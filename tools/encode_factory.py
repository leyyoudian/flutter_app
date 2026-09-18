#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Factory animation encoder for ESP32-S3 (EBAJ4) and ESP32-P4 (EBAJ5)."""

import os
import json
import subprocess
import struct
import sys
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "animation_comd"
OUT_DIR = ROOT / "animation_sd"
OUT_DIR_P4 = ROOT / "animation_sd_p4"

S3_FPS = 40
# P4 panel runs at exactly 90.0 Hz (pclk = 90 * H_TOTAL * V_TOTAL). Source
# assets must be 90 fps so frames map 1:1 onto scanout; 100 fps assets beat
# against the 90 Hz panel (frames alternate between one and two VSYNCs),
# which reads as judder and vertical-shift tearing during switches.
P4_FPS = 90
FPS = S3_FPS
WIDTH = 480
HEIGHT = 480
ZOOM = 1.1  # default scale-up factor

def get_zoom(pid):
    """3/6/7/18 no zoom(1.0), F008-F017 1.3x, others 1.1x."""
    try:
        n = int(pid[1:])  # "F003" -> 3
        if n in (3, 6, 7, 18):
            return 1.0
        if 8 <= n <= 17:
            return 1.3
    except ValueError:
        pass
    return ZOOM  # default 1.1


def get_third_zoom(eid):
    """Special transition materials are already pre-scaled."""
    return 1.0


PALETTE_ENTRIES = 256
PALETTE_BYTES = PALETTE_ENTRIES * 2
HEADER_SIZE = 44
FRAME_ENTRY_SIZE = 16
TILE_SIZE = 16
MAGIC = 0x344A4142
VERSION = 4
MAGIC_P4 = 0x354A4142
VERSION_P4 = 5
CODEC_KEY = 0x10
CODEC_TILE = 0x11
CODEC_REPEAT = 0x12
FLAG_LZ4 = 0x80
LZ4_MIN_MATCH = 4
LZ4_HASH_LOG = 14
LZ4_HASH_SIZE = 1 << LZ4_HASH_LOG

TARGET_SPECS = {
    "s3": {
        "magic": MAGIC,
        "version": VERSION,
        "fps": S3_FPS,
        "extension": ".eb4",
    },
    "p4": {
        "magic": MAGIC_P4,
        "version": VERSION_P4,
        "fps": P4_FPS,
        "extension": ".eb5",
    },
}


def target_spec(target):
    try:
        return TARGET_SPECS[target]
    except KeyError as exc:
        raise ValueError(f"unsupported hardware target: {target}") from exc


def target_output_paths(s3_root, p4_root, folder, asset_id):
    return (
        Path(s3_root) / folder / f"{asset_id}.eb4",
        Path(p4_root) / folder / f"{asset_id}.eb5",
    )


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
    m = re.match(r'F?(\d+)', Path(name).stem, re.IGNORECASE)
    return int(m.group(1)) if m else 0


def normalize_factory_loop_id(stem):
    """Normalize loop source stems like 22 or F023 to F022/F023."""
    name = str(stem).upper()
    if name.startswith("F"):
        name = name[1:]
    number = int(name)
    if number <= 0:
        raise ValueError(f"invalid factory loop id: {stem}")
    return f"F{number:03d}"


def is_factory_loop_third_half_stem(stem):
    """F022+ files in third_half are full-loop official animations, not transitions."""
    try:
        return int(normalize_factory_loop_id(stem)[1:]) >= 22
    except (TypeError, ValueError):
        return False


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
        if is_factory_loop_third_half_stem(eid):
            continue
        result.append((eid, mp4))
    return result


def discover_factory_loop_sources(src_dir=None):
    """Scan factory_loop and F022+ third_half files for full-loop official animations."""
    src_dir = SRC_DIR if src_dir is None else Path(src_dir)
    result_by_id = {}
    loop_dir = src_dir / "factory_loop"
    if loop_dir.is_dir():
        for mp4 in sorted(loop_dir.glob("*.mp4"), key=natural_key):
            result_by_id[normalize_factory_loop_id(mp4.stem)] = mp4
    third_dir = src_dir / "third_half"
    if third_dir.is_dir():
        for mp4 in sorted(third_dir.glob("*.mp4"), key=natural_key):
            if is_factory_loop_third_half_stem(mp4.stem):
                result_by_id.setdefault(normalize_factory_loop_id(mp4.stem), mp4)
    return sorted(result_by_id.items(), key=lambda item: natural_key(item[0]))


def write_factory_import_zip(items, zip_path):
    """Write a server import ZIP with one or more complete factory candidates."""
    zip_path = Path(zip_path)
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_paths = []
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for item in sorted(items, key=lambda entry: entry["id"]):
            item_id = item["id"]
            base = f"items/{item_id}"
            manifest_rel = f"{base}/manifest.json"
            manifest_paths.append(manifest_rel)

            thumbnail_name = Path(item["thumbnail"]).name
            loop_video_name = Path(item["loopVideo"]).name
            app_thumbnail = f"app/{thumbnail_name}"
            app_loop_video = f"app/{loop_video_name}"
            zf.write(item["thumbnail"], f"{base}/{app_thumbnail}")
            zf.write(item["loopVideo"], f"{base}/{app_loop_video}")

            device_files = []
            for device_file in item.get("deviceFiles", []):
                target_path = device_file["path"].replace("\\", "/")
                source = Path(device_file["source"])
                archive_path = f"{base}/device/{target_path}"
                zf.write(source, archive_path)
                device_files.append({
                    "path": target_path,
                    "source": f"device/{target_path}",
                })

            candidate_manifest = {
                "id": item_id,
                "title": item.get("title", item_id),
                "type": item.get("type", "loop"),
                "protected": bool(item.get("protected", False)),
                "minFirmwareVersion": item.get("minFirmwareVersion", "0.1.44"),
                "appFiles": {
                    "thumbnail": app_thumbnail,
                    "loopVideo": app_loop_video,
                },
                "deviceFiles": device_files,
            }
            zf.writestr(
                manifest_rel,
                json.dumps(candidate_manifest, indent=2, sort_keys=True),
            )
        zf.writestr(
            "import.json",
            json.dumps({"items": manifest_paths}, indent=2, sort_keys=True),
        )
    return zip_path


def third_transition_pairs(eid):
    """Return (source, target) pairs represented by a third_half file stem."""
    parts = eid.split('_')
    if len(parts) == 2 and all(parts):
        return [(parts[0], parts[1])]
    if eid == "F006":
        return [("F007", "F006")]
    if eid == "F007":
        return [("F006", "F007")]
    return []


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


def mp4_to_palette_frames(mp4, tmp_dir, ss=480, zoom=ZOOM, fps=FPS):
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
        "-vf", f"fps={fps},{scale_crop},palettegen=stats_mode=diff:max_colors={PALETTE_ENTRIES}",
        str(palette_png)
    ], check=True)
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(mp4),
        "-i", str(palette_png),
        "-lavfi",
        f"fps={fps},{scale_crop}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
        str(tmp_dir / "frame_%04d.png")
    ], check=True)
    return palette_png, sorted(tmp_dir.glob("frame_*.png"))


def encode_palette(colors, target="s3"):
    """Encode an indexed palette for the selected hardware display bus."""
    target_spec(target)
    if target == "s3":
        pal = bytearray(len(colors) * 2)
        for i, (r, g, b) in enumerate(colors):
            value = rgb888_to_rgb565(r, g, b)
            struct.pack_into("<H", pal, i * 2, value)
        return bytes(pal)

    pal = bytearray(len(colors) * 3)
    for i, (r, g, b) in enumerate(colors):
        # esp_lcd's 24-bit framebuffer byte order is B, G, R. The panel uses
        # the upper six bits from each byte on its 18 physical RGB data lines.
        pal[i * 3] = b & 0xFC
        pal[i * 3 + 1] = g & 0xFC
        pal[i * 3 + 2] = r & 0xFC
    return bytes(pal)


def read_palette_rgb(palette_png, target="s3"):
    """Read ffmpeg palette PNG and encode it for S3 RGB565 or P4 RGB666."""
    from PIL import Image
    img = Image.open(palette_png).convert("RGB")
    colors = list(img.getdata())[:PALETTE_ENTRIES]
    return colors, encode_palette(colors, target)


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
    palette_bytes = len(pal)
    out = bytearray(palette_bytes + 2 + n * (2 + TILE_SIZE * TILE_SIZE))
    out[:palette_bytes] = pal
    struct.pack_into('<H', out, palette_bytes, n)
    off = palette_bytes + 2
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


def badge_fw_lz4_decompress(src, dst_len):
    """Python replica of the firmware badge_lz4_decompress (BadgeLz4.c).

    Returns the decompressed bytes or None if the stream is undecodable.
    Used to guarantee every compressed frame round-trips before shipping."""
    ip = 0
    iend = len(src)
    out = bytearray()
    while ip < iend:
        token = src[ip]
        ip += 1
        literal_len = token >> 4
        if literal_len == 15:
            while True:
                if ip >= iend:
                    return None
                s = src[ip]
                ip += 1
                literal_len += s
                if s != 255:
                    break
        if iend - ip < literal_len or dst_len - len(out) < literal_len:
            return None
        out += src[ip:ip + literal_len]
        ip += literal_len
        if ip == iend:
            break
        if iend - ip < 2:
            return None
        match_offset = src[ip] | (src[ip + 1] << 8)
        ip += 2
        if match_offset == 0 or match_offset > len(out):
            return None
        match_len = token & 0x0F
        if match_len == 15:
            while True:
                if ip >= iend:
                    return None
                s = src[ip]
                ip += 1
                match_len += s
                if s != 255:
                    break
        match_len += LZ4_MIN_MATCH
        if dst_len - len(out) < match_len:
            return None
        m = len(out) - match_offset
        for _ in range(match_len):
            out.append(out[m])
            m += 1
    return bytes(out) if len(out) == dst_len else None


def cwrap(raw):
    c = lz4_compress(raw)
    # Only ship the compressed form when the firmware decoder can fully
    # round-trip it; otherwise fall back to raw storage. This guarantees no
    # frame ever reaches the badge in an undecodable state.
    if len(c) + 4 < len(raw) and badge_fw_lz4_decompress(c, len(raw)) is not None:
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


def _verify_package(buf, spec):
    """Replay the firmware decode path (predecode + per-codec layout checks)
    against a packed asset. Raises RuntimeError on the first bad frame so
    undecodable assets never reach the SD card."""
    import struct as _struct
    n = _struct.unpack_from('<H', buf, 12)[0]
    fto = _struct.unpack_from('<I', buf, 16)[0]
    version = _struct.unpack_from('<H', buf, 4)[0]
    stream_w = _struct.unpack_from('<H', buf, 36)[0]
    stream_h = _struct.unpack_from('<H', buf, 38)[0]
    pal_entries = _struct.unpack_from('<H', buf, 40)[0]
    pal_bytes = pal_entries * (3 if version >= 5 else 2)
    frame_bytes = stream_w * stream_h
    max_tiles = (stream_w // TILE_SIZE) * (stream_h // TILE_SIZE)
    max_payload = 2 * 1024 * 1024
    for i in range(n):
        e = fto + i * FRAME_ENTRY_SIZE
        data_offset = _struct.unpack_from('<I', buf, e)[0]
        data_size = _struct.unpack_from('<I', buf, e + 4)[0]
        codec = buf[e + 10]
        flags = buf[e + 11]
        stored = buf[data_offset:data_offset + data_size]
        payload = b''
        if (flags & FLAG_LZ4) and data_size >= 4:
            header_len = _struct.unpack_from('<I', stored, 0)[0]
            if header_len > max_payload:
                raise RuntimeError(
                    f"frame {i}: implausible LZ4 header {header_len}")
            payload = badge_fw_lz4_decompress(stored[4:], header_len)
            if payload is None:
                raise RuntimeError(
                    f"frame {i}: LZ4 stream fails firmware decode "
                    f"(codec={codec:02X} stored={data_size})")
        elif data_size > 0:
            payload = stored
        if codec == CODEC_KEY:
            expected = pal_bytes + frame_bytes
            if len(payload) < expected:
                raise RuntimeError(
                    f"frame {i}: KEY payload {len(payload)} < {expected}")
        elif codec == CODEC_TILE:
            if len(payload) < pal_bytes + 2:
                raise RuntimeError(
                    f"frame {i}: TILE payload {len(payload)} too small")
            tile_count = _struct.unpack_from('<H', payload, pal_bytes)[0]
            expected = pal_bytes + 2 + tile_count * (2 + TILE_SIZE * TILE_SIZE)
            if len(payload) < expected:
                raise RuntimeError(
                    f"frame {i}: TILE payload {len(payload)} < {expected} "
                    f"(n={tile_count})")
            if tile_count > max_tiles:
                raise RuntimeError(
                    f"frame {i}: TILE n={tile_count} > {max_tiles}")
        elif codec == CODEC_REPEAT:
            pass
        else:
            raise RuntimeError(f"frame {i}: unknown codec {codec:02X}")
    return n


def pack_ebaj(fd, fps, ss, target="s3"):
    spec = target_spec(target)
    n=len(fd); db=sum(len(f[0]) for f in fd)
    fto=HEADER_SIZE; fdo=HEADER_SIZE+n*FRAME_ENTRY_SIZE; ps=fdo+db
    buf=bytearray(ps)
    struct.pack_into('<I',buf,0,spec["magic"]); struct.pack_into('<H',buf,4,spec["version"])
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


def pack_ebaj4(fd, fps, ss):
    """Compatibility wrapper retained for existing S3 callers."""
    return pack_ebaj(fd, fps, ss, "s3")


def process(mp4, out, ss=480, zoom=ZOOM, target="s3", fps=None):
    import tempfile
    spec = target_spec(target)
    fps = spec["fps"] if fps is None else fps
    print(f"  [{target.upper()}] {mp4.name} -> {out.name} ({fps} fps, zoom={zoom}x)")
    with tempfile.TemporaryDirectory() as tmp:
        td = Path(tmp)
        palette_png, frames = mp4_to_palette_frames(mp4, td, ss, zoom=zoom, fps=fps)
        if not frames:
            raise RuntimeError("no frames")
        palette_rgb, pal = read_palette_rgb(palette_png, target)
        print(f"    building LUT for {len(palette_rgb)} colors...")
        lut = build_lut(palette_rgb)
        ef = []
        prev = None
        for i, fp in enumerate(frames):
            idx = frame_to_indices(fp, lut)
            d, c, f = enc_frame(pal, idx, prev, ss, i == 0)
            ef.append((d, c, f))
            prev = idx
        package = pack_ebaj(ef, fps, ss, target)
        _verify_package(package, spec)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(package)
        print(f"    {len(package)} bytes, {len(ef)} frames, firmware-decode verified")


def process_for_s3_and_p4(mp4, folder, asset_id, zoom=ZOOM):
    s3_out, p4_out = target_output_paths(OUT_DIR, OUT_DIR_P4, folder, asset_id)
    process(mp4, s3_out, zoom=zoom, target="s3", fps=S3_FPS)
    process(mp4, p4_out, zoom=zoom, target="p4", fps=P4_FPS)


def preview_frame_score(frame):
    """Score a frame by visible non-black luminance for grid thumbnails."""
    from PIL import Image
    with Image.open(frame).convert("L") as img:
        hist = img.histogram()
    return sum(value * count for value, count in enumerate(hist))


def choose_preview_frame(frames):
    if not frames:
        return None
    return max(frames, key=preview_frame_score)


def preview_from_sources(mp4s, out, zoom=1.0):
    """Generate a static PNG preview from the most visible frame."""
    import tempfile
    from PIL import Image
    with tempfile.TemporaryDirectory() as tmp:
        td = Path(tmp)
        frames = []
        for index, mp4 in enumerate(mp4s):
            if not mp4:
                continue
            source_dir = td / f"s{index}"
            source_dir.mkdir(parents=True, exist_ok=True)
            _, source_frames = mp4_to_palette_frames(mp4, source_dir, zoom=zoom)
            frames.extend(source_frames)
        selected = choose_preview_frame(frames)
        if selected:
            Image.open(selected).save(out, "PNG")


def preview(mp4, out, zoom=1.0):
    preview_from_sources([mp4], out, zoom=zoom)


def main():
    print("="*60); print("Factory Animation Encoder (S3 + P4)"); print("="*60)
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
        process_for_s3_and_p4(f1, "first_half", pid, zoom=z)
        if f2: process_for_s3_and_p4(f2, "second_half", pid, zoom=z)
    loops = discover_factory_loop_sources()
    if loops:
        print(f"\nFactory loop animations ({len(loops)}):")
        for pid, mp4 in loops:
            process_for_s3_and_p4(mp4, "factory_loop", pid, zoom=1.0)
    # Special transition animations (third_half)
    third = find_third()
    if third:
        print(f"\nSpecial transitions ({len(third)}):")
        for eid, mp4 in third:
            z = get_third_zoom(eid)
            process_for_s3_and_p4(mp4, "third_half", eid, zoom=z)
    print("\nPreviews...")
    pd=ROOT/"app_gif"/"assets"/"factory_previews"; pd.mkdir(parents=True,exist_ok=True)
    # Build transition map from third_half files
    third_map = {}  # { "F007": {"F006": "assets/.../F007_F006_third.mp4"} }
    for eid, mp4 in third:
        transition_pairs = third_transition_pairs(eid)
        for src, dst in transition_pairs:
            z = get_third_zoom(eid)
            out_name = f"{eid}_third.mp4"
            make_dial_mp4(mp4, pd/out_name, zoom=z)
            print(f"  {pd/out_name} (third_half {src}->{dst})")
            third_map.setdefault(src, {})[dst] = f"assets/factory_previews/{out_name}"

    manifest = []
    for pid,f1,f2 in pairs:
        z = get_zoom(pid)
        preview_from_sources([f1, f2], pd/f"{pid}.png", zoom=1.0)
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
    import_items = []
    for pid, mp4 in loops:
        preview_path = pd/f"{pid}.png"
        loop_video_path = pd/f"{pid}_loop.mp4"
        preview(mp4, preview_path, zoom=1.0)
        make_dial_mp4(mp4, loop_video_path, zoom=1.0)
        print(f"  {pid}: grid PNG + loop MP4")
        manifest.append({
            "id": pid,
            "name": pid,
            "type": "loop",
            "previewAsset": f"assets/factory_previews/{pid}.png",
            "loopVideo": f"assets/factory_previews/{pid}_loop.mp4",
            "transitions": {},
        })
        import_items.append({
            "id": pid,
            "title": pid,
            "type": "loop",
            "protected": False,
            "minFirmwareVersion": "0.1.44",
            "thumbnail": preview_path,
            "loopVideo": loop_video_path,
            "deviceFiles": [
                {
                    "path": f"factory_loop/{pid}.eb4",
                    "source": OUT_DIR/"factory_loop"/f"{pid}.eb4",
                },
            ],
        })
    # Write manifest
    manifest_path = pd / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"  {manifest_path} ({len(manifest)} entries)")
    if import_items:
        zip_path = write_factory_import_zip(import_items, OUT_DIR / "factory-import.zip")
        print(f"  {zip_path} ({len(import_items)} import candidate(s))")
    print(f"\nDone! S3 output: {OUT_DIR}")
    print(f"P4 output: {OUT_DIR_P4}\nCopy the matching folder set to each SD card.")


if __name__=="__main__": main()
