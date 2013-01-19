import sys, os.path

version = "0.1"

cflags = ['-Wall']
libs   = ['-lvorbis', '-lvorbisfile', '-lvorbisenc', '-logg', '-lm']

EXT_MODULE = "pyrogg"


setup_args = {}
ext_args   = {}
DEFINES = []

from distutils.core import setup, Extension


try:
    sys.argv.remove('--without-assert')
    DEFINES.append( ('PYREX_WITHOUT_ASSERTIONS', None) )
except ValueError:
    pass

try: sys.argv.remove('--debug-gcc')
except ValueError: pass
else: cflags.append('-ggdb')

try: sys.argv.remove('--parallel')
except ValueError: pass
else:
    cflags.append('-fopenmp')
    libs.append('-fopenmp')

ext_file = os.path.join('src', EXT_MODULE)
pyx_source = ext_file + '.pyx'
c_source   = ext_file + '.c'

extension = Extension(
    EXT_MODULE, [pyx_source],
    extra_compile_args = cflags,
    define_macros = DEFINES,
    extra_link_args = libs)

if not os.path.exists(c_source) or '--recompile' in sys.argv:
    try: sys.argv.remove('--recompile')
    except ValueError: pass
    from Cython.Build import cythonize
    ext_modules = cythonize([extension])
else:
    extension.sources[0] = extension.sources[0][:-4] + '.c'
    ext_modules = [extension]

setup(
    name = "pyrogg",
    version = version,
    author="pyrogg dev team",
#    author_email="lxml-dev@codespeak.net",
    maintainer="pyrogg dev team",
#    maintainer_email="lxml-dev@codespeak.net",
#    url="http://codespeak.net/lxml",
#    download_url="http://cheeseshop.python.org/packages/source/l/lxml/lxml-%s.tar.gz" % version,

    description="",

    long_description="""\
lxml is a Pythonic binding for the libxml2 and libxslt libraries.  It provides
safe and convenient access to these libraries using the ElementTree API.

It extends the ElementTree API significantly to offer support for XPath,
RelaxNG, XML Schema, XSLT, C14N and much more.

In case you want to use the current in-development version of lxml, you can
get it from the subversion repository at http://codespeak.net/svn/lxml/trunk .
Running ``easy_install lxml==dev`` will install it from
http://codespeak.net/svn/lxml/trunk#egg=lxml-dev

Current bug fixes for the stable version are at
http://codespeak.net/svn/lxml/branch/lxml-%(branch_version)s .
Running ``easy_install lxml==%(branch_version)sbugfix`` will install this
version from
http://codespeak.net/svn/lxml/branch/lxml-%(branch_version)s#egg=lxml-%(branch_version)sbugfix

""",

    classifiers = [
    'Development Status :: 3 - Alpha',
    'Intended Audience :: Developers',
    'Intended Audience :: Information Technology',
    'License :: OSI Approved :: BSD License',
    'Programming Language :: Python',
    'Programming Language :: C',
    'Operating System :: OS Independent',
    'Topic :: Software Development :: Libraries :: Python Modules'
    ],

    package_dir = {'': 'src'},
#    packages = [''],
    ext_modules = ext_modules,
    **setup_args
)
