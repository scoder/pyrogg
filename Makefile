PACKAGE=pyrogg
PYTHON?=python
TESTFLAGS=
TESTOPTS=
SETUPFLAGS=$(shell "$(PYTHON)" -c 'import Cython.Compiler.Main' 2>/dev/null && echo "--recompile")
VERSION?=$(shell sed -ne 's|^__version__\s*=\s*"\([^"]*\)".*|\1|p' src/pyrogg.pyx)

MANYLINUX_IMAGE_X86_64=quay.io/pypa/manylinux1_x86_64
MANYLINUX_IMAGE_686=quay.io/pypa/manylinux1_i686

all: inplace

sdist:
	$(PYTHON) setup.py $(SETUPFLAGS) sdist

# Build in-place
inplace:
	$(PYTHON) setup.py $(SETUPFLAGS) build_ext -i

build:
	$(PYTHON) setup.py $(SETUPFLAGS) build

test_build: build
	$(PYTHON) test.py $(TESTFLAGS) $(TESTOPTS)

test_inplace: inplace
	$(PYTHON) test.py $(TESTFLAGS) $(TESTOPTS)

bench_inplace: inplace
	$(PYTHON) bench.py -i

ftest_build: build
	$(PYTHON) test.py -f $(TESTFLAGS) $(TESTOPTS)

ftest_inplace: inplace
	$(PYTHON) test.py -f $(TESTFLAGS) $(TESTOPTS)

html:
	mkdir -p doc/html
	$(PYTHON) doc/mkhtml.py doc/html . `cat version.txt`

# XXX What should the default be?
test: test_inplace

bench: bench_inplace

ftest: ftest_inplace

clean:
	find . \( -name '*.o' -o -name '*.so' -o -name '*.py[cod]' -o -name '*.dll' \) -exec rm -f {} \;
	rm -rf build

realclean: clean
	find . -name '*.c' -exec rm -f {} \;
	rm -f TAGS
	$(PYTHON) setup.py clean -a

wheel_manylinux: wheel_manylinux64 wheel_manylinux32

wheel_manylinux32 wheel_manylinux64: dist/$(PACKAGE)-$(VERSION).tar.gz
	echo "Building wheels for $(PACKAGE) $(VERSION)"
	mkdir -p wheelhouse_$(subst wheel_,,$@)
	time docker run --rm -t \
		-v $(shell pwd):/io \
		-e CFLAGS="-O3 -g1 -mtune=generic -pipe -fPIC -flto" \
		-e LDFLAGS="$(LDFLAGS) -fPIC -flto" \
		-e WHEELHOUSE=wheelhouse_$(subst wheel_,,$@) \
		$(if $(patsubst %32,,$@),$(MANYLINUX_IMAGE_X86_64),$(MANYLINUX_IMAGE_686)) \
		bash -c '/opt/python/cp27-cp27m/bin/python /io/buildlibs.py $${HOME}/INSTALL || exit 1; \
		    for PYBIN in /opt/python/*/bin; do \
		    $$PYBIN/python -V; \
		    { PYROGG_STATIC_LIBS=$${HOME}/INSTALL/lib CFLAGS="-I$${HOME}/INSTALL/include $$CFLAGS" $$PYBIN/pip wheel -w /io/$$WHEELHOUSE /io/$< & } ; \
		    done; wait; \
		    for whl in /io/$$WHEELHOUSE/$(PACKAGE)-$(VERSION)-*-linux_*.whl; do auditwheel repair $$whl -w /io/$$WHEELHOUSE; done'
