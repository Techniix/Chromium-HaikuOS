#!/usr/bin/env python3
# HAIKU-PREGENERATED: Tint's generator needs Go >= 1.26, which Haiku lacks.
# Generate the sources on another machine (see haiku-fixes-pass5.sh) and
# unpack them into out/Release/gen; this script then just accepts them.
import os, shutil, subprocess, sys
out = os.path.join(os.getcwd(), sys.argv[1])
tint = os.path.join(out, "src", "tint")
if os.path.exists(os.path.join(tint, "lang", "core", "enums.cc")):
    for root, _, files in os.walk(tint):
        for f in files:
            os.utime(os.path.join(root, f))
    sys.exit(0)
if shutil.which("go"):
    orig = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate-sources-gn.py.orig")
    sys.exit(subprocess.call([sys.executable, orig] + sys.argv[1:]))
sys.stderr.write("Tint sources are missing from %s. Generate them with Go >= 1.26 "
                 "on another machine and unpack them there (see haiku-fixes-pass5.sh).\n" % tint)
sys.exit(1)
