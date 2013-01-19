#!/usr/bin/env python

import sys
sys.path.insert(0, "src")

import pyrogg
import os, os.path


def recode(filename, destdir, quality):
    basename   = os.path.basename(filename)
    targetname = os.path.join(destdir, basename)

    print("Encoding '%s' in quality %+d" % (basename, quality))

    recoder = pyrogg.VorbisFileRecoder(filename)
    time = recoder.recode(targetname, quality)
    print("Encoding '%s' in quality %+d took %.2f seconds" % (
          basename, quality, time))


def _process(args):
    filename, dirname, quality = args
    try:
        recode(filename, dirname, quality)
    except (IOError, pyrogg.VorbisException), e:
        print(e)
        return False
    return True


def main():
    from optparse import OptionParser

    parser = OptionParser()
    parser.add_option('-q', '--quality', dest="quality", type=int,
                      help="recode to quality level QUALITY", metavar="QUALITY")
    parser.add_option('-p', '--parallel', dest="parallel", type=int,
                      help="number of files to process in parallel", metavar="THREADS")
    parser.add_option('-d', '--output-dir', dest="output_dir",
                      help="write output files to directory DIR", metavar="DIR")

    parser.set_defaults(quality=2, output_dir=None)

    options, args = parser.parse_args()

    if len(args) == 0:
        print("No input files found")
        sys.exit(0)
    if options.output_dir is None:
        print("Output directory is required, call with '-h' for help")
        sys.exit(0)

    quality = min(10, max(-1, options.quality))
    dirname = options.output_dir

    print("Recoding %d file%s to target directory '%s' ..." % (
          len(args), 's' if len(args) != 1 else '', dirname))

    if not os.access(dirname, os.F_OK):
        os.makedirs(dirname)

    if not os.access(dirname, os.W_OK):
        print("Cannot write to '%s'" % dirname)

    any_failures = False
    if options.parallel:
        import multiprocessing
        pool = multiprocessing.Pool(options.parallel)
        params = [(filename, dirname, quality) for filename in args]
        try:
            results = pool.map(_process, params)
            for result, filename in zip(results, args):
                if not result:
                    any_failures = True
                    print("Recoding failed for file %s" % filename)
        finally:
            pool.close()
    else:
        for filename in args:
            if not _process([filename, dirname, quality]):
                any_failures = True
                print("Recoding failed for file %s" % filename)
    return any_failures

if __name__ == '__main__':
    sys.exit(0 if main() else 1)
