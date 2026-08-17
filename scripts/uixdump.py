import struct, sys, io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
path = sys.argv[1]
b = open(path, "rb").read()
magic, recsz, reccnt = struct.unpack_from("<4sHH", b, 0)
app = b[8:16].split(b"\x00")[0].decode()
nsec = struct.unpack_from("<I", b, 0x10)[0]
print("%s  %d bytes  magic=%s recsz=%d reccnt=%d app=%s builtinSections=%d"
      % (path, len(b), magic, recsz, reccnt, app, nsec))

for i in range(reccnt):
    o = 0x14 + i * 20
    sid, kind, cnt, poff, xoff, size = struct.unpack_from("<IHHIII", b, o)
    print("\n[rec %d] id=0x%04X kind=%d objs=%d payload=0x%X xprOff=0x%X size=0x%X"
          % (i, sid, kind, cnt, poff, xoff, size))
    tbl = poff
    blob = poff + cnt * 8
    entries = [struct.unpack_from("<II", b, tbl + k * 8) for k in range(cnt)]
    used = [(oid, off) for oid, off in entries if off != 0xFFFFFFFF]
    print("   objects with data: %d / %d ; blob at 0x%X (size 0x%X)"
          % (len(used), cnt, blob, size - cnt * 8))
    for oid, off in entries[:6]:
        print("     id=0x%08X off=%s" % (oid, "----" if off == 0xFFFFFFFF else "0x%X" % off))
    if kind == 1:  # strings
        print("   first strings:")
        for oid, off in used[:6]:
            p = blob + off
            n = 0
            while struct.unpack_from("<H", b, p + n)[0] != 0:
                n += 2
            print("      0x%08X @0x%-5X %r" % (oid, off, b[p:p + n].decode("utf-16-le")))
        # tail bytes of blob
        print("   blob head hex:", b[blob:blob + 32].hex())
    elif kind == 3:  # audio
        for oid, off in used[:8]:
            p = blob + off
            n = 0
            while struct.unpack_from("<H", b, p + n)[0] != 0:
                n += 2
            print("      0x%08X @0x%-5X %r" % (oid, off, b[p:p + n].decode("utf-16-le")))
    elif kind == 2:  # image
        print("   blob head hex:", b[blob:blob + 24].hex())
        print("   xpr magic:", b[blob + xoff:blob + xoff + 4])
        hdr = struct.unpack_from("<III", b, blob + xoff + 4)
        print("   xpr total=0x%X headerSize=0x%X count/flags=0x%X" % hdr)
    else:
        print("   layout records:")
        for oid, off in used[:8]:
            p = blob + off
            x, y, w, h, img, back, text, dis, sel, hi, font, flags, xo, yo, custom = \
                struct.unpack_from("<4HIIIIIIHHHHI", b, p)
            print("      0x%08X @0x%-5X %4d,%-4d %4dx%-4d img=0x%-6X back=%08X text=%08X dis=%08X sel=%08X hi=%08X font=%-3d flags=0x%-4X off=%d,%d custom=%d"
                  % (oid, off, x, y, w, h, img, back, text, dis, sel, hi, font, flags, xo, yo, custom))
        if xoff != 0xFFFFFFFF:
            print("   xpr at blob+0x%X magic=%s" % (xoff, b[blob + xoff:blob + xoff + 4]))
