from __future__ import absolute_import

import os
import os.path
import sys
import gzip
import shutil
import tarfile
import hashlib
import subprocess
import tempfile
from io import BytesIO
from contextlib import closing

try:
    from urllib import urlopen
except ImportError:
    from urllib.request import urlopen

URL = "https://downloads.xiph.org/releases/%(LIB)s/lib%(LIB)s-%(VERSION)s.tar.gz"

LIBS = {
    # 'lib': [("version", "SHA-256")]
    'ogg': [
        ('1.3.2', "e19ee34711d7af328cb26287f4137e70630e7261b17cbe3cd41011d73a654692"),
    ],
    'vorbis': [
        ('1.3.5', "6efbcecdd3e5dfbf090341b485da9d176eb250d893e3eb378c428a2db38301ce"),
    ]
}


OPTS = {
    'ogg': [],
    'vorbis': [],
}


def run(*cmd):
    print("Executing %s ..." % cmd[0])
    if subprocess.call(list(cmd)):
        raise RuntimeError("Command %s failed" % cmd[0])


def cmmi(basedir, installdir, *config_opts):
    orig_dir = os.getcwd()
    try:
        os.chdir(basedir)
        run(os.path.join(basedir, "configure"),
            "--enable-static", "--disable-shared", "--disable-dependency-tracking",
            "--prefix", installdir,
            *config_opts)
        run("make", "-j9")
        run("make", "install")
    finally:
        os.chdir(orig_dir)


def build(ogg_version=None, vorbis_version=None, installdir=None):
    if not installdir:
        installdir = tempfile.mkdtemp(suffix="-install")

    libs = [
        ('ogg', ogg_version, []),
        ('vorbis', vorbis_version, ['--disable-docs', '--disable-examples']),
    ]

    opts = []
    for lib, version, extra_opts in libs:
        if not version:
            check = LIBS[lib][0]
            version = check[0]
        else:
            for check in LIBS[lib]:
                if check[0] == version:
                    break
            else:
                check = None

        url = URL % {'LIB': lib, 'VERSION': version}
        with closing(urlopen(url)) as dl:
            data = dl.read()
        if check is not None:
            if hashlib.sha256(data).hexdigest() != check[1]:
                raise RuntimeError("checksum mismatch for lib %s" % lib)

        tempdir = tempfile.mkdtemp()
        try:
            zf = tarfile.TarFile(fileobj=gzip.GzipFile(fileobj=BytesIO(data)))
            zf.extractall(tempdir)
            cmmi(os.path.join(tempdir, "lib%s-%s" % (lib, version)),
                 installdir, *(opts + extra_opts))
            if os.path.isdir(os.path.join(installdir, "share")):
                shutil.rmtree(os.path.join(installdir, "share"))
            opts.append("--with-%s=%s" % (lib, installdir))
        finally:
            shutil.rmtree(tempdir)
    return installdir


if __name__ == '__main__':
    env = os.environ
    installdir = build(
        ogg_version=env.get('OGG_VERSION'),
        vorbis_version=env.get('VORBIS_VERSION'),
        installdir=sys.argv[1] if len(sys.argv) > 1 else None,
    )
    print(installdir)
