"""Per-texture comparison of the packed resources in two .uix skins.

Walks each section's embedded .xpr, decodes the resource headers and reports how
many bytes of each texture's data differ between the reference and the actual
file. Texture names come from the .rdf files skinbld writes with /rdf.
"""
import io
import struct
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

FORMATS = {
    0x06: ("A8R8G8B8", 4),
    0x0C: ("DXT1", 0),
    0x0E: ("DXT3", 0),
    0x0F: ("DXT5", 0),
    0x1A: ("LIN_A8R8G8B8", 4),
}


def sections(b):
    count = struct.unpack_from("<H", b, 6)[0]
    for i in range(count):
        o = 0x14 + i * 20
        sid, kind, cnt, poff, xoff, size = struct.unpack_from("<IHHIII", b, o)
        yield sid, kind, cnt, poff, xoff, size


def textures(b, xpr):
    total, header_size = struct.unpack_from("<II", b, xpr + 4)
    data = xpr + header_size
    p = xpr + 12
    while p + 20 <= xpr + header_size:
        common, off, lock, fmt, size = struct.unpack_from("<IIIII", b, p)
        if common == 0:
            break
        name, bpp = FORMATS.get((fmt >> 8) & 0xFF, ("fmt%02X" % ((fmt >> 8) & 0xFF), 0))
        u = 1 << ((fmt >> 20) & 0xF)
        v = 1 << ((fmt >> 24) & 0xF)
        if bpp:
            length = u * v * bpp
        else:
            length = u * v // (2 if name == "DXT1" else 1)
        yield data + off, length, name, u, v
        p += 20


def main():
    a = open(sys.argv[1], "rb").read()
    b = open(sys.argv[2], "rb").read()
    names = [line.split()[1] for line in open(sys.argv[3]).read().splitlines()
             if line.startswith("Texture ")] if len(sys.argv) > 3 else []

    index = 0
    for (sid, kind, cnt, poff, xoff, size), (sid2, _, cnt2, poff2, xoff2, _) in zip(sections(a), sections(b)):
        if xoff == 0xFFFFFFFF:
            continue
        xpr_a = poff + cnt * 8 + xoff
        xpr_b = poff2 + cnt2 * 8 + xoff2
        print("section 0x%04X kind=%d" % (sid, kind))
        for (oa, la, fmt, u, v), (ob, lb, _, _, _) in zip(textures(a, xpr_a), textures(b, xpr_b)):
            length = min(la, lb, len(a) - oa, len(b) - ob)
            diff = sum(1 for k in range(length) if a[oa + k] != b[ob + k])
            name = names[index] if index < len(names) else "?"
            index += 1
            flag = "OK  " if diff == 0 else "DIFF"
            print("  %s %-40s %-9s %4dx%-4d %7d bytes  %6d differ (%5.1f%%)"
                  % (flag, name, fmt, u, v, la, diff, 100.0 * diff / la))


main()
