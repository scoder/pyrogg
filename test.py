import os
import glob
import sys
sys.path.insert(0, "src")

import pyrogg

QUALITY_LEVELS = tuple(range(0, 11))
TEST_FILE = "test.ogg"
TEST_DIR = "testoutput"


def output_filename(test_dir, quality, recoder_type):
    return os.path.join(test_dir, 'out_%02d_%s.ogg' % (
        quality+1, 'cfile' if recoder_type == 'file' else 'pfile'))


def main(test_dir=TEST_DIR):
    files1, files2 = [], []
    recoder = pyrogg.VorbisFileRecoder(TEST_FILE)
    for quality in QUALITY_LEVELS:
        print("Encoding in quality %+d" % quality)
        filename = output_filename(test_dir, quality, 'file')
        files1.append(filename)
        print("time: %.2f" % recoder.recode(filename, quality))

    for quality in QUALITY_LEVELS:
        with open(TEST_FILE, 'rb') as f:
            recoder = pyrogg.VorbisFilelikeRecoder(f)
            print("Encoding in quality %+d" % quality)
            filename = output_filename(test_dir, quality, 'filelike')
            files2.append(filename)
            with open(filename, 'wb') as fout:
                print("time: %.2f" % recoder.recode(fout, quality))

    for quality, f1, f2 in zip(QUALITY_LEVELS, files1, files2):
        with open(f1, 'rb') as fresult1:
            with open(f2, 'rb') as fresult2:
                assert fresult1.read() == fresult2.read(), \
                    "mismatch at quality level %d" % quality


if __name__ == '__main__':
    if not os.path.isfile(TEST_FILE):
        print("Please provide a test file at '%s'" % TEST_FILE)
        sys.exit(1)
    test_dir = os.path.abspath(TEST_DIR)
    if not os.path.isdir(test_dir):
        os.makedirs(test_dir)
    try:
        main(test_dir)
    finally:
        for filepath in glob.iglob(os.path.join(test_dir, 'out_*.ogg')):
            os.remove(filepath)
