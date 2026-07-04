const assert = require('node:assert');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { createApp } = require('../src/app');

function request(baseUrl, method, pathname, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const payload = body ? Buffer.from(JSON.stringify(body)) : null;
    const req = http.request(
      `${baseUrl}${pathname}`,
      {
        method,
        headers: {
          ...(payload ? { 'content-type': 'application/json', 'content-length': payload.length } : {}),
          ...headers,
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let json = null;
          try {
            json = text ? JSON.parse(text) : null;
          } catch (_) {}
          resolve({ status: res.statusCode, headers: res.headers, text, json });
        });
      },
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function multipartRequest(baseUrl, pathname, fields, file, headers = {}) {
  return new Promise((resolve, reject) => {
    const boundary = `----espBajiTest${Date.now()}${Math.random().toString(16).slice(2)}`;
    const chunks = [];
    const append = (value) => chunks.push(Buffer.from(value));

    for (const [name, value] of Object.entries(fields || {})) {
      append(`--${boundary}\r\n`);
      append(`Content-Disposition: form-data; name="${name}"\r\n\r\n`);
      append(`${value}\r\n`);
    }

    append(`--${boundary}\r\n`);
    append(
      `Content-Disposition: form-data; name="${file.name}"; filename="${file.filename}"\r\n` +
        'Content-Type: application/octet-stream\r\n\r\n',
    );
    chunks.push(Buffer.from(file.content));
    append(`\r\n--${boundary}--\r\n`);

    const payload = Buffer.concat(chunks);
    const req = http.request(
      `${baseUrl}${pathname}`,
      {
        method: 'POST',
        headers: {
          'content-type': `multipart/form-data; boundary=${boundary}`,
          'content-length': payload.length,
          ...headers,
        },
      },
      (res) => {
        const bodyChunks = [];
        res.on('data', (chunk) => bodyChunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(bodyChunks).toString('utf8');
          let json = null;
          try {
            json = text ? JSON.parse(text) : null;
          } catch (_) {}
          resolve({ status: res.statusCode, headers: res.headers, text, json });
        });
      },
    );
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

async function withServer(fn) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'esp-baji-server-'));
  const app = createApp({ dataDir, adminToken: 'test-token' });
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    await fn(`http://127.0.0.1:${port}`, dataDir);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
}

test('version endpoint returns platform manifest', async () => {
  await withServer(async (baseUrl) => {
    const res = await request(baseUrl, 'GET', '/api/version?platform=android');
    assert.equal(res.status, 200);
    assert.equal(res.json.platform, 'android');
    assert.ok(res.json.latestVersion);
    assert.ok(res.json.storeUrl);
  });
});

test('asset submission can be approved by admin', async () => {
  await withServer(async (baseUrl) => {
    const created = await request(baseUrl, 'POST', '/api/assets', {
      userId: 'u1',
      name: 'demo.eb4',
      packageBase64: Buffer.from('asset').toString('base64'),
      previewBase64: Buffer.from('preview').toString('base64'),
      crc32: '00000000',
    });
    assert.equal(created.status, 201);
    assert.equal(created.json.status, 'pending');

    const pending = await request(
      baseUrl,
      'GET',
      '/api/admin/assets?status=pending',
      null,
      { 'X-Admin-Token': 'test-token' },
    );
    assert.equal(pending.status, 200);
    assert.equal(pending.json.items.length, 1);

    const approved = await request(
      baseUrl,
      'POST',
      `/api/admin/assets/${created.json.id}/approve`,
      { reviewer: 'admin' },
      { 'X-Admin-Token': 'test-token' },
    );
    assert.equal(approved.status, 200);
    assert.equal(approved.json.status, 'approved');

    const status = await request(baseUrl, 'GET', `/api/assets/${created.json.id}`);
    assert.equal(status.status, 200);
    assert.equal(status.json.status, 'approved');
  });
});

test('asset review deduplicates packages, serves previews, and deletes old assets', async () => {
  await withServer(async (baseUrl) => {
    const created = await request(baseUrl, 'POST', '/api/assets', {
      userId: 'u1',
      name: 'first.eb4',
      packageBase64: Buffer.from('same-package').toString('base64'),
      previewBase64: Buffer.from('preview-image').toString('base64'),
      previewMime: 'image/png',
      crc32: '11111111',
      packageSize: 12,
      frameCount: 3,
      fps: 40,
    });
    assert.equal(created.status, 201);
    assert.ok(created.json.previewUrl);
    assert.ok(created.json.packageSha256);

    const approved = await request(
      baseUrl,
      'POST',
      `/api/admin/assets/${created.json.id}/approve`,
      { reviewer: 'admin' },
      { 'X-Admin-Token': 'test-token' },
    );
    assert.equal(approved.status, 200);
    assert.equal(approved.json.status, 'approved');

    const duplicate = await request(baseUrl, 'POST', '/api/assets', {
      userId: 'u1',
      name: 'second.eb4',
      packageBase64: Buffer.from('same-package').toString('base64'),
      previewBase64: Buffer.from('new-preview').toString('base64'),
      previewMime: 'image/png',
      crc32: '11111111',
      packageSize: 12,
      frameCount: 3,
      fps: 40,
    });
    assert.equal(duplicate.status, 200);
    assert.equal(duplicate.json.id, created.json.id);
    assert.equal(duplicate.json.status, 'approved');

    const list = await request(
      baseUrl,
      'GET',
      '/api/admin/assets',
      null,
      { 'X-Admin-Token': 'test-token' },
    );
    assert.equal(list.status, 200);
    assert.equal(list.json.items.length, 1);
    assert.equal(list.json.items[0].previewUrl, `/api/admin/assets/${created.json.id}/preview`);
    assert.equal(list.json.items[0].previewMime, 'image/png');

    const preview = await request(
      baseUrl,
      'GET',
      `/api/admin/assets/${created.json.id}/preview?token=test-token`,
    );
    assert.equal(preview.status, 200);
    assert.equal(preview.headers['content-type'], 'image/png');
    assert.equal(preview.text, 'preview-image');

    const deleted = await request(
      baseUrl,
      'DELETE',
      `/api/admin/assets/${created.json.id}`,
      null,
      { 'X-Admin-Token': 'test-token' },
    );
    assert.equal(deleted.status, 200);
    assert.equal(deleted.json.ok, true);

    const afterDelete = await request(
      baseUrl,
      'GET',
      '/api/admin/assets',
      null,
      { 'X-Admin-Token': 'test-token' },
    );
    assert.equal(afterDelete.status, 200);
    assert.equal(afterDelete.json.items.length, 0);
  });
});

test('admin page renders playable video previews', async () => {
  await withServer(async (baseUrl) => {
    const created = await request(baseUrl, 'POST', '/api/assets', {
      userId: 'u1',
      name: 'movie.eb4',
      packageBase64: Buffer.from('video-package').toString('base64'),
      previewBase64: Buffer.from('video-preview').toString('base64'),
      previewMime: 'video/mp4',
      crc32: '22222222',
      packageSize: 13,
      frameCount: 4,
      fps: 40,
    });
    assert.equal(created.status, 201);
    assert.equal(created.json.previewMime, 'video/mp4');

    const list = await request(
      baseUrl,
      'GET',
      '/api/admin/assets',
      null,
      { 'X-Admin-Token': 'test-token' },
    );
    assert.equal(list.status, 200);
    assert.equal(list.json.items[0].previewMime, 'video/mp4');

    const preview = await request(
      baseUrl,
      'GET',
      `/api/admin/assets/${created.json.id}/preview?token=test-token`,
    );
    assert.equal(preview.status, 200);
    assert.equal(preview.headers['content-type'], 'video/mp4');

    const adminPage = await request(baseUrl, 'GET', '/');
    assert.equal(adminPage.status, 200);
    assert.match(adminPage.text, /function buildPreviewHtml/);
    assert.match(adminPage.text, /<video class="asset-thumb" controls/);
  });
});

test('admin login validates the token against a protected endpoint', async () => {
  await withServer(async (baseUrl) => {
    const publicHealth = await request(baseUrl, 'GET', '/api/health');
    assert.equal(publicHealth.status, 200);

    const withoutToken = await request(baseUrl, 'GET', '/api/admin/health');
    assert.equal(withoutToken.status, 401);

    const withToken = await request(
      baseUrl,
      'GET',
      '/api/admin/health',
      null,
      { 'X-Admin-Token': 'test-token' },
    );
    assert.equal(withToken.status, 200);
    assert.equal(withToken.json.ok, true);

    const adminPage = await request(baseUrl, 'GET', '/');
    assert.equal(adminPage.status, 200);
    assert.match(adminPage.text, /api\('GET', '\/api\/admin\/health'\)/);
    assert.doesNotMatch(adminPage.text, /api\('GET', '\/api\/health'\)/);
  });
});

test('ota manifest endpoint returns firmware metadata', async () => {
  await withServer(async (baseUrl) => {
    const res = await request(baseUrl, 'GET', '/api/ota/manifest?hardware=esp32s3');
    assert.equal(res.status, 200);
    assert.equal(res.json.hardware, 'esp32s3');
    assert.ok(res.json.version);
    assert.ok(res.json.url);
  });
});

test('download endpoints support header probes', async () => {
  await withServer(async (baseUrl, dataDir) => {
    const apkDir = path.join(dataDir, 'downloads', 'apk');
    const firmwareDir = path.join(dataDir, 'downloads', 'firmware');
    fs.mkdirSync(apkDir, { recursive: true });
    fs.mkdirSync(firmwareDir, { recursive: true });
    fs.writeFileSync(path.join(apkDir, 'app_gif_1.0.2.apk'), Buffer.from('apk'));
    fs.writeFileSync(path.join(firmwareDir, 'esp-baji-esp32s3-0.1.1.bin'), Buffer.from('fw'));

    const apk = await request(baseUrl, 'HEAD', '/downloads/apk/app_gif_1.0.2.apk');
    assert.equal(apk.status, 200);
    assert.equal(apk.headers['content-length'], '3');
    assert.equal(apk.text, '');

    const firmware = await request(baseUrl, 'HEAD', '/downloads/firmware/esp-baji-esp32s3-0.1.1.bin');
    assert.equal(firmware.status, 200);
    assert.equal(firmware.headers['content-length'], '2');
    assert.equal(firmware.text, '');
  });
});

test('admin uploads maintain app and firmware version history', async () => {
  await withServer(async (baseUrl, dataDir) => {
    const admin = { 'X-Admin-Token': 'test-token' };

    const apk102 = await multipartRequest(
      baseUrl,
      '/api/admin/upload-apk',
      { version: '1.0.2', force: 'false', notes: 'android 1.0.2' },
      { name: 'file', filename: 'app_gif_1.0.2.apk', content: Buffer.from('apk102') },
      admin,
    );
    assert.equal(apk102.status, 200);
    assert.equal(apk102.json.android.latestVersion, '1.0.2');

    const apk103 = await multipartRequest(
      baseUrl,
      '/api/admin/upload-apk',
      { version: '1.0.3', force: 'true', notes: 'android 1.0.3' },
      { name: 'file', filename: 'app_gif_1.0.3.apk', content: Buffer.from('apk103') },
      admin,
    );
    assert.equal(apk103.status, 200);
    assert.equal(apk103.json.android.latestVersion, '1.0.3');

    const appHistory = await request(baseUrl, 'GET', '/api/admin/app-versions?platform=android', null, admin);
    assert.equal(appHistory.status, 200);
    assert.deepEqual(
      appHistory.json.items.map((item) => item.version),
      ['1.0.3', '1.0.2'],
    );
    assert.match(appHistory.json.items[0].url, /\/downloads\/apk\/app_gif_1\.0\.3\.apk$/);
    assert.equal(appHistory.json.items[0].force, true);

    const deleteLatestApk = await request(
      baseUrl,
      'DELETE',
      '/api/admin/app-versions/android/1.0.3',
      null,
      admin,
    );
    assert.equal(deleteLatestApk.status, 200);
    assert.equal(deleteLatestApk.json.android.latestVersion, '1.0.2');
    assert.equal(fs.existsSync(path.join(dataDir, 'downloads', 'apk', 'app_gif_1.0.3.apk')), false);

    const afterApkDelete = await request(baseUrl, 'GET', '/api/version?platform=android');
    assert.equal(afterApkDelete.status, 200);
    assert.equal(afterApkDelete.json.latestVersion, '1.0.2');

    const fw011 = await multipartRequest(
      baseUrl,
      '/api/admin/upload-firmware',
      { version: '0.1.1', notes: 'firmware 0.1.1' },
      { name: 'file', filename: 'esp-baji-esp32s3-0.1.1.bin', content: Buffer.from('fw011') },
      admin,
    );
    assert.equal(fw011.status, 200);
    assert.equal(fw011.json.esp32s3.version, '0.1.1');

    const fw012 = await multipartRequest(
      baseUrl,
      '/api/admin/upload-firmware',
      { version: '0.1.2', notes: 'firmware 0.1.2' },
      { name: 'file', filename: 'esp-baji-esp32s3-0.1.2.bin', content: Buffer.from('fw012') },
      admin,
    );
    assert.equal(fw012.status, 200);
    assert.equal(fw012.json.esp32s3.version, '0.1.2');

    const firmwareHistory = await request(
      baseUrl,
      'GET',
      '/api/admin/firmware-versions?hardware=esp32s3',
      null,
      admin,
    );
    assert.equal(firmwareHistory.status, 200);
    assert.deepEqual(
      firmwareHistory.json.items.map((item) => item.version),
      ['0.1.2', '0.1.1'],
    );
    assert.match(firmwareHistory.json.items[0].url, /\/downloads\/firmware\/esp-baji-esp32s3-0\.1\.2\.bin$/);
    assert.equal(firmwareHistory.json.items[0].sha256.length, 64);

    const deleteLatestFirmware = await request(
      baseUrl,
      'DELETE',
      '/api/admin/firmware-versions/esp32s3/0.1.2',
      null,
      admin,
    );
    assert.equal(deleteLatestFirmware.status, 200);
    assert.equal(deleteLatestFirmware.json.esp32s3.version, '0.1.1');
    assert.equal(
      fs.existsSync(path.join(dataDir, 'downloads', 'firmware', 'esp-baji-esp32s3-0.1.2.bin')),
      false,
    );

    const afterFirmwareDelete = await request(baseUrl, 'GET', '/api/ota/manifest?hardware=esp32s3');
    assert.equal(afterFirmwareDelete.status, 200);
    assert.equal(afterFirmwareDelete.json.version, '0.1.1');
  });
});
