'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const ebaj = require('../src/ebaj');

test('packs P4 JPEG frames without changing the EBAJ4 container layout', () => {
  const frames = [
    Buffer.from([0xff, 0xd8, 0x01, 0xff, 0xd9]),
    Buffer.from([0xff, 0xd8, 0x02, 0x03, 0xff, 0xd9]),
  ];

  const result = ebaj.packJpegFrames(frames, 60, 480);
  const bytes = result.packageBytes;
  const firstEntry = ebaj.HEADER_SIZE;
  const secondEntry = firstEntry + ebaj.FRAME_ENTRY_SIZE;
  const dataOffset = ebaj.HEADER_SIZE + frames.length * ebaj.FRAME_ENTRY_SIZE;

  assert.equal(bytes.readUInt32LE(0), ebaj.MAGIC);
  assert.equal(bytes.readUInt16LE(12), 2);
  assert.equal(bytes.readUInt16LE(14), 60);
  assert.equal(bytes[firstEntry + 10], ebaj.CODEC_JPEG);
  assert.equal(bytes[secondEntry + 10], ebaj.CODEC_JPEG);
  assert.equal(bytes.readUInt32LE(firstEntry), dataOffset);
  assert.equal(bytes.readUInt32LE(firstEntry + 4), frames[0].length);
  assert.deepEqual(bytes.subarray(dataOffset, dataOffset + frames[0].length), frames[0]);
});
