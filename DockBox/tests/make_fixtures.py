#!/usr/bin/env python3
"""Builds the .deb and Ren'Py samples ImporterTests.swift reads."""
import gzip, io, lzma, os, sys, tarfile

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
LONG = "deep/" * 30 + "asset.bin"

def add(t, name, data=None, link=None, mode=0o644):
    i = tarfile.TarInfo(name)
    i.mode = mode
    if link:
        i.type, i.linkname = tarfile.SYMTYPE, link
        t.addfile(i)
    elif data is None:
        i.type, i.mode = tarfile.DIRTYPE, 0o755
        t.addfile(i)
    else:
        i.size = len(data)
        t.addfile(i, io.BytesIO(data))

def tar(prefix, fmt, app=True):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w", format=fmt) as t:
        add(t, "./Library/MobileSubstrate/DynamicLibraries/x.plist", b"tweak")
        if app:
            a = prefix + "Applications/Demo.app/"
            add(t, a)
            add(t, a + "Info.plist", b"plist")
            add(t, a + "Demo", b"\xcf\xfa" * 40000, mode=0o755)
            add(t, a + LONG, b"long")
            add(t, a + "inside", link="Info.plist")
            add(t, a + "outside", link="../../../etc/passwd")
            add(t, a + "../../../../escape", b"bad")
    return b.getvalue()

def deb(name, member, data):
    def entry(n, d):
        head = f"{n + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(d):<10}`\n".encode()
        return head + d + (b"\n" if len(d) % 2 else b"")
    with open(os.path.join(out, name), "wb") as f:
        f.write(b"!<arch>\n" + entry("debian-binary", b"2.0\n") + entry("control.tar.gz", gzip.compress(b"x")) + entry(member, data))

deb("rootless-xz.deb", "data.tar.xz", lzma.compress(tar("./var/jb/", tarfile.PAX_FORMAT), format=lzma.FORMAT_XZ))
deb("rootful-gz.deb", "data.tar.gz", gzip.compress(tar("./", tarfile.GNU_FORMAT)))
deb("plain.deb", "data.tar", tar("", tarfile.USTAR_FORMAT if False else tarfile.PAX_FORMAT))
deb("tweak.deb", "data.tar.xz", lzma.compress(tar("./", tarfile.PAX_FORMAT, app=False), format=lzma.FORMAT_XZ))
deb("zstd.deb", "data.tar.zst", b"\x28\xb5\x2f\xfd")

for rel in ("renpy/MyGame-1.0-pc/game/scripts.rpa", "renpy/MyGame-1.0-pc/lib/game/ignored.rpa", "notrenpy/game/readme.txt"):
    p = os.path.join(out, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(b"x")
