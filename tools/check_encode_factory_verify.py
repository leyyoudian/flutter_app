# -*- coding: utf-8 -*-
"""Sanity-check the encode_factory self-verification additions:
1. cwrap round-trips through the firmware decoder replica for random payloads.
2. _verify_package passes on every existing P4 asset."""
import random
import struct
import sys
from pathlib import Path

sys.path.insert(0, r"D:\Documents\esp-baji\tools")
import encode_factory as enc

failures = []

# 1. cwrap round-trip: compressed form must decode to exactly the original
for n in list(range(1, 200)) + [512, 768, 1024, 4096, 230912, 231168]:
    for trial in range(8):
        raw = bytes(random.getrandbits(8) for _ in range(n))
        data, flags = enc.cwrap(raw)
        if flags & enc.FLAG_LZ4:
            header_len = struct.unpack_from("<I", data, 0)[0]
            if header_len != len(raw):
                failures.append(f"cwrap header {header_len} != {len(raw)}")
                continue
            dec = enc.badge_fw_lz4_decompress(data[4:], header_len)
            if dec != raw:
                failures.append(f"cwrap round-trip mismatch n={n}")
        else:
            if data != raw:
                failures.append(f"cwrap raw passthrough mismatch n={n}")

# 2. _verify_package on every existing P4 asset
assets = sorted(Path(r"D:\Documents\esp-baji\animation_sd_p4").rglob("*.eb5"))
spec = enc.target_spec("p4")
for p in assets:
    buf = p.read_bytes()
    try:
        n = enc._verify_package(buf, spec)
        print(f"  OK {p.parent.name}/{p.name}: {n} frames")
    except RuntimeError as exc:
        failures.append(f"{p.name}: {exc}")

if failures:
    print("FAILURES:")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print(f"ALL OK: {len(assets)} assets verified, cwrap round-trips clean")
