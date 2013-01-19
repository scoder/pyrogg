import sys, os.path
from distutils.core import setup, Extension

version = "0.1"

cflags = ['-Wall']
libs   = ['-lvorbis', '-lvorbisfile', '-lvorbisenc', '-logg', '-lm']

EXT_MODULE = "pyrogg"
setup_args = {}
DEFINES = []

ext_file = os.path.join('src', EXT_MODULE)
pyx_source = ext_file + '.pyx'
c_source   = ext_file + '.c'

extension = Extension(
    EXT_MODULE, [pyx_source],
    extra_compile_args = cflags,
    define_macros = DEFINES,
    extra_link_args = libs)

try: sys.argv.remove('--without-assert')
except ValueError: pass
else: DEFINES.append( ('CYTHON_WITHOUT_ASSERTIONS', None) )

try: sys.argv.remove('--debug-gcc')
except ValueError: pass
else: cflags.append('-ggdb')

try: sys.argv.remove('--no-parallel')
except ValueError:
    if sys.platform == 'win32':
        cflags.append('/fopenmp')
        libs.append('/fopenmp')
    else:
        cflags.append('-fopenmp')
        libs.append('-fopenmp')

if not os.path.exists(c_source) or '--recompile' in sys.argv:
    try: sys.argv.remove('--recompile')
    except ValueError: pass
    from Cython.Build import cythonize
    ext_modules = cythonize([extension])
else:
    extension.sources[0] = c_source
    ext_modules = [extension]


with open('README.rst') as f:
    long_description = f.read()

setup(
    name = "pyrogg",
    version = version,
    author="pyrogg dev team",
    author_email="stefan_ml@behnel.de",
    maintainer="pyrogg dev team",
    maintainer_email="stefan_ml@behnel.de",
    url="https://github.com/scoder/pyrogg",

    description="Recode Ogg-Vorbis files to a different quality level",
    long_description=long_description,

    classifiers = [
    'Development Status :: 3 - Alpha',
    'Intended Audience :: Developers',
    'Intended Audience :: Information Technology',
    'License :: OSI Approved :: BSD License',
    'Programming Language :: Cython',
    'Programming Language :: Python :: 2',
    'Programming Language :: Python :: 3',
    'Operating System :: OS Independent',
    'Topic :: Multimedia :: Sound/Audio',
    ],

    package_dir = {'': 'src'},
#    packages = [''],
    ext_modules = ext_modules,
    **setup_args
)
