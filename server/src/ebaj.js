'use strict';

/* EBAJ4 encoder for the server side (Node.js).
 *
 * Mirrors the format produced by the Android app's EbajEncoder so the
 * firmware decoder (BadgeIndexed.c / BadgeLz4.c) consumes it unchanged:
 *  - header: 44 bytes (magic "BAJ4", version 4)
 *  - frame table: 16 bytes per frame
 *  - KEY frame: 512-byte RGB565 palette + indexed pixels
 *  - TILE frame: palette + tile count + [tile index + 16x16 tile bytes]
 *  - REPEAT frame: empty payload
 *  - payloads are LZ4-compressed when smaller (4-byte LE raw size prefix)
 *
 * The visual pipeline matches the app: cover-crop render (done by FFmpeg),
 * rgb332 quantization with sharpen + 4x4 ordered dither.
 */

const TILE_SIZE = 16;
const PALETTE_ENTRIES = 256;
const PALETTE_BYTES = PALETTE_ENTRIES * 2; // RGB565 LE
const HEADER_SIZE = 44;
const FRAME_ENTRY_SIZE = 16;
const MAGIC = 0x344a4142; // "BAJ4"
const VERSION = 4;
const CODEC_INDEXED_KEY = 0x10;
const CODEC_INDEXED_TILE = 0x11;
const CODEC_INDEXED_REPEAT = 0x12;
const CODEC_JPEG = 0x20;
const FRAME_FLAG_LZ4 = 0x80;
const SHARPEN_PERCENT = 106;
const DITHER_4X4 = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];

function clampInt(value, lo, hi) {
  return value < lo ? lo : value > hi ? hi : value;
}

function sharpenForIndexed(value) {
  const centered = value - 128;
  return clampInt(128 + Math.trunc(centered * SHARPEN_PERCENT / 100), 0, 255);
}

function orderedDither(x, y, bits) {
  const levelStep = bits === 2 ? 64 : 32;
  const threshold = DITHER_4X4[((y & 3) << 2) | (x & 3)] - 8;
  return Math.trunc(threshold * levelStep / 16);
}

/* RGB24 frame (width*height*3) -> indexed bytes (width*height). */
function quantizeToIndexed(rgb, width, height) {
  const out = Buffer.alloc(width * height);
  let offset = 0;
  for (let y = 0; y < height; y += 1) {
    const rowOffset = y * width;
    for (let x = 0; x < width; x += 1) {
      const src = (rowOffset + x) * 3;
      const red = clampInt(sharpenForIndexed(rgb[src]) + orderedDither(x, y, 3), 0, 255);
      const green = clampInt(sharpenForIndexed(rgb[src + 1]) + orderedDither(x, y, 3), 0, 255);
      const blue = clampInt(sharpenForIndexed(rgb[src + 2]) + orderedDither(x, y, 2), 0, 255);
      out[offset++] = ((red >>> 5) << 5) | ((green >>> 5) << 2) | (blue >>> 6);
    }
  }
  return out;
}

function rgb332Palette() {
  const palette = Buffer.alloc(PALETTE_BYTES);
  let offset = 0;
  for (let index = 0; index < PALETTE_ENTRIES; index += 1) {
    const red = ((index >>> 5) & 0x07) * 255 / 7;
    const green = ((index >>> 2) & 0x07) * 255 / 7;
    const blue = (index & 0x03) * 255 / 3;
    const rgb565 = ((red & 0xf8) << 8) | ((green & 0xfc) << 3) | (blue >>> 3);
    palette[offset++] = rgb565 & 0xff;
    palette[offset++] = (rgb565 >>> 8) & 0xff;
  }
  return palette;
}

/* Standard LZ4 block compressor (raw block format, no frame header).
 * The firmware side decompresses with a plain LZ4 block decoder, so this
 * only has to be a correct LZ4 block stream. */
function lz4Compress(data) {
  if (data.length < 8) {
    return Buffer.from(data);
  }
  const srcEnd = data.length;
  const out = Buffer.alloc(srcEnd + Math.floor(srcEnd / 255) + 32);
  let dst = 0;
  let src = 0;
  let litStart = 0;

  const hashLog = 14;
  const hashSize = 1 << hashLog;
  const hashTable = new Int32Array(hashSize);
  const minMatch = 4;
  const lastMatchPos = srcEnd - minMatch;

  const hashAt = (pos) => (((data[pos] & 0xff) |
    ((data[pos + 1] & 0xff) << 8) |
    ((data[pos + 2] & 0xff) << 16) |
    ((data[pos + 3] & 0xff) << 24)) * 2654435761) >>> (32 - hashLog);

  while (src < lastMatchPos) {
    const idx = hashAt(src);
    const ref = hashTable[idx];
    hashTable[idx] = src;

    if (ref === 0 || src - ref > 65535 ||
      data[ref] !== data[src] || data[ref + 1] !== data[src + 1] ||
      data[ref + 2] !== data[src + 2] || data[ref + 3] !== data[src + 3]) {
      src += 1;
      continue;
    }

    let matchLen = minMatch;
    const maxMatch = Math.min(srcEnd - src, 0x1f + minMatch - 1);
    while (matchLen < maxMatch && data[ref + matchLen] === data[src + matchLen]) {
      matchLen += 1;
    }

    const litLen = src - litStart;
    const token = (Math.min(litLen, 15) << 4) | Math.min(matchLen - minMatch, 15);
    out[dst++] = token;

    let extra = litLen - 15;
    while (extra >= 255) {
      out[dst++] = 255;
      extra -= 255;
    }
    if (litLen >= 15) out[dst++] = extra;

    data.copy(out, dst, litStart, src);
    dst += litLen;

    out[dst++] = (src - ref) & 0xff;
    out[dst++] = ((src - ref) >>> 8) & 0xff;

    extra = matchLen - minMatch - 15;
    while (extra >= 255) {
      out[dst++] = 255;
      extra -= 255;
    }
    if (matchLen - minMatch >= 15) out[dst++] = extra;

    src += matchLen;
    litStart = src;
  }

  const litLen = srcEnd - litStart;
  if (litLen > 0) {
    const token = Math.min(litLen, 15) << 4;
    out[dst++] = token;
    let extra = litLen - 15;
    while (extra >= 255) {
      out[dst++] = 255;
      extra -= 255;
    }
    if (litLen >= 15) out[dst++] = extra;
    data.copy(out, dst, litStart, srcEnd);
    dst += litLen;
  }

  return out.subarray(0, dst);
}

function encodeIndexedKey(indexed) {
  const out = Buffer.alloc(PALETTE_BYTES + indexed.length);
  rgb332Palette().copy(out, 0);
  indexed.copy(out, PALETTE_BYTES);
  return out;
}

function encodeIndexedTile(indexed, previous, streamSize) {
  const tileCols = streamSize / TILE_SIZE;
  const tileRows = streamSize / TILE_SIZE;
  /* Worst case: every tile changed. Unlike the app's auto-growing ByteSink,
   * Node Buffers never grow - size it up front or copies silently truncate. */
  const maxBytes = PALETTE_BYTES + 2 +
    tileCols * tileRows * (2 + TILE_SIZE * TILE_SIZE);
  const out = Buffer.alloc(maxBytes);
  rgb332Palette().copy(out, 0);
  out[PALETTE_BYTES] = 0;
  out[PALETTE_BYTES + 1] = 0;
  let writeOffset = PALETTE_BYTES + 2;

  let changedTiles = 0;
  for (let tileY = 0; tileY < tileRows; tileY += 1) {
    for (let tileX = 0; tileX < tileCols; tileX += 1) {
      let changed = false;
      for (let row = 0; row < TILE_SIZE && !changed; row += 1) {
        const offset = ((tileY * TILE_SIZE + row) * streamSize) + tileX * TILE_SIZE;
        const end = offset + TILE_SIZE;
        for (let index = offset; index < end; index += 1) {
          if (indexed[index] !== previous[index]) {
            changed = true;
            break;
          }
        }
      }
      if (!changed) {
        continue;
      }

      const tileIndex = tileY * tileCols + tileX;
      out[writeOffset++] = tileIndex & 0xff;
      out[writeOffset++] = (tileIndex >>> 8) & 0xff;
      for (let row = 0; row < TILE_SIZE; row += 1) {
        const offset = ((tileY * TILE_SIZE + row) * streamSize) + tileX * TILE_SIZE;
        indexed.copy(out, writeOffset, offset, offset + TILE_SIZE);
        writeOffset += TILE_SIZE;
      }
      changedTiles += 1;
    }
  }

  out[PALETTE_BYTES] = changedTiles & 0xff;
  out[PALETTE_BYTES + 1] = (changedTiles >>> 8) & 0xff;
  return out.subarray(0, writeOffset);
}

function compressAndWrap(raw, codec, delayMs, streamSize) {
  const compressed = lz4Compress(raw);
  if (compressed.length + 4 < raw.length) {
    const wrapped = Buffer.alloc(compressed.length + 4);
    wrapped.writeUInt32LE(raw.length, 0);
    compressed.copy(wrapped, 4);
    return { data: wrapped, codec, delayMs, flags: FRAME_FLAG_LZ4, width: streamSize, height: streamSize };
  }
  return { data: Buffer.from(raw), codec, delayMs, flags: 0, width: streamSize, height: streamSize };
}

function encodeFrame(indexed, previous, delayMs, streamSize, forceKeyframe) {
  if (!forceKeyframe && previous && indexed.equals(previous)) {
    return { data: Buffer.alloc(0), codec: CODEC_INDEXED_REPEAT, delayMs, flags: 0, width: streamSize, height: streamSize };
  }
  const key = encodeIndexedKey(indexed);
  if (!forceKeyframe && previous) {
    const tile = encodeIndexedTile(indexed, previous, streamSize);
    if (tile.length < key.length) {
      return compressAndWrap(tile, CODEC_INDEXED_TILE, delayMs, streamSize);
    }
  }
  return compressAndWrap(key, CODEC_INDEXED_KEY, delayMs, streamSize);
}

function frameDelayMs(fps) {
  return Math.floor((1000 + fps / 2) / fps);
}

/* Pack indexed frames into a complete EBAJ4 package buffer.
 * frames: Array<Buffer> of indexed (width*height) bytes. */
function packFrames(frames, fps, streamSize) {
  const delayMs = frameDelayMs(fps);
  const encoded = [];
  let previous = null;
  for (let index = 0; index < frames.length; index += 1) {
    const frame = encodeFrame(frames[index], previous, delayMs, streamSize, index === 0);
    encoded.push(frame);
    previous = frames[index];
  }

  const dataBytes = encoded.reduce((sum, frame) => sum + frame.data.length, 0);
  const frameTableOffset = HEADER_SIZE;
  const frameDataOffset = HEADER_SIZE + encoded.length * FRAME_ENTRY_SIZE;
  const packageSize = frameDataOffset + dataBytes;

  const out = Buffer.alloc(packageSize);
  out.writeUInt32LE(MAGIC, 0);
  out.writeUInt16LE(VERSION, 4);
  out.writeUInt16LE(HEADER_SIZE, 6);
  out.writeUInt16LE(480, 8); // panel width
  out.writeUInt16LE(480, 10); // panel height
  out.writeUInt16LE(encoded.length, 12);
  out.writeUInt16LE(fps, 14);
  out.writeUInt32LE(frameTableOffset, 16);
  out.writeUInt32LE(frameDataOffset, 20);
  out.writeUInt32LE(packageSize, 24);
  out.writeUInt32LE(0, 28); // package_crc32
  out.writeUInt32LE(0, 32); // flags
  out.writeUInt16LE(streamSize, 36);
  out.writeUInt16LE(streamSize, 38);
  out.writeUInt16LE(PALETTE_ENTRIES, 40);
  out.writeUInt16LE(0, 42);

  let tableOffset = frameTableOffset;
  let dataOffset = frameDataOffset;
  for (const frame of encoded) {
    out.writeUInt32LE(dataOffset, tableOffset);
    out.writeUInt32LE(frame.data.length, tableOffset + 4);
    out.writeUInt16LE(frame.delayMs, tableOffset + 8);
    out[tableOffset + 10] = frame.codec;
    out[tableOffset + 11] = frame.flags;
    out.writeUInt16LE(frame.width, tableOffset + 12);
    out.writeUInt16LE(frame.height, tableOffset + 14);
    frame.data.copy(out, dataOffset);
    tableOffset += FRAME_ENTRY_SIZE;
    dataOffset += frame.data.length;
  }

  return { packageBytes: out, frameCount: encoded.length, fps, streamSize };
}

/* P4-only frame payloads. The outer EBAJ4 header/table stays unchanged so
 * upload, review, storage and CRC handling remain backward compatible; the
 * frame codec selects the P4 JPEG hardware decoder. */
function packJpegFrames(jpegFrames, fps, streamSize) {
  if (!Array.isArray(jpegFrames) || jpegFrames.length === 0) {
    throw new Error('JPEG frame list is empty');
  }
  if (jpegFrames.length > 0xffff) {
    throw new Error('JPEG frame count exceeds EBAJ4 limit');
  }

  const delayMs = frameDelayMs(fps);
  const dataBytes = jpegFrames.reduce((sum, frame) => sum + frame.length, 0);
  const frameTableOffset = HEADER_SIZE;
  const frameDataOffset = HEADER_SIZE + jpegFrames.length * FRAME_ENTRY_SIZE;
  const packageSize = frameDataOffset + dataBytes;
  const out = Buffer.alloc(packageSize);

  out.writeUInt32LE(MAGIC, 0);
  out.writeUInt16LE(VERSION, 4);
  out.writeUInt16LE(HEADER_SIZE, 6);
  out.writeUInt16LE(480, 8);
  out.writeUInt16LE(480, 10);
  out.writeUInt16LE(jpegFrames.length, 12);
  out.writeUInt16LE(fps, 14);
  out.writeUInt32LE(frameTableOffset, 16);
  out.writeUInt32LE(frameDataOffset, 20);
  out.writeUInt32LE(packageSize, 24);
  out.writeUInt32LE(0, 28);
  out.writeUInt32LE(0, 32);
  out.writeUInt16LE(streamSize, 36);
  out.writeUInt16LE(streamSize, 38);
  /* Kept at 256 for compatibility with existing EBAJ4 header validation;
   * JPEG payloads do not contain or use this palette. */
  out.writeUInt16LE(PALETTE_ENTRIES, 40);
  out.writeUInt16LE(0, 42);

  let tableOffset = frameTableOffset;
  let dataOffset = frameDataOffset;
  for (const frame of jpegFrames) {
    if (!Buffer.isBuffer(frame) || frame.length < 4 ||
        frame[0] !== 0xff || frame[1] !== 0xd8 ||
        frame[frame.length - 2] !== 0xff || frame[frame.length - 1] !== 0xd9) {
      throw new Error('invalid JPEG frame');
    }
    out.writeUInt32LE(dataOffset, tableOffset);
    out.writeUInt32LE(frame.length, tableOffset + 4);
    out.writeUInt16LE(delayMs, tableOffset + 8);
    out[tableOffset + 10] = CODEC_JPEG;
    out[tableOffset + 11] = 0;
    out.writeUInt16LE(streamSize, tableOffset + 12);
    out.writeUInt16LE(streamSize, tableOffset + 14);
    frame.copy(out, dataOffset);
    tableOffset += FRAME_ENTRY_SIZE;
    dataOffset += frame.length;
  }

  return { packageBytes: out, frameCount: jpegFrames.length, fps, streamSize };
}

/* Encode an in-memory RGB24 frame stream into an EBAJ4 package.
 * rgbStream: Buffer of frameCount * width * height * 3 bytes. */
function encodeFromRgbFrames(rgbStream, frameCount, width, height, fps) {
  const frames = [];
  const frameBytes = width * height * 3;
  for (let index = 0; index < frameCount; index += 1) {
    const frame = rgbStream.subarray(index * frameBytes, (index + 1) * frameBytes);
    frames.push(quantizeToIndexed(frame, width, height));
  }
  return packFrames(frames, fps, width);
}

module.exports = {
  encodeFromRgbFrames,
  packFrames,
  packJpegFrames,
  quantizeToIndexed,
  frameDelayMs,
  HEADER_SIZE,
  FRAME_ENTRY_SIZE,
  MAGIC,
  VERSION,
  CODEC_JPEG,
};
