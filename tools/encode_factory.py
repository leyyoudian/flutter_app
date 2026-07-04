#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Factory Animation Encoder - MP4 to EBAJ4 for ESP32 badge."""

import os
import subprocess
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "animation_comd"
OUT_DIR = ROOT / "animation_sd"

FPS = 40
WIDTH = 480
HEIGHT = 480
ZOOM = 1.1  # default scale-up factor

def get_zoom(pid):
    """F008-F017 need 1.3x zoom, others 1.1x."""
    try:
        n = int(pid[1:])  # "F008" -> 8
        if 8 <= n <= 17:
            return 1.3
    except ValueError:
        pass
    return ZOOM  # default 1.1
PALETTE_ENTRIES = 256
PALETTE_BYTES = PALETTE_ENTRIES * 2
HEADER_SIZE = 44
FRAME_ENTRY_SIZE = 16
TILE_SIZE = 16
MAGIC = 0x344A4142
VERSION = 4
CODEC_KEY = 0x10
CODEC_TILE = 0x11
CODEC_REPEAT = 0x12
FLAG_LZ4 = 0x80
LZ4_MIN_MATCH = 4
LZ4_HASH_LOG = 14
LZ4_HASH_SIZE = 1 << LZ4_HASH_LOG


def make_dial_mp4(mp4, out_mp4, size=480, fps=30, zoom=1.0):
    """Convert MP4 to preview MP4: play once at full quality."""
    out_mp4.parent.mkdir(parents=True, exist_ok=True)
    zs = int(size * zoom)
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(mp4),
        "-vf", f"fps={fps},scale={zs}:{zs}:force_original_aspect_ratio=increase:flags=lanczos,crop={size}:{size}",
        "-c:v", "libx264", "-crf", "18", "-preset", "fast",
        "-pix_fmt", "yuv420p", "-an",
        str(out_mp4)
    ], check=True)


def natural_key(name):
    """Extract leading number for natural sort (2 < 10)."""
    import re
    m = re.match(r'(\d+)', Path(name).name)
    return int(m.group(1)) if m else 0


def find_pairs():
    first = sorted((SRC_DIR / "first_half").glob("*.mp4"), key=natural_key)
    second = sorted((SRC_DIR / "second_half").glob("*.mp4"), key=natural_key)
    pairs = []
    for i, f1 in enumerate(first):
        s2 = second[i] if i < len(second) else None
        pairs.append((f"F{i+1:03d}", f1, s2))
    return pairs


def find_third():
    """Scan third_half folder for special transition animations."""
    third_dir = SRC_DIR / "third_half"
    if not third_dir.is_dir():
        return []
    result = []
    for mp4 in sorted(third_dir.glob("*.mp4")):
        # Name convention: <source_id>.mp4 e.g. F007.mp4 = transition FROM F007
        eid = mp4.stem  # "F007"
        result.append((eid, mp4))
    return result


def mp4_to_frames(mp4_path, tmp_dir):
    tmp_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(mp4_path),
        "-vf", f"fps={FPS},scale={WIDTH}:{HEIGHT}:flags=lanczos",
        str(tmp_dir / "frame_%04d.png")
    ], check=True)
    return sorted(tmp_dir.glob("frame_*.png"))


def rgb565_to_rgb888(v):
    """Convert RGB565 (uint16) to (R, G, B) 0-255 tuple."""
    return ((v >> 11) & 0x1F) * 255 // 31, ((v >> 5) & 0x3F) * 255 // 63, (v & 0x1F) * 255 // 31


def rgb888_to_rgb565(r, g, b):
    """Convert (R, G, B) 0-255 to RGB565 uint16."""
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def mp4_to_palette_frames(mp4, tmp_dir, ss=480, zoom=ZOOM):
    """ffmpeg: optimal palette + Bayer-dithered frames with optional ZOOM crop."""
    palette_png = tmp_dir / "palette.png"
    if zoom != 1.0:
        zs = int(ss * zoom)
        scale_crop = f"scale={zs}:{zs}:force_original_aspect_ratio=increase:flags=lanczos,crop={ss}:{ss}"
    else:
        scale_crop = f"scale={ss}:{ss}:flags=lanczos"
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(mp4),
        "-vf", f"fps={FPS},{scale_crop},palettegen=stats_mode=diff:max_colors={PALETTE_ENTRIES}",
        str(palette_png)
    ], check=True)
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(mp4),
        "-i", str(palette_png),
        "-lavfi",
        f"fps={FPS},{scale_crop}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
        str(tmp_dir / "frame_%04d.png")
    ], check=True)
    return palette_png, sorted(tmp_dir.glob("frame_*.png"))


def read_palette_rgb(palette_png):
    """Read ffmpeg palette PNG, return list of (R,G,B) tuples + 512-byte RGB565 palette."""
    from PIL import Image
    img = Image.open(palette_png).convert("RGB")
    colors = list(img.getdata())[:PALETTE_ENTRIES]
    pal = bytearray(PALETTE_BYTES)
    for i, (r, g, b) in enumerate(colors):
        v = rgb888_to_rgb565(r, g, b)
        pal[i * 2] = v & 0xFF
        pal[i * 2 + 1] = (v >> 8) & 0xFF
    return colors, bytes(pal)


def build_lut(palette_rgb):
    """Build 64^3 RGB lookup table using numpy vectorization."""
    import numpy as np
    p = np.array(palette_rgb, dtype=np.int32)  # (256, 3)
    rs = np.arange(64, dtype=np.int32) * 255 // 63
    gs = np.arange(64, dtype=np.int32) * 255 // 63
    bs = np.arange(64, dtype=np.int32) * 255 // 63
    lut = np.zeros((64, 64, 64), dtype=np.uint8)
    for ri in range(64):
        fr = rs[ri]
        gg, bb = np.meshgrid(gs, bs, indexing='ij')
        pixels = np.stack([np.full_like(gg, fr), gg, bb], axis=-1)  # (64, 64, 3)
        pixels = pixels[:, :, None, :] - p[None, None, :, :]  # (64, 64, 256, 3)
        dist = np.sum(pixels.astype(np.int64) ** 2, axis=-1)  # (64, 64, 256)
        lut[ri] = np.argmin(dist, axis=-1).astype(np.uint8)
    return lut


def frame_to_indices(frame_png, lut):
    """Convert frame PNG to palette indices using 3D LUT (instant)."""
    from PIL import Image
    import numpy as np
    img = Image.open(frame_png).convert("RGB")
    a = np.array(img, dtype=np.int32)
    r = np.clip(a[:, :, 0] * 63 // 255, 0, 63)
    g = np.clip(a[:, :, 1] * 63 // 255, 0, 63)
    b = np.clip(a[:, :, 2] * 63 // 255, 0, 63)
    return lut[r, g, b].tobytes()


def enc_key(pal, idx):
    """KEY frame: palette (512B) + raw indices."""
    return pal + idx


def enc_tile(pal, idx, prev, ss):
    """TILE frame: palette + only changed 16x16 tiles."""
    tc, tr = ss // TILE_SIZE, ss // TILE_SIZE
    dirty = []
    for ty in range(tr):
        for tx in range(tc):
            ch = False
            for row in range(TILE_SIZE):
                y = ty * TILE_SIZE + row
                off = y * ss + tx * TILE_SIZE
                if idx[off:off + TILE_SIZE] != prev[off:off + TILE_SIZE]:
                    ch = True
                    break
            if ch:
                dirty.append((ty * tc + tx, tx, ty))
    n = len(dirty)
    out = bytearray(PALETTE_BYTES + 2 + n * (2 + TILE_SIZE * TILE_SIZE))
    out[:PALETTE_BYTES] = pal
    struct.pack_into('<H', out, PALETTE_BYTES, n)
    off = PALETTE_BYTES + 2
    for ti, tx, ty in dirty:
        struct.pack_into('<H', out, off, ti)
        off += 2
        for row in range(TILE_SIZE):
            y = ty * TILE_SIZE + row
            so = y * ss + tx * TILE_SIZE
            out[off:off + TILE_SIZE] = idx[so:so + TILE_SIZE]
            off += TILE_SIZE
    return bytes(out[:off])


def lz4_compress(data):
    if len(data) < 8: return data
    s = bytearray(data); se = len(s)
    o = bytearray(se + se//255 + 32); od = 0
    sp = 0; ls = 0; ht = [0]*LZ4_HASH_SIZE; pr = 0x9E3779B1
    while sp < se - LZ4_MIN_MATCH:
        h = ((s[sp]|(s[sp+1]<<8)|(s[sp+2]<<16)|(s[sp+3]<<24))*pr)&0xFFFFFFFF
        idx = h >> (32-LZ4_HASH_LOG); ref = ht[idx]; ht[idx] = sp
        if ref==0 or sp-ref>65535 or s[ref]!=s[sp] or s[ref+1]!=s[sp+1] or s[ref+2]!=s[sp+2] or s[ref+3]!=s[sp+3]:
            sp+=1; continue
        ml = LZ4_MIN_MATCH; mm = min(se-sp, 0x1F+LZ4_MIN_MATCH-1)
        while ml<mm and s[ref+ml]==s[sp+ml]: ml+=1
        ll = sp - ls
        tok = (min(ll,15)<<4)|min(ml-LZ4_MIN_MATCH,15); o[od]=tok; od+=1
        ex = ll-15
        while ex>=255: o[od]=255; od+=1; ex-=255
        if ll>=15: o[od]=ex; od+=1
        o[od:od+ll]=s[ls:ls+ll]; od+=ll
        off = sp-ref; o[od]=off&0xFF; o[od+1]=(off>>8)&0xFF; od+=2
        ex = ml-LZ4_MIN_MATCH-15
        while ex>=255: o[od]=255; od+=1; ex-=255
        if ml-LZ4_MIN_MATCH>=15: o[od]=ex; od+=1
        sp+=ml; ls=sp
    ll = se-ls
    if ll>0:
        tok = min(ll,15)<<4; o[od]=tok; od+=1
        ex=ll-15
        while ex>=255: o[od]=255; od+=1; ex-=255
        if ll>=15: o[od]=ex; od+=1
        o[od:od+ll]=s[ls:ls+ll]; od+=ll
    return bytes(o[:od])


def cwrap(raw):
    c = lz4_compress(raw)
    if len(c) + 4 < len(raw):
        return struct.pack('<I', len(raw)) + c, FLAG_LZ4
    return raw, 0


def enc_frame(pal, idx, prev, ss, fk=False):
    if not fk and prev is not None and idx==prev: return b'',CODEC_REPEAT,0
    key=enc_key(pal, idx)
    if not fk and prev is not None:
        tile=enc_tile(pal, idx,prev,ss)
        if len(tile)<len(key):
            d,f=cwrap(tile); return d,CODEC_TILE,f
    d,f=cwrap(key); return d,CODEC_KEY,f


def pack_ebaj4(fd, fps, ss):
    n=len(fd); db=sum(len(f[0]) for f in fd)
    fto=HEADER_SIZE; fdo=HEADER_SIZE+n*FRAME_ENTRY_SIZE; ps=fdo+db
    buf=bytearray(ps)
    struct.pack_into('<I',buf,0,MAGIC); struct.pack_into('<H',buf,4,VERSION)
    struct.pack_into('<H',buf,6,HEADER_SIZE); struct.pack_into('<H',buf,8,WIDTH)
    struct.pack_into('<H',buf,10,HEIGHT); struct.pack_into('<H',buf,12,n)
    struct.pack_into('<H',buf,14,fps); struct.pack_into('<I',buf,16,fto)
    struct.pack_into('<I',buf,20,fdo); struct.pack_into('<I',buf,24,ps)
    struct.pack_into('<I',buf,28,0); struct.pack_into('<I',buf,32,0)
    struct.pack_into('<H',buf,36,ss); struct.pack_into('<H',buf,38,ss)
    struct.pack_into('<H',buf,40,PALETTE_ENTRIES); struct.pack_into('<H',buf,42,0)
    to,ddo=fto,fdo
    for data,codec,flags in fd:
        struct.pack_into('<I',buf,to,ddo); struct.pack_into('<I',buf,to+4,len(data))
        struct.pack_into('<H',buf,to+8,1000//fps); buf[to+10]=codec; buf[to+11]=flags
        struct.pack_into('<H',buf,to+12,ss); struct.pack_into('<H',buf,to+14,ss)
        buf[ddo:ddo+len(data)]=data; to+=FRAME_ENTRY_SIZE; ddo+=len(data)
    crc=zlib.crc32(buf)&0xFFFFFFFF; struct.pack_into('<I',buf,28,crc)
    return bytes(buf)


def process(mp4, out, ss=480, zoom=ZOOM):
    import tempfile
    print(f"  {mp4.name} -> {out.name} (zoom={zoom}x)")
    with tempfile.TemporaryDirectory() as tmp:
        td = Path(tmp)
        palette_png, frames = mp4_to_palette_frames(mp4, td, ss, zoom=zoom)
        if not frames:
            raise RuntimeError("no frames")
        if not frames:
            raise RuntimeError("no frames")
        palette_rgb, pal = read_palette_rgb(palette_png)
        print(f"    building LUT for {len(palette_rgb)} colors...")
        lut = build_lut(palette_rgb)
        ef = []
        prev = None
        for i, fp in enumerate(frames):
            idx = frame_to_indices(fp, lut)
            d, c, f = enc_frame(pal, idx, prev, ss, i == 0)
            ef.append((d, c, f))
            prev = idx
        eb4 = pack_ebaj4(ef, FPS, ss)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(eb4)
        print(f"    {len(eb4)} bytes, {len(ef)} frames")


def preview(mp4, out, zoom=1.0):
    """Generate a static PNG preview from the middle frame."""
    import tempfile
    from PIL import Image
    with tempfile.TemporaryDirectory() as tmp:
        td = Path(tmp)
        _, frames = mp4_to_palette_frames(mp4, td, zoom=zoom)
        if frames:
            mid = frames[len(frames) // 2]
            Image.open(mid).save(out, "PNG")


def main():
    print("="*60); print("Factory Animation Encoder"); print("="*60)
    try:
        subprocess.run(["ffmpeg","-version"],capture_output=True,check=True)
    except: print("ERROR: ffmpeg not found"); sys.exit(1)
    try: from PIL import Image
    except: print("ERROR: pip install pillow numpy"); sys.exit(1)
    pairs=find_pairs()
    print(f"\nFound {len(pairs)} pair(s):")
    for pid,f1,f2 in pairs: print(f"  {pid}: {f1.name} / {f2.name if f2 else 'N/A'}")
    print("\nEncoding...")
    for pid,f1,f2 in pairs:
        z = get_zoom(pid)
        process(f1, OUT_DIR/"first_half"/f"{pid}.eb4", zoom=z)
        if f2: process(f2, OUT_DIR/"second_half"/f"{pid}.eb4", zoom=z)
    # Special transition animations (third_half)
    third = find_third()
    if third:
        print(f"\nSpecial transitions ({len(third)}):")
        for eid, mp4 in third:
            # Use source animation's zoom for third_half
            z = get_zoom(eid)
            process(mp4, OUT_DIR/"third_half"/f"{eid}.eb4", zoom=z)
    print("\nPreviews...")
    pd=ROOT/"app_gif"/"assets"/"factory_previews"; pd.mkdir(parents=True,exist_ok=True)
    # Build transition map from third_half files
    third_map = {}  # { "F007": {"F006": "assets/.../F007_F006_third.mp4"} }
    for eid, mp4 in third:
        parts = eid.split('_')  # "F007_F006" -> ["F007", "F006"]
        if len(parts) == 2:
            src, dst = parts[0], parts[1]
            z = get_zoom(src)
            out_name = f"{eid}_third.mp4"
            make_dial_mp4(mp4, pd/out_name, zoom=z)
            print(f"  {pd/out_name} (third_half {src}->{dst})")
            third_map.setdefault(src, {})[dst] = f"assets/factory_previews/{out_name}"

    manifest = []
    for pid,f1,f2 in pairs:
        z = get_zoom(pid)
        preview(f1, pd/f"{pid}.png", zoom=1.0)
        make_dial_mp4(f1, pd/f"{pid}_first.mp4", zoom=z)
        if f2: make_dial_mp4(f2, pd/f"{pid}_second.mp4", zoom=z)
        print(f"  {pid}: grid PNG + first/second MP4")
        entry = {
            "id": pid, "name": pid,
            "previewAsset": f"assets/factory_previews/{pid}.png",
            "firstVideo": f"assets/factory_previews/{pid}_first.mp4",
        }
        if f2:
            entry["secondVideo"] = f"assets/factory_previews/{pid}_second.mp4"
        if pid in third_map:
            entry["transitions"] = third_map[pid]
        else:
            entry["transitions"] = {}
        manifest.append(entry)
    # Write manifest
    import json
    manifest_path = pd / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"  {manifest_path} ({len(manifest)} entries)")
    print(f"\nDone! Output: {OUT_DIR}\nCopy to SD card.")


if __name__=="__main__": main()
