'use strict';

/* Server-side video transcoding: FFmpeg does the crop/scale/fps sampling
 * (the phone only sends the source video + crop parameters), then the
 * EBAJ4 encoder packs the frames. */

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ebaj = require('./ebaj');

const DEFAULT_OUTPUT_FPS = 60;
const MAX_OUTPUT_FPS = 80;
/* The original S3 player validates EBAJ4 fps against 25..40.  P4's JPEG
 * path can use the general 80 fps ceiling, but an S3 package above 40 fps is
 * rejected only after the entire upload has been received. */
const MAX_S3_OUTPUT_FPS = 40;
const P4_JPEG_QUALITY = 5;

function normalizeTranscodeHardware(value) {
  const hardware = String(value || '').trim().toLowerCase();
  if (hardware === 'esp32p4' || hardware === 'p4') {
    return 'esp32p4';
  }
  if (hardware === 'esp32s3' || hardware === 's3') {
    return 'esp32s3';
  }
  throw new Error(`server transcode is not supported for hardware: ${hardware || 'unknown'}`);
}

function parseFrameRate(value) {
  if (typeof value === 'number') {
    return Number.isFinite(value) && value > 0 ? value : 0;
  }
  const match = String(value || '').trim().match(/^(\d+(?:\.\d+)?)\/(\d+(?:\.\d+)?)$/);
  if (match) {
    const numerator = Number(match[1]);
    const denominator = Number(match[2]);
    return denominator > 0 ? numerator / denominator : 0;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function selectOutputFps(sourceFps, requestedMaxFps = MAX_OUTPUT_FPS) {
  const requested = Math.round(Number(requestedMaxFps));
  const cap = Number.isFinite(requested) && requested > 0
    ? Math.min(requested, MAX_OUTPUT_FPS)
    : MAX_OUTPUT_FPS;
  const source = Number(sourceFps);
  if (!Number.isFinite(source) || source <= 0) {
    return Math.min(DEFAULT_OUTPUT_FPS, cap);
  }
  return Math.max(1, Math.min(Math.round(source), cap));
}

function ffmpegAvailable() {
  return new Promise((resolve) => {
    const child = spawn('ffmpeg', ['-version'], { stdio: 'ignore' });
    child.on('error', () => resolve(false));
    child.on('exit', (code) => resolve(code === 0));
  });
}

function ffprobeVideo(inputPath) {
  return new Promise((resolve, reject) => {
    const child = spawn('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=width,height,duration,avg_frame_rate,r_frame_rate:format=duration',
      '-of', 'json',
      inputPath,
    ]);
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => reject(error));
    child.on('exit', (code) => {
      if (code !== 0) {
        reject(new Error(`ffprobe failed: ${stderr || `exit ${code}`}`));
        return;
      }
      try {
        const info = JSON.parse(stdout);
        const stream = (info.streams || []).find((item) => item.codec_type === 'video' || item.width);
        const duration = Number(stream && stream.duration ? stream.duration : (info.format && info.format.duration) || 0);
        resolve({
          width: stream ? Number(stream.width) : 0,
          height: stream ? Number(stream.height) : 0,
          durationSec: Number.isFinite(duration) ? duration : 0,
          fps: stream
            ? (parseFrameRate(stream.avg_frame_rate) || parseFrameRate(stream.r_frame_rate))
            : 0,
        });
      } catch (error) {
        reject(error);
      }
    });
  });
}

/* Sample the video with FFmpeg into a concatenated MJPEG stream.
 * crop: { scale, offsetX, offsetY } - same semantics as the app's
 * CropTransform (cover fit, centered, then scaled/offset). hflip is baked
 * into the P4 payload because the panel scan direction is mirrored. */
function sampleVideoToMjpeg(inputPath, mjpegPath, { fps, streamSize, crop }) {
  return new Promise((resolve, reject) => {
    const s = Number(crop.scale) || 1;
    const ox = Number(crop.offsetX) || 0;
    const oy = Number(crop.offsetY) || 0;

    // cover scale: scale source so it covers streamSize, then apply crop.scale
    const scaleExpr = `scale=trunc(iw*${s}*${streamSize}/min(iw\\,ih)/2)*2:trunc(ih*${s}*${streamSize}/min(iw\\,ih)/2)*2`;
    const cropExpr = `crop=${streamSize}:${streamSize}:'(iw-${streamSize})/2+${ox}*${streamSize}':'(ih-${streamSize})/2+${oy}*${streamSize}'`;
    const vf = `${scaleExpr},${cropExpr},hflip,fps=${fps}`;

    const args = [
      '-v', 'error', '-i', inputPath, '-an', '-vf', vf,
      '-c:v', 'mjpeg', '-q:v', String(P4_JPEG_QUALITY),
      '-pix_fmt', 'yuvj420p', '-f', 'image2pipe', '-y', mjpegPath,
    ];
    const child = spawn('ffmpeg', args);
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => reject(error));
    child.on('exit', (code) => {
      if (code !== 0) {
        reject(new Error(`ffmpeg failed: ${stderr || `exit ${code}`}`));
        return;
      }
      resolve();
    });
  });
}

function sampleVideoToRgb24(inputPath, rgbPath, { fps, streamSize, crop }) {
  return new Promise((resolve, reject) => {
    const s = Number(crop.scale) || 1;
    const ox = Number(crop.offsetX) || 0;
    const oy = Number(crop.offsetY) || 0;
    const scaleExpr = `scale=trunc(iw*${s}*${streamSize}/min(iw\\,ih)/2)*2:trunc(ih*${s}*${streamSize}/min(iw\\,ih)/2)*2`;
    const cropExpr = `crop=${streamSize}:${streamSize}:'(iw-${streamSize})/2+${ox}*${streamSize}':'(ih-${streamSize})/2+${oy}*${streamSize}'`;
    const vf = `${scaleExpr},${cropExpr},fps=${fps}`;
    const args = [
      '-v', 'error', '-i', inputPath, '-an', '-vf', vf,
      '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-y', rgbPath,
    ];
    const child = spawn('ffmpeg', args);
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => reject(error));
    child.on('exit', (code) => {
      if (code !== 0) {
        reject(new Error(`ffmpeg failed: ${stderr || `exit ${code}`}`));
        return;
      }
      resolve();
    });
  });
}

function packS3RgbFile(rgbPath, fps, streamSize) {
  const frameBytes = streamSize * streamSize * 3;
  const size = fs.statSync(rgbPath).size;
  if (size === 0 || size % frameBytes !== 0) {
    throw new Error('FFmpeg produced an incomplete RGB frame stream');
  }
  const frameCount = size / frameBytes;
  if (frameCount > 0xffff) {
    throw new Error('RGB frame count exceeds EBAJ4 limit');
  }
  const descriptor = fs.openSync(rgbPath, 'r');
  const rgb = Buffer.allocUnsafe(frameBytes);
  const frames = [];
  try {
    for (let index = 0; index < frameCount; index += 1) {
      const bytesRead = fs.readSync(descriptor, rgb, 0, frameBytes, index * frameBytes);
      if (bytesRead !== frameBytes) {
        throw new Error('failed to read a complete RGB frame');
      }
      frames.push(ebaj.quantizeToIndexed(rgb, streamSize, streamSize));
    }
  } finally {
    fs.closeSync(descriptor);
  }
  return ebaj.packFrames(frames, fps, streamSize);
}

function splitJpegFrames(stream) {
  const frames = [];
  let cursor = 0;
  while (cursor < stream.length) {
    const start = stream.indexOf(Buffer.from([0xff, 0xd8]), cursor);
    if (start < 0) break;
    const end = stream.indexOf(Buffer.from([0xff, 0xd9]), start + 2);
    if (end < 0) {
      throw new Error('truncated MJPEG frame');
    }
    frames.push(stream.subarray(start, end + 2));
    cursor = end + 2;
  }
  if (frames.length === 0) {
    throw new Error('FFmpeg produced no JPEG frames');
  }
  return frames;
}

/* Hardware-specific EBAJ4 pipeline. P4 uses JPEG frame payloads for its
 * hardware decoder; S3 uses indexed key/tile/repeat frames understood by
 * the original S3 player. */
async function transcodeToEbaj({ inputPath, outputPath, fps, streamSize, crop, hardware }) {
  const target = normalizeTranscodeHardware(hardware);
  const suffix = target === 'esp32p4' ? 'mjpg' : 'rgb';
  const intermediatePath = path.join(
    os.tmpdir(),
    `ebaj_${Date.now()}_${Math.random().toString(36).slice(2)}.${suffix}`,
  );
  try {
    let packed;
    if (target === 'esp32p4') {
      await sampleVideoToMjpeg(inputPath, intermediatePath, { fps, streamSize, crop });
      const jpegFrames = splitJpegFrames(fs.readFileSync(intermediatePath));
      packed = ebaj.packJpegFrames(jpegFrames, fps, streamSize);
    } else {
      await sampleVideoToRgb24(inputPath, intermediatePath, { fps, streamSize, crop });
      packed = packS3RgbFile(intermediatePath, fps, streamSize);
    }
    const { packageBytes, frameCount: packedFrames } = packed;
    fs.writeFileSync(outputPath, packageBytes);
    return { packageBytes, frameCount: packedFrames, fps, streamSize, hardware: target };
  } finally {
    fs.rmSync(intermediatePath, { force: true });
  }
}

module.exports = {
  DEFAULT_OUTPUT_FPS,
  MAX_OUTPUT_FPS,
  MAX_S3_OUTPUT_FPS,
  ffmpegAvailable,
  ffprobeVideo,
  normalizeTranscodeHardware,
  parseFrameRate,
  selectOutputFps,
  splitJpegFrames,
  transcodeToEbaj,
};
