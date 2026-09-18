'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  parseFrameRate,
  normalizeTranscodeHardware,
  selectOutputFps,
  MAX_S3_OUTPUT_FPS,
  splitJpegFrames,
} = require('../src/transcode');

test('server transcoding selects a distinct S3 or P4 package format', () => {
  assert.equal(normalizeTranscodeHardware('ESP32P4'), 'esp32p4');
  assert.equal(normalizeTranscodeHardware('p4'), 'esp32p4');
  assert.equal(normalizeTranscodeHardware('ESP32S3'), 'esp32s3');
  assert.equal(normalizeTranscodeHardware('s3'), 'esp32s3');
  assert.throws(() => normalizeTranscodeHardware('esp32c3'), /not supported/);
});

test('parseFrameRate reads common FFprobe rational frame rates', () => {
  assert.equal(parseFrameRate('30/1'), 30);
  assert.ok(Math.abs(parseFrameRate('30000/1001') - 29.97002997) < 0.000001);
  assert.equal(parseFrameRate('0/0'), 0);
  assert.equal(parseFrameRate('not-a-rate'), 0);
});

test('selectOutputFps preserves source cadence up to the 80 fps limit', () => {
  assert.equal(selectOutputFps(30, 80), 30);
  assert.equal(selectOutputFps(59.94, 80), 60);
  assert.equal(selectOutputFps(80, 80), 80);
  assert.equal(selectOutputFps(120, 80), 80);
});

test('selectOutputFps falls back to 60 fps and never accepts a cap above 80', () => {
  assert.equal(selectOutputFps(0, 80), 60);
  assert.equal(selectOutputFps(Number.NaN, 80), 60);
  assert.equal(selectOutputFps(120, 120), 80);
});

test('S3 transcode cap keeps packages within the firmware 40 fps limit', () => {
  assert.equal(selectOutputFps(60, MAX_S3_OUTPUT_FPS), 40);
  assert.equal(selectOutputFps(30, MAX_S3_OUTPUT_FPS), 30);
});

test('splitJpegFrames extracts each complete MJPEG image', () => {
  const stream = Buffer.from([
    0x00, 0xff, 0xd8, 0x11, 0xff, 0x00, 0x22, 0xff, 0xd9,
    0xff, 0xd8, 0x33, 0x44, 0xff, 0xd9, 0x55,
  ]);
  assert.deepEqual(
    splitJpegFrames(stream).map((frame) => [...frame]),
    [
      [0xff, 0xd8, 0x11, 0xff, 0x00, 0x22, 0xff, 0xd9],
      [0xff, 0xd8, 0x33, 0x44, 0xff, 0xd9],
    ],
  );
});
