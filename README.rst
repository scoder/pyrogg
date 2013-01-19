pyrogg
======

What is it?
-----------

pyrogg is a simple recoding library for Ogg-Vorbis audio files, implemented in Cython.
It reads Vorbis streams from the provided input files and recodes them to the desired
quality level (-1 ... 10).  It comes with handy command line interface.


Example
-------

Command line usage::

   $ recode.py -d outputdir --quality=1 --parallel=3 input1.ogg input2.ogg input3.ogg

Python usage::

   >>> from pyrogg import VorbisFileRecoder
   >>> rec = VorbisFileRecoder("input.ogg")

   >>> time = rec.recode("output.ogg", quality=1)


Why would I use it?
-------------------

* It can recode files on the file-system as well as file-like objects.

* It uses OpenMP to decode and encode an input stream in parallel, as well as
  multiprocessing to recode multiple files in parallel.  So it can use
  all resources that your machine can provide, which makes it pretty fast.

* Parallel recoding of separate input files is thread-safe and frees the GIL.


Why would I not use it?
-----------------------

* Currently, error handling isn't very elaborate, so unexpected errors may
  crash your system.  This should be easy to fix with a little work, and
  help on this is certainly appreciated.  (Fear not, it's written in Cython,
  not C.)

* It's not meant to recode streams on the fly, just files and file-like
  objects.  Currently, input files/objects must allow random access through
  seek().  This should be fixable.


How can I install it?
---------------------

Using pip::

    pip install pyrogg

Note that this will do a source build, so you need a properly configured
C compiler on your system that can build Python extension modules, as well
as the library packages ``libogg``, ``libvorbis``, ``libvorbisfile`` and
their corresponding development packages.  Most operating systems (including
all commonly used Linux distributions) will allow you to install them via
the normal package management tool.  For the development packages, look
for packages called ``libogg-dev`` or ``libogg-devel``.

For Windows and MacOS, however, you need to install them manually.  See here:

https://www.xiph.org/downloads/
