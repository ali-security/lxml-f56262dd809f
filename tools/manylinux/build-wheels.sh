#!/bin/bash
#
# Called inside the manylinux image
echo "Started $0 $@"

set -e -x
REQUIREMENTS=/io/requirements.txt
[ -n "$WHEELHOUSE" ] || WHEELHOUSE=wheelhouse
SDIST=$1
PACKAGE=$(basename ${SDIST%-*})
SDIST_PREFIX=$(basename ${SDIST%%.tar.gz})
[ -z "$PYTHON_BUILD_VERSION" ] && PYTHON_BUILD_VERSION="*"

pin_wheel_version() {
    # Optionally pin the "wheel" package version for Python 3.7+ interpreters.
    # There is no pyproject.toml, so "pip wheel" takes the legacy, non-isolated
    # build path and the ambient "wheel" package stamps the "Generator" of the
    # wheel metadata.  Images that already provide the expected version pass an
    # empty WHEEL_VERSION_PY37PLUS and keep their ambient "wheel" untouched.
    pybin="$1"
    [ -n "$WHEEL_VERSION_PY37PLUS" ] || return 0
    ${pybin}/python -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 7) else 1)' || return 0
    echo "Pinning wheel==$WHEEL_VERSION_PY37PLUS for $(${pybin}/python -V 2>&1)"
    ${pybin}/python -m pip install "wheel==$WHEEL_VERSION_PY37PLUS"
}

build_wheel() {
    pybin="$1"
    source="$2"
    [ -n "$source" ] || source=/io

    pin_wheel_version "$pybin"

    env STATIC_DEPS=true \
        RUN_TESTS=true \
        LDFLAGS="$LDFLAGS -fPIC" \
        CFLAGS="$CFLAGS -fPIC" \
        ACLOCAL_PATH=/usr/share/aclocal/ \
        ${pybin}/pip \
            wheel \
            "$source" \
            -w /io/$WHEELHOUSE
}

TEST_HARNESS_DIR=$HOME/lxml-wheel-test

run_test_suite() {
    # Run lxml's own test suite against the *installed* wheel.
    #
    # The runner (the repo root test.py) sets sys.path[0] to "<dir of
    # test.py>/src", so it must not be started from the source tree: /io/src
    # holds no compiled modules and would shadow the installed package.
    # Instead, build a harness directory outside the source tree containing the
    # runner, the INSTALLED lxml package as ./src/lxml, the test packages from
    # the source tree, and the doc/ + samples/ data files that the doctests
    # read.  This mirrors the "Test the built wheel" step of the macOS/Windows
    # workflow, so that every platform tests the same way.
    pybin="$1"
    (
        # NOTE: bash suspends "set -e" inside a subshell that is part of an
        # "||" list, so every step below fails explicitly with "exit 1".
        set -x

        # html5lib is a test dependency of lxml.html.tests.test_html5parser
        # (its "module missing" import hook no longer works on Python 3.12+).
        # beautifulsoup4/cssselect/rnc2rng are deliberately not installed:
        # those tests self-skip when the module is absent.
        ${pybin}/python -m pip install "html5lib==1.1" || exit 1

        # a clean harness per interpreter
        rm -rf "$TEST_HARNESS_DIR" || exit 1
        mkdir -p "$TEST_HARNESS_DIR" || exit 1
        cp /io/test.py "$TEST_HARNESS_DIR/test.py" || exit 1
        cd "$TEST_HARNESS_DIR" || exit 1

        cat > collect_installed.py <<'PYEOF'
import os, shutil, sys
import lxml
installed = os.path.dirname(os.path.abspath(lxml.__file__))
print("installed lxml package: " + installed)
norm = installed.replace(os.sep, "/")
if "site-packages" not in norm and "dist-packages" not in norm:
    sys.exit("refusing to test %s - not an installed package" % installed)
target = os.path.join(os.getcwd(), "src", "lxml")
shutil.copytree(installed, target)
source = sys.argv[1]
shutil.copytree(os.path.join(source, "src", "lxml", "tests"),
                os.path.join(target, "tests"))
shutil.copytree(os.path.join(source, "src", "lxml", "html", "tests"),
                os.path.join(target, "html", "tests"))
# the doctests read ../../../doc/*.txt and samples/*.xml relative to here
shutil.copytree(os.path.join(source, "doc"), os.path.join(os.getcwd(), "doc"))
shutil.copytree(os.path.join(source, "samples"), os.path.join(os.getcwd(), "samples"))
print("test tree ready at " + target)
PYEOF
        ${pybin}/python collect_installed.py /io || exit 1
        rm -f collect_installed.py

        # test.py discovers ./src/lxml/tests and ./src/lxml/html/tests, prints
        # every test plus a "Ran N tests" summary, and exits non-zero on any
        # failure or error.
        # The one filtered test id tests the *stdlib*
        # xml.etree.ElementTree.XMLPullParser (etree = ElementTree), not lxml:
        # expat 2.6's reparse deferral (shipped in CPython 3.9.19+/3.10.14+/
        # 3.11.9+/3.12.3+, which these images carry) delays its incremental
        # events, so it fails on those interpreters regardless of lxml.  No lxml
        # test is filtered out; lxml's own ETreePullTestCase equivalent runs.
        PYTHONIOENCODING=utf-8 ${pybin}/python ./test.py -vv '' '!^lxml\.tests\.test_elementtree\.ElementTreePullTestCase\.test_simple_xml$'
    )
}

select_full_suite_interpreter() {
    # The newest CPython in this image runs the whole suite; the other
    # interpreters keep the cheap import check.  Running the full suite on every
    # interpreter of every image pushes this workflow past the CI dispatch
    # window, and the suite is identical across interpreters: every image still
    # gets one full run, and every non-Linux leg runs the full suite for its own
    # interpreter.
    best=0
    FULL_SUITE_PYBIN=""
    for pybin in /opt/python/${PYTHON_BUILD_VERSION}/bin/; do
        case "$pybin" in *pypy*) continue ;; esac
        tag=$(echo "$pybin" | sed -ne 's|.*/\(cp[0-9][0-9]*\)-.*|\1|p')
        n=${tag#cp}
        [ -n "$n" ] || continue
        if [ "$n" -gt "$best" ]; then
            best="$n"
            FULL_SUITE_PYBIN="$pybin"
        fi
    done
    echo "Full test suite interpreter for this image: ${FULL_SUITE_PYBIN:-<none>}"
}

run_one_interpreter() {
    if [ "$1" = "${FULL_SUITE_PYBIN}" ]; then
        run_test_suite "$1"
    else
        # the upstream import check, for the interpreters of this image that do
        # not run the full suite
        (cd $HOME; ${1}/python -c 'import lxml.etree, lxml.objectify')
    fi
}

run_tests() {
    # Install packages and test
    select_full_suite_interpreter
    for PYBIN in /opt/python/${PYTHON_BUILD_VERSION}/bin/; do
        ${PYBIN}/python -m pip install $PACKAGE --no-index -f /io/$WHEELHOUSE | tee install.txt || exit 1

        run_one_interpreter "${PYBIN}" || {
          # Allow PyPy to fail the tests due to C-API differences for 'str' (PyVarObject or not).
          echo "${PYBIN}" | fgrep -q pypy || exit 1
          echo "Tests failed - deleting wheel"
          sed -ne '/Processing .*\.whl/s|Processing ||p' install.txt | (cd /io/$WHEELHOUSE && xargs rm)
        }
    done
}

prepare_system() {
    #yum install -y zlib-devel
    yum --version 2>/dev/null && yum -y install xz  || true
    apt-get --version 2>/dev/null && apt-get install xz-utils  || true
    #rm -fr /opt/python/cp34-*
    echo "Python versions found: $(cd /opt/python && echo cp* | sed -e 's|[^ ]*-||g')"
    ${CC:-gcc} --version
}

build_wheels() {
    # Compile wheels for all python versions
    test -e "$SDIST" && source="$SDIST" || source=
    FIRST=
    SECOND=
    THIRD=
    for PYBIN in /opt/python/${PYTHON_BUILD_VERSION}/bin; do
        # Install build requirements if we need them and file exists
        test -n "$source" -o ! -e "$REQUIREMENTS" \
            || ${PYBIN}/python -m pip install -r "$REQUIREMENTS"

        echo "Starting build with $($PYBIN/python -V)"
        build_wheel "$PYBIN" "$source" &
        THIRD=$!

        [ -z "$FIRST" ] || wait ${FIRST}
        if [ "$(uname -m)" == "aarch64" ]; then FIRST=$THIRD; else FIRST=$SECOND; fi
        SECOND=$THIRD
    done
    wait || exit 1
}

repair_wheels() {
    # Bundle external shared libraries into the wheels
    for whl in /io/$WHEELHOUSE/${SDIST_PREFIX}-*.whl; do
        auditwheel repair $whl -w /io/$WHEELHOUSE || exit 1
    done
}

show_wheels() {
    ls -l /io/$WHEELHOUSE/${SDIST_PREFIX}-*.whl
}

prepare_system
build_wheels
repair_wheels
run_tests
show_wheels
