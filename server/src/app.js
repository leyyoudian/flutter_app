const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const defaultVersions = {
  android: {
    platform: 'android',
    latestVersion: '1.0.0',
    minimumVersion: '1.0.0',
    force: false,
    storeUrl: 'https://play.google.com/store/apps/details?id=com.espbaji.app',
    notes: '首个远程更新配置。',
  },
  ios: {
    platform: 'ios',
    latestVersion: '1.0.0',
    minimumVersion: '1.0.0',
    force: false,
    storeUrl: 'https://apps.apple.com/app/id0000000000',
    notes: '首个远程更新配置。',
  },
};

const defaultOta = {
  esp32s3: {
    hardware: 'esp32s3',
    version: '0.1.0',
    url: 'https://example.com/firmware/esp-baji-esp32s3.bin',
    sha256: '',
    notes: '把正式固件 bin 上传到服务器后替换这里的 URL。',
  },
};

const defaultAppVersionHistory = [];
const defaultFirmwareVersionHistory = [];
const adminTokenHeader = 'X-Admin-Token';
const factorySchemaVersion = 1;
const protectedFactoryMax = 21;
const factoryZipMaxBytes = 256 * 1024 * 1024;

const crcTable = Array.from({ length: 256 }, (_, index) => {
  let crc = index;
  for (let bit = 0; bit < 8; bit += 1) {
    crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  return crc >>> 0;
});

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function loadJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
    ensureDir(path.dirname(file));
    fs.writeFileSync(file, JSON.stringify(fallback, null, 2));
    return JSON.parse(JSON.stringify(fallback));
  }
}

function saveJson(file, data) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

function writeFileAtomicSync(file, data) {
  ensureDir(path.dirname(file));
  const tmpPath = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tmpPath, data);
  fs.renameSync(tmpPath, file);
}

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

function sendText(res, status, text, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(status, {
    'content-type': contentType,
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
  });
  res.end(text);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (!text) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(text));
      } catch (error) {
        reject(Object.assign(new Error('invalid json'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

function sanitizeName(name) {
  return String(name || 'asset.eb4')
    .replace(/[\\/:*?"<>|]/g, '_')
    .slice(0, 120);
}

function decodeBase64(value, label) {
  if (typeof value !== 'string' || value.length === 0) {
    throw Object.assign(new Error(`missing ${label}`), { status: 400 });
  }
  return Buffer.from(value, 'base64');
}

function requireAdmin(req, adminToken, url = null) {
  const headerToken = req.headers[adminTokenHeader.toLowerCase()];
  const auth = req.headers.authorization || '';
  const bearerToken = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const queryToken = url ? url.searchParams.get('token') : '';
  return adminToken && (headerToken === adminToken || bearerToken === adminToken || queryToken === adminToken);
}

function publicAsset(item) {
  return {
    id: item.id,
    status: item.status,
    name: item.name,
    userId: item.userId,
    crc32: item.crc32,
    packageSha256: item.packageSha256,
    packageSize: item.packageSize,
    frameCount: item.frameCount,
    fps: item.fps,
    previewMime: item.previewMime,
    previewUrl: item.previewPath ? `/api/admin/assets/${encodeURIComponent(item.id)}/preview` : null,
    submittedAt: item.submittedAt,
    reviewedAt: item.reviewedAt,
    reviewer: item.reviewer,
    rejectReason: item.rejectReason,
  };
}

function duplicateAssetMatches(asset, packageSha256, crc32, packageSize) {
  return asset.packageSha256 === packageSha256 ||
    (!asset.packageSha256 && asset.crc32 === crc32 && Number(asset.packageSize || 0) === packageSize);
}

function duplicateStatusPriority(status) {
  if (status === 'approved') return 0;
  if (status === 'rejected') return 1;
  return 2;
}

function findDuplicateAsset(items, packageSha256, crc32, packageSize) {
  let best = null;
  let bestPriority = Number.MAX_SAFE_INTEGER;
  for (const asset of items) {
    if (!duplicateAssetMatches(asset, packageSha256, crc32, packageSize)) {
      continue;
    }
    const priority = duplicateStatusPriority(asset.status);
    if (!best || priority < bestPriority) {
      best = asset;
      bestPriority = priority;
    }
  }
  return best;
}

function extractVersionFromFilename(filename) {
  const match = String(filename).match(/(\d+\.\d+\.\d+)/);
  return match ? match[1] : null;
}

function sanitizeVersion(value, fallback) {
  const match = String(value || '').trim().match(/^(\d+\.\d+\.\d+)$/);
  return match ? match[1] : fallback;
}

function computeSha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

function computeBufferSha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function computeBufferCrc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function normalizeZipPath(name) {
  const normalized = String(name || '').replace(/\\/g, '/').replace(/^\/+/, '');
  if (!normalized || normalized.endsWith('/')) return null;
  if (path.posix.isAbsolute(normalized) || normalized.split('/').includes('..')) {
    throw Object.assign(new Error('invalid zip path'), { status: 400 });
  }
  if (!(normalized === 'import.json' || normalized.startsWith('items/'))) {
    throw Object.assign(new Error('unknown zip path'), { status: 400 });
  }
  return normalized;
}

function parseZipEntries(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0 || buffer.length > factoryZipMaxBytes) {
    throw Object.assign(new Error('invalid zip'), { status: 400 });
  }
  const entries = new Map();
  let offset = 0;
  while (offset + 30 <= buffer.length) {
    const signature = buffer.readUInt32LE(offset);
    if (signature === 0x02014b50 || signature === 0x06054b50) break;
    if (signature !== 0x04034b50) {
      throw Object.assign(new Error('invalid zip header'), { status: 400 });
    }
    const flags = buffer.readUInt16LE(offset + 6);
    const method = buffer.readUInt16LE(offset + 8);
    const expectedCrc = buffer.readUInt32LE(offset + 14);
    const compressedSize = buffer.readUInt32LE(offset + 18);
    const nameLength = buffer.readUInt16LE(offset + 26);
    const extraLength = buffer.readUInt16LE(offset + 28);
    if ((flags & 0x08) !== 0) {
      throw Object.assign(new Error('unsupported zip data descriptor'), { status: 400 });
    }
    const nameStart = offset + 30;
    const dataStart = nameStart + nameLength + extraLength;
    const dataEnd = dataStart + compressedSize;
    if (dataEnd > buffer.length) {
      throw Object.assign(new Error('truncated zip entry'), { status: 400 });
    }
    const entryName = normalizeZipPath(buffer.slice(nameStart, nameStart + nameLength).toString('utf8'));
    const compressed = buffer.slice(dataStart, dataEnd);
    let data;
    if (method === 0) {
      data = compressed;
    } else if (method === 8) {
      data = zlib.inflateRawSync(compressed);
    } else {
      throw Object.assign(new Error('unsupported zip compression'), { status: 400 });
    }
    if (entryName) {
      if (entries.has(entryName)) {
        throw Object.assign(new Error('duplicate zip path'), { status: 400 });
      }
      if (expectedCrc && computeBufferCrc32(data) !== expectedCrc) {
        throw Object.assign(new Error('zip crc mismatch'), { status: 400 });
      }
      entries.set(entryName, data);
    }
    offset = dataEnd;
  }
  if (!entries.has('import.json')) {
    throw Object.assign(new Error('missing import.json'), { status: 400 });
  }
  return entries;
}

function normalizeFactoryItemId(id) {
  const match = String(id || '').trim().toUpperCase().match(/^F?(\d{1,3})$/);
  if (!match) {
    throw Object.assign(new Error('invalid factory id'), { status: 400 });
  }
  return `F${Number(match[1]).toString().padStart(3, '0')}`;
}

function factoryNumber(id) {
  const match = String(id || '').match(/^F(\d{3})$/);
  return match ? Number(match[1]) : Number.MAX_SAFE_INTEGER;
}

function isProtectedFactoryId(id) {
  const number = factoryNumber(id);
  return number >= 1 && number <= protectedFactoryMax;
}

function makeProtectedBaselineItem(index) {
  const id = `F${index.toString().padStart(3, '0')}`;
  return {
    id,
    title: id,
    type: 'split',
    protected: true,
    revision: 0,
    appFiles: {},
    deviceFiles: [],
    history: [],
  };
}

function withProtectedBaseline(catalog) {
  const next = catalog && Array.isArray(catalog.items) ? JSON.parse(JSON.stringify(catalog)) : {
    schemaVersion: factorySchemaVersion,
    catalogRevision: 0,
    publishedAt: new Date(0).toISOString(),
    items: [],
  };
  next.schemaVersion = factorySchemaVersion;
  for (let i = 1; i <= protectedFactoryMax; i += 1) {
    const id = `F${i.toString().padStart(3, '0')}`;
    const existing = next.items.find((item) => item.id === id);
    if (existing) {
      existing.protected = true;
      if (!existing.type) existing.type = 'split';
      if (!Number.isFinite(existing.revision)) existing.revision = 0;
      if (!existing.appFiles) existing.appFiles = {};
      if (!Array.isArray(existing.deviceFiles)) existing.deviceFiles = [];
      if (!Array.isArray(existing.history)) existing.history = [];
    } else {
      next.items.push(makeProtectedBaselineItem(i));
    }
  }
  next.items.sort((a, b) => factoryNumber(a.id) - factoryNumber(b.id));
  return next;
}

function loadFactoryCatalog(factoryCatalogFile) {
  const catalog = loadJson(factoryCatalogFile, {
    schemaVersion: factorySchemaVersion,
    catalogRevision: 0,
    publishedAt: new Date(0).toISOString(),
    items: [],
  });
  const withBaseline = withProtectedBaseline(catalog);
  saveFactoryCatalogAtomic(factoryCatalogFile, withBaseline);
  return withBaseline;
}

function saveFactoryCatalogAtomic(factoryCatalogFile, catalog) {
  writeFileAtomicSync(factoryCatalogFile, JSON.stringify(withProtectedBaseline(catalog), null, 2));
}

function publicFactoryCatalog(catalog) {
  return {
    schemaVersion: factorySchemaVersion,
    catalogRevision: catalog.catalogRevision || 0,
    publishedAt: catalog.publishedAt || new Date(0).toISOString(),
    items: catalog.items.map((item) => ({
      id: item.id,
      title: item.title || item.id,
      type: item.type || 'split',
      protected: !!item.protected,
      revision: item.revision || 0,
      minFirmwareVersion: item.minFirmwareVersion || '',
      appFiles: item.appFiles || {},
      deviceFiles: item.deviceFiles || [],
    })),
  };
}

function validateFactoryTargetPath(targetPath) {
  const value = String(targetPath || '').replace(/\\/g, '/');
  const patterns = [
    /^first_half\/F\d{3}\.eb4$/,
    /^second_half\/F\d{3}\.eb4$/,
    /^third_half\/F\d{3}(?:_F\d{3})?\.eb4$/,
    /^factory_loop\/F\d{3}\.eb4$/,
  ];
  if (!patterns.some((pattern) => pattern.test(value))) {
    throw Object.assign(new Error('invalid device file path'), { status: 400 });
  }
  return value;
}

function safeStagePath(stageDir, relativePath) {
  const root = path.resolve(stageDir);
  const target = path.resolve(stageDir, relativePath);
  if (!target.startsWith(root + path.sep)) {
    throw Object.assign(new Error('invalid stage path'), { status: 400 });
  }
  return target;
}

function stageFactoryImport(zipBuffer, factoryImportsDir) {
  const entries = parseZipEntries(zipBuffer);
  const importJson = JSON.parse(entries.get('import.json').toString('utf8'));
  const manifestPaths = Array.isArray(importJson.items) ? importJson.items : [];
  if (manifestPaths.length === 0 || manifestPaths.length > 100) {
    throw Object.assign(new Error('invalid import manifest'), { status: 400 });
  }
  const importId = `${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  const stageDir = path.join(factoryImportsDir, importId);
  ensureDir(stageDir);
  const candidates = [];

  for (const manifestPath of manifestPaths) {
    const normalizedManifestPath = normalizeZipPath(manifestPath);
    if (!normalizedManifestPath || !entries.has(normalizedManifestPath)) {
      throw Object.assign(new Error('candidate manifest not found'), { status: 400 });
    }
    const itemRootMatch = normalizedManifestPath.match(/^items\/([^/]+)\/manifest\.json$/);
    if (!itemRootMatch) {
      throw Object.assign(new Error('invalid candidate manifest path'), { status: 400 });
    }
    const itemRoot = `items/${itemRootMatch[1]}`;
    const manifest = JSON.parse(entries.get(normalizedManifestPath).toString('utf8'));
    const id = normalizeFactoryItemId(manifest.id);
    const type = String(manifest.type || '').toLowerCase();
    if (!['split', 'loop', 'transition'].includes(type)) {
      throw Object.assign(new Error('invalid factory type'), { status: 400 });
    }

    const appFiles = {};
    for (const [key, rel] of Object.entries(manifest.appFiles || {})) {
      const candidateRel = String(rel || '').replace(/\\/g, '/');
      const zipRel = `${itemRoot}/${candidateRel}`;
      if (!entries.has(zipRel)) {
        throw Object.assign(new Error('missing app file'), { status: 400 });
      }
      const outRel = `${id}/${candidateRel}`;
      const outPath = safeStagePath(stageDir, outRel);
      ensureDir(path.dirname(outPath));
      fs.writeFileSync(outPath, entries.get(zipRel));
      appFiles[key] = outRel;
    }

    const deviceFiles = [];
    for (const deviceFile of manifest.deviceFiles || []) {
      const targetPath = validateFactoryTargetPath(deviceFile.path);
      const sourceRel = String(deviceFile.source || '').replace(/\\/g, '/');
      const zipRel = `${itemRoot}/${sourceRel}`;
      if (!entries.has(zipRel)) {
        throw Object.assign(new Error('missing device file'), { status: 400 });
      }
      const outRel = `${id}/${sourceRel}`;
      const outPath = safeStagePath(stageDir, outRel);
      ensureDir(path.dirname(outPath));
      fs.writeFileSync(outPath, entries.get(zipRel));
      deviceFiles.push({ path: targetPath, source: outRel });
    }

    candidates.push({
      id,
      title: String(manifest.title || id),
      type,
      protected: isProtectedFactoryId(id),
      minFirmwareVersion: String(manifest.minFirmwareVersion || ''),
      appFiles,
      deviceFiles,
    });
  }

  saveJson(path.join(stageDir, 'staged.json'), { importId, stagedAt: new Date().toISOString(), candidates });
  return { importId, candidates };
}

function publishFactoryCandidates({ factoryCatalogFile, factoryImportsDir, factoryDownloadsDir, importId, itemIds }) {
  const stageDir = path.join(factoryImportsDir, path.basename(String(importId || '')));
  const staged = loadJson(path.join(stageDir, 'staged.json'), null);
  const selected = new Set((Array.isArray(itemIds) ? itemIds : []).map(normalizeFactoryItemId));
  const catalog = loadFactoryCatalog(factoryCatalogFile);
  const now = new Date().toISOString();

  for (const candidate of staged.candidates.filter((item) => selected.has(item.id))) {
    const existing = catalog.items.find((item) => item.id === candidate.id);
    const revision = (existing?.revision || 0) + 1;
    const itemDir = path.join(factoryDownloadsDir, candidate.id, String(revision));
    ensureDir(itemDir);

    const appFiles = {};
    for (const [key, rel] of Object.entries(candidate.appFiles || {})) {
      const source = safeStagePath(stageDir, rel);
      const filename = path.basename(rel);
      const destination = path.join(itemDir, filename);
      fs.copyFileSync(source, destination);
      const stat = fs.statSync(destination);
      appFiles[key] = {
        url: `/downloads/factory/${candidate.id}/${revision}/${encodeURIComponent(filename)}`,
        size: stat.size,
        sha256: computeBufferSha256(fs.readFileSync(destination)),
      };
    }

    const deviceFiles = [];
    for (const deviceFile of candidate.deviceFiles || []) {
      const source = safeStagePath(stageDir, deviceFile.source);
      const destination = path.join(itemDir, 'device', deviceFile.path);
      ensureDir(path.dirname(destination));
      fs.copyFileSync(source, destination);
      const stat = fs.statSync(destination);
      deviceFiles.push({
        path: deviceFile.path,
        url: `/downloads/factory/${candidate.id}/${revision}/device/${deviceFile.path}`,
        size: stat.size,
        sha256: computeBufferSha256(fs.readFileSync(destination)),
      });
    }

    const nextItem = {
      id: candidate.id,
      title: candidate.title,
      type: candidate.type,
      protected: isProtectedFactoryId(candidate.id),
      revision,
      minFirmwareVersion: candidate.minFirmwareVersion,
      publishedAt: now,
      appFiles,
      deviceFiles,
      history: [
        ...(existing?.history || []),
        ...(existing ? [{
          revision: existing.revision || 0,
          publishedAt: existing.publishedAt || '',
          appFiles: existing.appFiles || {},
          deviceFiles: existing.deviceFiles || [],
        }] : []),
      ].filter((entry) => entry.revision > 0).slice(-10),
    };

    if (existing) {
      Object.assign(existing, nextItem);
    } else {
      catalog.items.push(nextItem);
    }
  }

  catalog.catalogRevision = (catalog.catalogRevision || 0) + 1;
  catalog.publishedAt = now;
  saveFactoryCatalogAtomic(factoryCatalogFile, catalog);
  return publicFactoryCatalog(loadFactoryCatalog(factoryCatalogFile));
}

function deleteFactoryItem(factoryCatalogFile, id) {
  const itemId = normalizeFactoryItemId(id);
  if (isProtectedFactoryId(itemId)) {
    throw Object.assign(new Error('protected factory item cannot be deleted'), { status: 409 });
  }
  const catalog = loadFactoryCatalog(factoryCatalogFile);
  const before = catalog.items.length;
  catalog.items = catalog.items.filter((item) => item.id !== itemId);
  if (catalog.items.length === before) {
    throw Object.assign(new Error('factory item not found'), { status: 404 });
  }
  catalog.catalogRevision = (catalog.catalogRevision || 0) + 1;
  catalog.publishedAt = new Date().toISOString();
  saveFactoryCatalogAtomic(factoryCatalogFile, catalog);
  return publicFactoryCatalog(loadFactoryCatalog(factoryCatalogFile));
}

function sanitizePreviewMime(mime) {
  const value = String(mime || '').toLowerCase();
  if ([
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'video/mp4',
  ].includes(value)) {
    return value;
  }
  return 'application/octet-stream';
}

function previewMimeRank(mime) {
  const value = sanitizePreviewMime(mime);
  if (value.startsWith('video/')) return 3;
  if (value === 'image/gif') return 2;
  if (value.startsWith('image/')) return 1;
  return 0;
}

function shouldReplacePreview(existingMime, nextMime) {
  return previewMimeRank(nextMime) > previewMimeRank(existingMime);
}

function removeRelativeFile(dataDir, relativePath) {
  if (!relativePath) return;
  const root = path.resolve(dataDir);
  const target = path.resolve(dataDir, relativePath);
  if (!target.startsWith(root + path.sep)) return;
  fs.rmSync(target, { force: true });
}

function removeDownloadFile(downloadDir, filename) {
  if (!filename) return;
  const root = path.resolve(downloadDir);
  const target = path.resolve(downloadDir, path.basename(filename));
  if (!target.startsWith(root + path.sep)) return;
  fs.rmSync(target, { force: true });
}

function upsertHistoryItem(items, item, key) {
  return [
    item,
    ...items.filter((existing) => existing[key] !== item[key] || existing.version !== item.version),
  ];
}

function syncAppManifestFromHistory(versions, appHistory, platform) {
  const latest = appHistory.find((item) => item.platform === platform);
  if (!latest) {
    versions[platform] = { ...defaultVersions[platform] };
    return versions[platform];
  }
  versions[platform] = {
    platform,
    latestVersion: latest.version,
    minimumVersion: versions[platform]?.minimumVersion || latest.version,
    force: !!latest.force,
    storeUrl: latest.url,
    notes: latest.notes || `版本 ${latest.version}`,
  };
  return versions[platform];
}

function syncFirmwareManifestFromHistory(manifests, firmwareHistory, hardware) {
  const latest = firmwareHistory.find((item) => item.hardware === hardware);
  if (!latest) {
    manifests[hardware] = { ...defaultOta[hardware] };
    return manifests[hardware];
  }
  manifests[hardware] = {
    hardware,
    version: latest.version,
    url: latest.url,
    sha256: latest.sha256 || '',
    notes: latest.notes || `固件版本 ${latest.version}`,
  };
  return manifests[hardware];
}

function readMultipart(req) {
  return new Promise((resolve, reject) => {
    const contentType = req.headers['content-type'] || '';
    const boundaryMatch = contentType.match(/boundary=(?:"([^"]+)"|([^\s;]+))/);
    if (!boundaryMatch) {
      reject(Object.assign(new Error('missing boundary'), { status: 400 }));
      return;
    }
    const boundary = boundaryMatch[1] || boundaryMatch[2];
    const delimiter = Buffer.from(`--${boundary}`);
    const endDelimiter = Buffer.from(`--${boundary}--`);

    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      const parts = [];
      let pos = 0;

      while (pos < body.length) {
        const delimIdx = body.indexOf(delimiter, pos);
        if (delimIdx === -1) break;
        pos = delimIdx + delimiter.length;
        if (pos < body.length && body[pos] === 0x0d) pos += 2;
        else if (pos < body.length && body[pos] === 0x0a) pos += 1;

        const headerEnd = body.indexOf(Buffer.from('\r\n\r\n'), pos);
        if (headerEnd === -1) break;
        const headerText = body.slice(pos, headerEnd).toString('utf8');
        pos = headerEnd + 4;

        let nextDelim = body.indexOf(delimiter, pos);
        if (nextDelim === -1) nextDelim = body.length;
        const contentEnd = nextDelim >= 2 && body[nextDelim - 2] === 0x0d ? nextDelim - 2 : nextDelim;
        const content = body.slice(pos, contentEnd);
        pos = nextDelim;

        const nameMatch = headerText.match(/name="([^"]+)"/);
        const filenameMatch = headerText.match(/filename="([^"]+)"/);
        if (!nameMatch) continue;

        parts.push({
          name: nameMatch[1],
          filename: filenameMatch ? filenameMatch[1] : null,
          data: content,
        });
      }

      resolve(parts);
    });
    req.on('error', reject);
  });
}

const adminPageHtml = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ESP BAJI - 管理后台</title>
<style>
:root{--c-bg:#f5f6f8;--c-card:#fff;--c-border:#e4e7ed;--c-text:#1d2129;--c-text-2:#4e5969;--c-text-3:#86909c;--c-primary:#165dff;--c-primary-hover:#0e42d2;--c-primary-bg:rgba(22,93,255,.06);--c-danger:#cb2634;--c-danger-hover:#a91d2a;--c-success:#00b42a;--c-warn:#ff7d00;--c-tag-green-bg:#e8ffea;--c-tag-green:#00b42a;--c-tag-orange-bg:#fff7e8;--c-tag-orange:#ff7d00;--c-tag-red-bg:#ffece8;--c-tag-red:#cb2634;--c-info-bg:#f2f3f5;--c-sidebar:#1d2129;--c-sidebar-hover:rgba(255,255,255,.06);--c-sidebar-active:rgba(22,93,255,.15);--radius:6px}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;background:var(--c-bg);color:var(--c-text);min-height:100vh;font-size:14px;line-height:1.5;-webkit-font-smoothing:antialiased}
svg{vertical-align:-0.125em}
.icon-sm{width:16px;height:16px}
.icon-md{width:18px;height:18px}
.layout{display:flex;min-height:100vh}
.sidebar{width:200px;background:var(--c-sidebar);color:#fff;display:flex;flex-direction:column;flex-shrink:0;position:fixed;top:0;left:0;bottom:0;z-index:200}
.sidebar-brand{padding:16px 20px;display:flex;align-items:center;gap:10px;border-bottom:1px solid rgba(255,255,255,.08)}
.sidebar-brand svg{color:var(--c-primary);flex-shrink:0}
.sidebar-brand span{font-size:15px;font-weight:600;letter-spacing:-.2px}
.sidebar-nav{padding:8px 0;flex:1}
.nav-item{display:flex;align-items:center;gap:10px;padding:10px 20px;font-size:13px;color:rgba(255,255,255,.65);cursor:pointer;transition:all .12s;border-left:2px solid transparent;margin:1px 0}
.nav-item:hover{color:#fff;background:var(--c-sidebar-hover)}
.nav-item.active{color:#fff;background:var(--c-sidebar-active);border-left-color:var(--c-primary)}
.nav-item svg{flex-shrink:0;opacity:.7}
.nav-item.active svg{opacity:1;color:var(--c-primary)}
.main{margin-left:200px;flex:1;min-height:100vh;display:flex;flex-direction:column}
.topbar{background:var(--c-card);border-bottom:1px solid var(--c-border);padding:0 28px;height:48px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0;position:sticky;top:0;z-index:100}
.topbar-title{font-size:14px;font-weight:600;color:var(--c-text)}
.topbar-right{font-size:12px;color:var(--c-text-3)}
.content{padding:20px 28px 48px;flex:1}
.card{background:var(--c-card);border:1px solid var(--c-border);border-radius:var(--radius);padding:30px 50px;margin-bottom:16px}
.card-header{display:flex;align-items:center;gap:8px;margin-bottom:16px;padding-bottom:12px;border-bottom:1px solid var(--c-border)}
.card-header h2{font-size:15px;font-weight:600;color:var(--c-text)}
.card-header svg{color:var(--c-primary);flex-shrink:0}
.row{display:flex;gap:12px;flex-wrap:wrap}
.field{flex:1;min-width:160px}
.field label{display:block;font-size:13px;font-weight:500;color:var(--c-text-2);margin-bottom:4px}
.field input,.field select,.field textarea{width:100%;padding:6px 10px;border:1px solid var(--c-border);border-radius:var(--radius);font-size:13px;color:var(--c-text);outline:none;transition:border-color .15s,box-shadow .15s;background:var(--c-card)}
.field input:focus,.field select:focus,.field textarea:focus{border-color:var(--c-primary);box-shadow:0 0 0 2px rgba(22,93,255,.1)}
.field textarea{resize:vertical;min-height:56px}
.drop-zone{border:1px dashed var(--c-border);border-radius:var(--radius);padding:50px 30px;text-align:center;cursor:pointer;transition:all .15s;margin-bottom:14px;position:relative;background:var(--c-bg)}
.drop-zone:hover{border-color:var(--c-primary);background:rgba(22,93,255,.02)}
.drop-zone.active{border-color:var(--c-primary);background:rgba(22,93,255,.04)}
.drop-zone.has-file{border-color:var(--c-success);border-style:solid;background:rgba(0,180,42,.02)}
.drop-zone .hint{font-size:13px;color:var(--c-text-3);display:flex;align-items:center;justify-content:center;gap:6px}
.drop-zone .hint svg{color:var(--c-text-3)}
.drop-zone .filename{font-size:13px;font-weight:500;color:var(--c-text);margin-top:6px;word-break:break-all}
.drop-zone input[type=file]{position:absolute;inset:0;opacity:0;cursor:pointer}
.tag{display:inline-flex;align-items:center;padding:1px 8px;border-radius:3px;font-size:12px;font-weight:500;line-height:20px}
.tag-green{background:var(--c-tag-green-bg);color:var(--c-tag-green)}
.tag-orange{background:var(--c-tag-orange-bg);color:var(--c-tag-orange)}
.tag-red{background:var(--c-tag-red-bg);color:var(--c-tag-red)}
.btn{display:inline-flex;align-items:center;gap:6px;padding:5px 14px;border:1px solid var(--c-border);border-radius:var(--radius);font-size:13px;font-weight:500;cursor:pointer;transition:all .15s;background:var(--c-card);color:var(--c-text);line-height:22px}
.btn:hover{border-color:var(--c-primary);color:var(--c-primary)}
.btn-primary{background:var(--c-primary);color:#fff;border-color:var(--c-primary)}
.btn-primary:hover{background:var(--c-primary-hover);border-color:var(--c-primary-hover);color:#fff}
.btn-primary:disabled{background:var(--c-text-3);border-color:var(--c-text-3);cursor:not-allowed;color:#fff}
.btn-danger{color:var(--c-danger);border-color:var(--c-danger)}
.btn-danger:hover{background:var(--c-danger);color:#fff;border-color:var(--c-danger)}
.btn-sm{padding:2px 10px;font-size:12px;line-height:20px}
.actions{display:flex;gap:8px;margin-top:14px;align-items:center}
.status-msg{font-size:13px;font-weight:500}
.status-msg.ok{color:var(--c-success)}
.status-msg.err{color:var(--c-danger)}
.info-bar{background:var(--c-info-bg);border-radius:var(--radius);padding:10px 14px;margin-bottom:14px;font-size:13px;color:var(--c-text-2);line-height:1.8;display:flex;flex-wrap:wrap;gap:4px 16px}
.info-bar span{display:inline-flex;align-items:center;gap:4px}
.info-bar strong{color:var(--c-text);font-weight:500}
.info-bar a{color:var(--c-primary);text-decoration:none}
.info-bar a:hover{text-decoration:underline}
table{width:100%;border-collapse:collapse;font-size:13px}
table th,table td{padding:8px 12px;text-align:left;border-bottom:1px solid var(--c-border)}
table th{font-weight:500;color:var(--c-text-3);background:var(--c-info-bg);font-size:12px}
table tr:hover td{background:rgba(22,93,255,.02)}
.empty-msg{text-align:center;padding:28px;color:var(--c-text-3);font-size:13px}
.login-wrap{display:flex;align-items:center;justify-content:center;min-height:100vh;background:var(--c-bg)}
.login-card{width:320px;padding:32px 28px}
.login-card h2{font-size:16px;font-weight:600;text-align:center;margin-bottom:20px}
.login-card input{width:100%;padding:8px 10px;border:1px solid var(--c-border);border-radius:var(--radius);font-size:13px;outline:none;transition:border-color .15s;margin-bottom:12px}
.login-card input:focus{border-color:var(--c-primary);box-shadow:0 0 0 2px rgba(22,93,255,.1)}
.login-card .btn{width:100%;justify-content:center;padding:7px 14px}
.toggle-row{display:flex;align-items:center;gap:8px;margin-top:6px}
.toggle-row input[type=checkbox]{width:15px;height:15px;accent-color:var(--c-primary);cursor:pointer}
.toggle-row label{font-size:13px;color:var(--c-text-2);cursor:pointer}
.section-hidden{display:none}
.page{display:none}
.page.active{display:block}
.asset-thumb{width:72px;height:72px;object-fit:cover;border-radius:var(--radius);border:1px solid var(--c-border);background:var(--c-info-bg);display:block}
.asset-meta{font-size:12px;color:var(--c-text-3);margin-top:2px}
.asset-actions{display:flex;gap:6px;flex-wrap:wrap}
.history-title{font-size:13px;font-weight:600;color:var(--c-text);margin:18px 0 8px}
.version-actions{display:flex;gap:6px;flex-wrap:wrap}
.mono{font-family:"SFMono-Regular",Consolas,"Liberation Mono",monospace;font-size:12px}
</style>
</head>
<body>

<div id="loginSection" class="login-wrap">
  <div class="card login-card">
    <h2>管理员登录</h2>
    <input type="password" id="tokenInput" placeholder="请输入 Admin Token">
    <button class="btn btn-primary" onclick="doLogin()">登 录</button>
  </div>
</div>

<div id="mainSection" class="layout section-hidden">
  <aside class="sidebar">
    <div class="sidebar-brand">
      <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="2" x2="9" y2="4"/><line x1="15" y1="2" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="22"/><line x1="15" y1="20" x2="15" y2="22"/><line x1="20" y1="9" x2="22" y2="9"/><line x1="20" y1="14" x2="22" y2="14"/><line x1="2" y1="9" x2="4" y2="9"/><line x1="2" y1="14" x2="4" y2="14"/></svg>
      <span>ESP BAJI</span>
    </div>
    <nav class="sidebar-nav">
      <div class="nav-item active" data-page="assets" onclick="switchPage('assets')">
        <svg class="icon-md" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>
        素材审核
      </div>
      <div class="nav-item" data-page="apk" onclick="switchPage('apk')">
        <svg class="icon-md" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2" width="14" height="20" rx="2" ry="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>
        App 版本管理
      </div>
      <div class="nav-item" data-page="firmware" onclick="switchPage('firmware')">
        <svg class="icon-md" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>
        固件管理
      </div>
      <div class="nav-item" data-page="factory" onclick="switchPage('factory')">
        <svg class="icon-md" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>
        Official Animations
      </div>
    </nav>
  </aside>
  <div class="main">
    <div class="topbar">
      <div class="topbar-title" id="pageTitle">素材审核</div>
      <div class="topbar-right">ESP BAJI Admin</div>
    </div>
    <div class="content">

      <div class="page active" id="page-assets">
        <div class="card">
          <div id="assetList"><div class="empty-msg">加载中...</div></div>
        </div>
      </div>

      <div class="page" id="page-apk">
        <div class="card">
          <div class="info-bar" id="androidInfo">加载中...</div>
          <div class="drop-zone" id="apkDropZone">
            <div class="hint">
              <svg class="icon-sm" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
              拖拽 APK 到此处，或点击选择文件
            </div>
            <div class="filename" id="apkFilename"></div>
            <input type="file" accept=".apk" id="apkFileInput" onchange="onApkSelected(this)">
          </div>
          <div class="row">
            <div class="field">
              <label>版本号</label>
              <input type="text" id="apkVersion" placeholder="1.0.0">
            </div>
            <div class="field">
              <label>更新说明</label>
              <input type="text" id="apkNotes" placeholder="修复了若干问题">
            </div>
          </div>
          <div class="toggle-row">
            <input type="checkbox" id="apkForce">
            <label for="apkForce">强制更新</label>
          </div>
          <div class="actions">
            <button class="btn btn-primary" id="apkUploadBtn" onclick="uploadApk()" disabled>
              <svg class="icon-sm" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
              上传 APK
            </button>
            <span class="status-msg" id="apkStatus"></span>
          </div>
          <div class="history-title">历史版本</div>
          <div id="apkHistory"><div class="empty-msg">加载中...</div></div>
        </div>
      </div>

      <div class="page" id="page-firmware">
        <div class="card">
          <div class="info-bar" id="firmwareInfo">加载中...</div>
          <div class="drop-zone" id="fwDropZone">
            <div class="hint">
              <svg class="icon-sm" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
              拖拽 .bin 固件到此处，或点击选择文件
            </div>
            <div class="filename" id="fwFilename"></div>
            <input type="file" accept=".bin" id="fwFileInput" onchange="onFwSelected(this)">
          </div>
          <div class="row">
            <div class="field">
              <label>版本号</label>
              <input type="text" id="fwVersion" placeholder="0.1.0">
            </div>
            <div class="field">
              <label>更新说明</label>
              <input type="text" id="fwNotes" placeholder="新增 OTA 功能">
            </div>
          </div>
          <div class="actions">
            <button class="btn btn-primary" id="fwUploadBtn" onclick="uploadFirmware()" disabled>
              <svg class="icon-sm" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
              上传固件
            </button>
            <span class="status-msg" id="fwStatus"></span>
          </div>
          <div class="history-title">历史版本</div>
          <div id="firmwareHistory"><div class="empty-msg">加载中...</div></div>
        </div>
      </div>

      <div class="page" id="page-factory">
        <div class="card">
          <div class="info-bar" id="factoryInfo">Loading catalog...</div>
          <div class="drop-zone" id="factoryDropZone">
            <div class="hint">
              <svg class="icon-sm" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
              Drop factory-import.zip here or click to select
            </div>
            <div class="filename" id="factoryFilename"></div>
            <input type="file" accept=".zip" id="factoryFileInput" onchange="onFactoryZipSelected(this)">
          </div>
          <div class="actions">
            <button class="btn btn-primary" id="factoryUploadBtn" onclick="uploadFactoryZip()" disabled>Upload ZIP</button>
            <button class="btn" id="factoryPublishBtn" onclick="publishFactorySelection()" disabled>Publish Selected</button>
            <span class="status-msg" id="factoryStatus"></span>
          </div>
          <div class="history-title">Staged Candidates</div>
          <div id="factoryCandidates"><div class="empty-msg">No staged import</div></div>
          <div class="history-title">Published Catalog</div>
          <div id="factoryCatalog"><div class="empty-msg">Loading...</div></div>
        </div>
      </div>

    </div>
  </div>
</div>

<script>
let adminToken = localStorage.getItem('esp_baji_token') || '';
let apkFile = null;
let fwFile = null;
let factoryZipFile = null;
let factoryImportId = '';
const pageTitles = { assets: '素材审核', apk: 'App 版本管理', firmware: '固件管理', factory: 'Official Animations' };

function switchPage(name) {
  document.querySelectorAll('.nav-item').forEach(el => el.classList.toggle('active', el.dataset.page === name));
  document.querySelectorAll('.page').forEach(el => el.classList.toggle('active', el.id === 'page-' + name));
  document.getElementById('pageTitle').textContent = pageTitles[name] || '';
  if (name === 'apk') refreshStatus();
  if (name === 'firmware') refreshStatus();
  if (name === 'assets') loadAssets();
  if (name === 'factory') loadFactoryCatalog();
}

function api(method, path, body) {
  const opts = {
    method,
    headers: { 'X-Admin-Token': adminToken, 'Content-Type': 'application/json' },
  };
  if (body) opts.body = JSON.stringify(body);
  return fetch(path, opts).then(async r => {
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || '请求失败');
    return data;
  });
}

function escapeHtml(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function jsArg(value) {
  return JSON.stringify(String(value == null ? '' : value)).replace(/</g, '\\u003c');
}

function doLogin() {
  adminToken = document.getElementById('tokenInput').value.trim();
  if (!adminToken) return;
  api('GET', '/api/admin/health').then(data => {
    if (data.ok) {
      localStorage.setItem('esp_baji_token', adminToken);
      showMain();
    } else {
      alert('Token 无效');
    }
  }).catch(() => {
    localStorage.removeItem('esp_baji_token');
    alert('Token 无效或已过期');
  });
}

function showLogin() {
  document.getElementById('mainSection').classList.add('section-hidden');
  document.getElementById('loginSection').classList.remove('section-hidden');
}

function showMain() {
  document.getElementById('loginSection').classList.add('section-hidden');
  document.getElementById('mainSection').classList.remove('section-hidden');
  refreshStatus();
  loadAssets();
}

function extractVersion(filename) {
  const m = filename.match(/(\\d+\\.\\d+\\.\\d+)/);
  return m ? m[1] : '';
}

function formatSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / 1048576).toFixed(1) + ' MB';
}

function onApkSelected(input) {
  apkFile = input.files[0];
  if (!apkFile) return;
  document.getElementById('apkFilename').textContent = apkFile.name + ' (' + formatSize(apkFile.size) + ')';
  document.getElementById('apkDropZone').classList.add('has-file');
  document.getElementById('apkUploadBtn').disabled = false;
  const v = extractVersion(apkFile.name);
  if (v) document.getElementById('apkVersion').value = v;
}

function onFwSelected(input) {
  fwFile = input.files[0];
  if (!fwFile) return;
  document.getElementById('fwFilename').textContent = fwFile.name + ' (' + formatSize(fwFile.size) + ')';
  document.getElementById('fwDropZone').classList.add('has-file');
  document.getElementById('fwUploadBtn').disabled = false;
  const v = extractVersion(fwFile.name);
  if (v) document.getElementById('fwVersion').value = v;
}

['apkDropZone', 'fwDropZone', 'factoryDropZone'].forEach(id => {
  const zone = document.getElementById(id);
  if (!zone) return;
  const fileInput = zone.querySelector('input[type=file]');
  zone.addEventListener('dragover', e => { e.preventDefault(); zone.classList.add('active'); });
  zone.addEventListener('dragleave', () => zone.classList.remove('active'));
  zone.addEventListener('drop', e => {
    e.preventDefault();
    zone.classList.remove('active');
    if (e.dataTransfer.files.length > 0) {
      fileInput.files = e.dataTransfer.files;
      fileInput.dispatchEvent(new Event('change'));
    }
  });
});

async function uploadApk() {
  if (!apkFile) return;
  const btn = document.getElementById('apkUploadBtn');
  const status = document.getElementById('apkStatus');
  btn.disabled = true;
  status.textContent = '上传中...';
  status.className = 'status-msg';
  try {
    const form = new FormData();
    form.append('file', apkFile);
    form.append('version', document.getElementById('apkVersion').value.trim());
    form.append('force', document.getElementById('apkForce').checked ? 'true' : 'false');
    form.append('notes', document.getElementById('apkNotes').value.trim());
    const r = await fetch('/api/admin/upload-apk', {
      method: 'POST',
      headers: { 'X-Admin-Token': adminToken },
      body: form,
    });
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || '上传失败');
    status.textContent = '上传成功，版本已更新为 ' + data.android.latestVersion;
    status.className = 'status-msg ok';
    apkFile = null;
    document.getElementById('apkFilename').textContent = '';
    document.getElementById('apkDropZone').classList.remove('has-file');
    document.getElementById('apkFileInput').value = '';
    refreshStatus();
  } catch (e) {
    status.textContent = '失败: ' + e.message;
    status.className = 'status-msg err';
  } finally {
    btn.disabled = false;
  }
}

async function uploadFirmware() {
  if (!fwFile) return;
  const btn = document.getElementById('fwUploadBtn');
  const status = document.getElementById('fwStatus');
  btn.disabled = true;
  status.textContent = '上传中...';
  status.className = 'status-msg';
  try {
    const form = new FormData();
    form.append('file', fwFile);
    form.append('version', document.getElementById('fwVersion').value.trim());
    form.append('notes', document.getElementById('fwNotes').value.trim());
    const r = await fetch('/api/admin/upload-firmware', {
      method: 'POST',
      headers: { 'X-Admin-Token': adminToken },
      body: form,
    });
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || '上传失败');
    status.textContent = '上传成功，固件版本已更新为 ' + data.esp32s3.version;
    status.className = 'status-msg ok';
    fwFile = null;
    document.getElementById('fwFilename').textContent = '';
    document.getElementById('fwDropZone').classList.remove('has-file');
    document.getElementById('fwFileInput').value = '';
    refreshStatus();
  } catch (e) {
    status.textContent = '失败: ' + e.message;
    status.className = 'status-msg err';
  } finally {
    btn.disabled = false;
  }
}

async function refreshStatus() {
  try {
    const versions = await (await fetch('/api/version')).json();
    const a = versions.android || {};
    const url = a.storeUrl || '';
    document.getElementById('androidInfo').innerHTML =
      '<span><strong>版本</strong> ' + (a.latestVersion || '-') + '</span>' +
      (url ? '<span><a href="' + url + '" target="_blank">下载</a></span>' : '') +
      '<span><strong>强制更新</strong> ' + (a.force ? '是' : '否') + '</span>' +
      '<span><strong>说明</strong> ' + (a.notes || '-') + '</span>';
  } catch (_) {}

  try {
    const ota = await (await fetch('/api/ota/manifest')).json();
    const url = ota.url || '';
    document.getElementById('firmwareInfo').innerHTML =
      '<span><strong>版本</strong> ' + (ota.version || '-') + '</span>' +
      (url ? '<span><a href="' + url + '" target="_blank">下载</a></span>' : '') +
      '<span><strong>SHA256</strong> ' + (ota.sha256 ? ota.sha256.slice(0, 16) + '...' : '-') + '</span>' +
      '<span><strong>说明</strong> ' + (ota.notes || '-') + '</span>';
  } catch (_) {}

  loadAppHistory();
  loadFirmwareHistory();
}

async function loadAppHistory() {
  const list = document.getElementById('apkHistory');
  if (!list) return;
  try {
    const data = await api('GET', '/api/admin/app-versions?platform=android');
    if (!data.items || data.items.length === 0) {
      list.innerHTML = '<div class="empty-msg">暂无 App 历史版本</div>';
      return;
    }
    let html = '<table><thead><tr><th>版本</th><th>大小</th><th>强制更新</th><th>时间</th><th>说明</th><th>操作</th></tr></thead><tbody>';
    for (let i = 0; i < data.items.length; i += 1) {
      const item = data.items[i];
      const uploadedAt = String(item.uploadedAt || '-').slice(0, 16).replace('T', ' ');
      const latestTag = i === 0 ? '<span class="tag tag-green">最新</span> ' : '';
      const actions =
        '<a class="btn btn-sm" href="' + escapeHtml(item.url || '#') + '" target="_blank">下载</a> ' +
        '<button class="btn btn-sm btn-danger" onclick=\\'deleteAppVersion(' +
        jsArg(item.platform || 'android') + ',' + jsArg(item.version) + ')\\'>删除</button>';
      html += '<tr>' +
        '<td>' + latestTag + escapeHtml(item.version || '-') + '</td>' +
        '<td>' + formatSize(Number(item.size) || 0) + '</td>' +
        '<td>' + (item.force ? '是' : '否') + '</td>' +
        '<td>' + escapeHtml(uploadedAt) + '</td>' +
        '<td>' + escapeHtml(item.notes || '-') + '</td>' +
        '<td><div class="version-actions">' + actions + '</div></td>' +
        '</tr>';
    }
    html += '</tbody></table>';
    list.innerHTML = html;
  } catch (_) {
    list.innerHTML = '<div class="empty-msg">加载失败</div>';
  }
}

async function loadFirmwareHistory() {
  const list = document.getElementById('firmwareHistory');
  if (!list) return;
  try {
    const data = await api('GET', '/api/admin/firmware-versions?hardware=esp32s3');
    if (!data.items || data.items.length === 0) {
      list.innerHTML = '<div class="empty-msg">暂无固件历史版本</div>';
      return;
    }
    let html = '<table><thead><tr><th>版本</th><th>大小</th><th>SHA256</th><th>时间</th><th>说明</th><th>操作</th></tr></thead><tbody>';
    for (let i = 0; i < data.items.length; i += 1) {
      const item = data.items[i];
      const uploadedAt = String(item.uploadedAt || '-').slice(0, 16).replace('T', ' ');
      const latestTag = i === 0 ? '<span class="tag tag-green">最新</span> ' : '';
      const sha = item.sha256 ? String(item.sha256).slice(0, 16) + '...' : '-';
      const actions =
        '<a class="btn btn-sm" href="' + escapeHtml(item.url || '#') + '" target="_blank">下载</a> ' +
        '<button class="btn btn-sm btn-danger" onclick=\\'deleteFirmwareVersion(' +
        jsArg(item.hardware || 'esp32s3') + ',' + jsArg(item.version) + ')\\'>删除</button>';
      html += '<tr>' +
        '<td>' + latestTag + escapeHtml(item.version || '-') + '</td>' +
        '<td>' + formatSize(Number(item.size) || 0) + '</td>' +
        '<td><span class="mono">' + escapeHtml(sha) + '</span></td>' +
        '<td>' + escapeHtml(uploadedAt) + '</td>' +
        '<td>' + escapeHtml(item.notes || '-') + '</td>' +
        '<td><div class="version-actions">' + actions + '</div></td>' +
        '</tr>';
    }
    html += '</tbody></table>';
    list.innerHTML = html;
  } catch (_) {
    list.innerHTML = '<div class="empty-msg">加载失败</div>';
  }
}

function renderFactoryPreview(item) {
  const thumb = item.appFiles && item.appFiles.thumbnail ? item.appFiles.thumbnail.url : '';
  const loopVideo = item.appFiles && item.appFiles.loopVideo ? item.appFiles.loopVideo.url : '';
  if (loopVideo) {
    return '<video class="asset-thumb" controls muted preload="metadata" src="' + escapeHtml(loopVideo) + '"></video>';
  }
  if (thumb) {
    return '<a href="' + escapeHtml(thumb) + '" target="_blank"><img class="asset-thumb" src="' + escapeHtml(thumb) + '" alt="thumbnail"></a>';
  }
  return '<span class="asset-meta">No preview</span>';
}

function renderFactoryCandidates(candidates) {
  const list = document.getElementById('factoryCandidates');
  const publishBtn = document.getElementById('factoryPublishBtn');
  if (!list) return;
  if (!candidates || candidates.length === 0) {
    list.innerHTML = '<div class="empty-msg">No staged import</div>';
    if (publishBtn) publishBtn.disabled = true;
    return;
  }
  let html = '<table><thead><tr><th></th><th>Preview</th><th>ID</th><th>Type</th><th>Firmware</th><th>Files</th></tr></thead><tbody>';
  for (const item of candidates) {
    const preview = renderFactoryPreview(item);
    const fileCount = (item.appFiles ? Object.keys(item.appFiles).length : 0) + (item.deviceFiles ? item.deviceFiles.length : 0);
    html += '<tr>' +
      '<td><input type="checkbox" class="factoryCandidateCheck" value="' + escapeHtml(item.id) + '" checked></td>' +
      '<td>' + preview + '</td>' +
      '<td><span class="mono">' + escapeHtml(item.id) + '</span></td>' +
      '<td>' + escapeHtml(item.type || '-') + '</td>' +
      '<td>' + escapeHtml(item.minFirmwareVersion || '-') + '</td>' +
      '<td>' + fileCount + '</td>' +
      '</tr>';
  }
  html += '</tbody></table>';
  list.innerHTML = html;
  if (publishBtn) publishBtn.disabled = false;
}

function renderFactoryCatalog(catalog) {
  const list = document.getElementById('factoryCatalog');
  const info = document.getElementById('factoryInfo');
  if (!list) return;
  if (info) {
    info.innerHTML = '<span><strong>Revision</strong> ' + (catalog.catalogRevision || 0) + '</span>' +
      '<span><strong>Published</strong> ' + escapeHtml(String(catalog.publishedAt || '-').slice(0, 19).replace('T', ' ')) + '</span>' +
      '<span><strong>Items</strong> ' + (catalog.items ? catalog.items.length : 0) + '</span>';
  }
  if (!catalog.items || catalog.items.length === 0) {
    list.innerHTML = '<div class="empty-msg">No published items</div>';
    return;
  }
  let html = '<table><thead><tr><th>Preview</th><th>ID</th><th>Type</th><th>Protected</th><th>Revision</th><th>Files</th><th>Actions</th></tr></thead><tbody>';
  for (const item of catalog.items) {
    const files = []
      .concat(Object.values(item.appFiles || {}).map((entry) => entry.size || 0))
      .concat((item.deviceFiles || []).map((entry) => entry.size || 0))
      .reduce((sum, size) => sum + Number(size || 0), 0);
    const actions = [
      '<button class="btn btn-sm btn-danger" onclick="deleteFactoryItem(\\'' + item.id + '\\')">Delete</button>',
    ].join(' ');
    html += '<tr>' +
      '<td>' + renderFactoryPreview(item) + '</td>' +
      '<td><span class="mono">' + escapeHtml(item.id) + '</span></td>' +
      '<td>' + escapeHtml(item.type || '-') + '</td>' +
      '<td>' + (item.protected ? '<span class="tag tag-green">yes</span>' : '<span class="tag tag-orange">no</span>') + '</td>' +
      '<td>' + escapeHtml(String(item.revision || 0)) + '</td>' +
      '<td>' + formatSize(files) + '</td>' +
      '<td><div class="version-actions">' + actions + '</div></td>' +
      '</tr>';
  }
  html += '</tbody></table>';
  list.innerHTML = html;
}

async function loadFactoryCatalog() {
  try {
    const data = await api('GET', '/api/admin/factory');
    renderFactoryCatalog(data);
  } catch (e) {
    const list = document.getElementById('factoryCatalog');
    if (list) list.innerHTML = '<div class="empty-msg">Load failed</div>';
  }
}

function onFactoryZipSelected(input) {
  factoryZipFile = input.files[0] || null;
  const filename = document.getElementById('factoryFilename');
  const uploadBtn = document.getElementById('factoryUploadBtn');
  if (!factoryZipFile) return;
  filename.textContent = factoryZipFile.name + ' (' + formatSize(factoryZipFile.size) + ')';
  document.getElementById('factoryDropZone').classList.add('has-file');
  uploadBtn.disabled = false;
}

async function uploadFactoryZip() {
  if (!factoryZipFile) return;
  const status = document.getElementById('factoryStatus');
  const btn = document.getElementById('factoryUploadBtn');
  btn.disabled = true;
  status.textContent = 'Uploading...';
  try {
    const form = new FormData();
    form.append('file', factoryZipFile);
    const r = await fetch('/api/admin/factory/import', {
      method: 'POST',
      headers: { 'X-Admin-Token': adminToken },
      body: form,
    });
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || 'upload failed');
    factoryImportId = data.importId || '';
    renderFactoryCandidates(data.candidates || []);
    status.textContent = 'Import staged';
    status.className = 'status-msg ok';
    await loadFactoryCatalog();
  } catch (e) {
    status.textContent = 'Failed: ' + e.message;
    status.className = 'status-msg err';
  } finally {
    btn.disabled = false;
  }
}

async function publishFactorySelection() {
  const status = document.getElementById('factoryStatus');
  const selected = Array.from(document.querySelectorAll('.factoryCandidateCheck:checked')).map((el) => el.value);
  if (!factoryImportId || selected.length === 0) return;
  try {
    const data = await api('POST', '/api/admin/factory/publish', {
      importId: factoryImportId,
      itemIds: selected,
    });
    renderFactoryCatalog(data);
    status.textContent = 'Published';
    status.className = 'status-msg ok';
  } catch (e) {
    status.textContent = 'Failed: ' + e.message;
    status.className = 'status-msg err';
  }
}

async function deleteFactoryItem(id) {
  if (!confirm('Delete factory item ' + id + '?')) return;
  try {
    const data = await api('DELETE', '/api/admin/factory/' + encodeURIComponent(id), null);
    renderFactoryCatalog(data);
  } catch (e) {
    alert('Delete failed: ' + e.message);
  }
}

async function deleteAppVersion(platform, version) {
  if (!confirm('确定删除 App 版本 ' + version + ' 吗？')) return;
  try {
    await api('DELETE', '/api/admin/app-versions/' + encodeURIComponent(platform) + '/' + encodeURIComponent(version), null);
    refreshStatus();
  } catch (e) {
    alert('删除失败: ' + e.message);
  }
}

async function deleteFirmwareVersion(hardware, version) {
  if (!confirm('确定删除固件版本 ' + version + ' 吗？')) return;
  try {
    await api('DELETE', '/api/admin/firmware-versions/' + encodeURIComponent(hardware) + '/' + encodeURIComponent(version), null);
    refreshStatus();
  } catch (e) {
    alert('删除失败: ' + e.message);
  }
}

function buildPreviewHtml(item, previewHref) {
  if (!previewHref) return '<span class="asset-meta">无预览</span>';
  const mime = String(item.previewMime || '');
  if (mime.startsWith('video/')) {
    return '<video class="asset-thumb" controls muted preload="metadata" src="' + previewHref + '"></video>';
  }
  return '<a href="' + previewHref + '" target="_blank"><img class="asset-thumb" src="' + previewHref + '" alt="素材预览"></a>';
}

async function loadAssets() {
  try {
    const data = await api('GET', '/api/admin/assets');
    const list = document.getElementById('assetList');
    if (!data.items || data.items.length === 0) {
      list.innerHTML = '<div class="empty-msg">暂无待审核素材</div>';
      return;
    }
    let html = '<table><thead><tr><th>预览</th><th>名称</th><th>用户</th><th>状态</th><th>时间</th><th>操作</th></tr></thead><tbody>';
    for (const item of data.items.slice(0, 20)) {
      const tc = item.status === 'approved' ? 'tag-green' : item.status === 'rejected' ? 'tag-red' : 'tag-orange';
      const tl = item.status === 'approved' ? '已通过' : item.status === 'rejected' ? '已拒绝' : '待审核';
      const previewHref = item.previewUrl ? item.previewUrl + '?token=' + encodeURIComponent(adminToken) : '';
      const previewHtml = buildPreviewHtml(item, previewHref);
      const meta = [
        item.packageSize ? formatSize(item.packageSize) : '',
        item.frameCount ? item.frameCount + ' 帧' : '',
        item.fps ? item.fps + ' fps' : '',
      ].filter(Boolean).join(' · ');
      const actions = [
        item.status === 'pending'
          ? '<button class="btn btn-sm btn-primary" onclick="reviewAsset(\\'' + item.id + '\\',\\'approve\\')">通过</button>'
          : '',
        item.status === 'pending'
          ? '<button class="btn btn-sm btn-danger" onclick="reviewAsset(\\'' + item.id + '\\',\\'reject\\')">拒绝</button>'
          : '',
        '<button class="btn btn-sm btn-danger" onclick="deleteAsset(\\'' + item.id + '\\')">删除</button>',
      ].filter(Boolean).join(' ');
      html += '<tr>' +
        '<td>' + previewHtml + '</td>' +
        '<td>' + escapeHtml(item.name || '-') + (meta ? '<div class="asset-meta">' + escapeHtml(meta) + '</div>' : '') + '</td>' +
        '<td>' + escapeHtml(item.userId || '-') + '</td>' +
        '<td><span class="tag ' + tc + '">' + tl + '</span></td>' +
        '<td>' + escapeHtml((item.submittedAt || '-').slice(0, 16).replace('T', ' ')) + '</td>' +
        '<td><div class="asset-actions">' + actions + '</div></td></tr>';
    }
    html += '</tbody></table>';
    list.innerHTML = html;
  } catch (_) {
    document.getElementById('assetList').innerHTML = '<div class="empty-msg">加载失败</div>';
  }
}

async function reviewAsset(id, action) {
  try {
    await api('POST', '/api/admin/assets/' + id + '/' + action, {});
    loadAssets();
  } catch (e) {
    alert('操作失败: ' + e.message);
  }
}

async function deleteAsset(id) {
  if (!confirm('确定删除这个素材及其预览文件吗？')) return;
  try {
    await api('DELETE', '/api/admin/assets/' + id, null);
    loadAssets();
  } catch (e) {
    alert('删除失败: ' + e.message);
  }
}

if (adminToken) {
  document.getElementById('tokenInput').value = adminToken;
  api('GET', '/api/admin/health')
    .then(() => showMain())
    .catch(() => {
      adminToken = '';
      localStorage.removeItem('esp_baji_token');
      showLogin();
    });
}
</script>
</body>
</html>`;

function createApp(options = {}) {
  const dataDir = options.dataDir || path.join(__dirname, '..', 'data');
  const adminToken = options.adminToken || process.env.ESP_BAJI_ADMIN_TOKEN || 'change-me';
  const versionsFile = path.join(dataDir, 'versions.json');
  const otaFile = path.join(dataDir, 'ota.json');
  const appVersionsFile = path.join(dataDir, 'app_versions.json');
  const firmwareVersionsFile = path.join(dataDir, 'firmware_versions.json');
  const assetsDir = path.join(dataDir, 'assets');
  const packagesDir = path.join(assetsDir, 'packages');
  const previewsDir = path.join(assetsDir, 'previews');
  const metadataFile = path.join(assetsDir, 'metadata.json');
  const downloadsDir = path.join(dataDir, 'downloads');
  const apkDir = path.join(downloadsDir, 'apk');
  const firmwareDir = path.join(downloadsDir, 'firmware');
  const factoryCatalogFile = path.join(dataDir, 'factory_catalog.json');
  const factoryImportsDir = path.join(dataDir, 'factory_imports');
  const factoryDownloadsDir = path.join(downloadsDir, 'factory');

  ensureDir(packagesDir);
  ensureDir(previewsDir);
  ensureDir(apkDir);
  ensureDir(firmwareDir);
  ensureDir(factoryImportsDir);
  ensureDir(factoryDownloadsDir);
  loadJson(versionsFile, defaultVersions);
  loadJson(otaFile, defaultOta);
  loadJson(appVersionsFile, defaultAppVersionHistory);
  loadJson(firmwareVersionsFile, defaultFirmwareVersionHistory);
  loadJson(metadataFile, []);
  loadFactoryCatalog(factoryCatalogFile);

  function getServerBaseUrl(req) {
    const host = req.headers.host || 'localhost:8787';
    const proto = req.headers['x-forwarded-proto'] || 'http';
    return `${proto}://${host}`;
  }

  function getFirmwareBaseUrl(req) {
    const host = req.headers.host || 'localhost:8787';
    return `http://${host}`;
  }

  return async function app(req, res) {
    const url = new URL(req.url, 'http://127.0.0.1');

    try {
      if (req.method === 'GET' && url.pathname === '/') {
        sendText(res, 200, adminPageHtml, 'text/html; charset=utf-8');
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/health') {
        sendJson(res, 200, { ok: true });
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/admin/health') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        sendJson(res, 200, { ok: true });
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/version') {
        const platform = (url.searchParams.get('platform') || '').toLowerCase();
        const versions = loadJson(versionsFile, defaultVersions);
        if (platform) {
          sendJson(res, versions[platform] ? 200 : 404, versions[platform] || { error: 'unknown platform' });
        } else {
          sendJson(res, 200, versions);
        }
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/ota/manifest') {
        const hardware = (url.searchParams.get('hardware') || 'esp32s3').toLowerCase();
        const manifests = loadJson(otaFile, defaultOta);
        sendJson(res, manifests[hardware] ? 200 : 404, manifests[hardware] || { error: 'unknown hardware' });
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/factory-catalog') {
        const catalog = loadFactoryCatalog(factoryCatalogFile);
        sendJson(res, 200, publicFactoryCatalog(catalog));
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/admin/factory') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        sendJson(res, 200, publicFactoryCatalog(loadFactoryCatalog(factoryCatalogFile)));
        return;
      }

      if (req.method === 'POST' && url.pathname === '/api/admin/factory/import') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const parts = await readMultipart(req);
        const filePart = parts.find((part) => part.name === 'file' && part.filename);
        if (!filePart) {
          sendJson(res, 400, { error: 'missing file' });
          return;
        }
        const staged = stageFactoryImport(filePart.data, factoryImportsDir);
        sendJson(res, 201, staged);
        return;
      }

      if (req.method === 'POST' && url.pathname === '/api/admin/factory/publish') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const body = await readJsonBody(req);
        const published = publishFactoryCandidates({
          factoryCatalogFile,
          factoryImportsDir,
          factoryDownloadsDir,
          importId: body.importId,
          itemIds: body.itemIds,
        });
        sendJson(res, 200, published);
        return;
      }

      const deleteFactoryMatch = url.pathname.match(/^\/api\/admin\/factory\/([^/]+)$/);
      if (req.method === 'DELETE' && deleteFactoryMatch) {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const deleted = deleteFactoryItem(factoryCatalogFile, decodeURIComponent(deleteFactoryMatch[1]));
        sendJson(res, 200, deleted);
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/admin/app-versions') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const platform = (url.searchParams.get('platform') || 'android').toLowerCase();
        const items = loadJson(appVersionsFile, defaultAppVersionHistory)
          .filter((item) => item.platform === platform);
        sendJson(res, 200, { platform, items });
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/admin/firmware-versions') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const hardware = (url.searchParams.get('hardware') || 'esp32s3').toLowerCase();
        const items = loadJson(firmwareVersionsFile, defaultFirmwareVersionHistory)
          .filter((item) => item.hardware === hardware);
        sendJson(res, 200, { hardware, items });
        return;
      }

      const deleteAppVersionMatch = url.pathname.match(/^\/api\/admin\/app-versions\/([^/]+)\/([^/]+)$/);
      if (req.method === 'DELETE' && deleteAppVersionMatch) {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const platform = decodeURIComponent(deleteAppVersionMatch[1]).toLowerCase();
        const version = decodeURIComponent(deleteAppVersionMatch[2]);
        const history = loadJson(appVersionsFile, defaultAppVersionHistory);
        const index = history.findIndex((item) => item.platform === platform && item.version === version);
        if (index === -1) {
          sendJson(res, 404, { error: 'version not found' });
          return;
        }
        const [removed] = history.splice(index, 1);
        removeDownloadFile(apkDir, removed.filename);
        saveJson(appVersionsFile, history);

        const versions = loadJson(versionsFile, defaultVersions);
        const current = syncAppManifestFromHistory(versions, history, platform);
        saveJson(versionsFile, versions);
        sendJson(res, 200, { ok: true, [platform]: current, items: history.filter((item) => item.platform === platform) });
        return;
      }

      const deleteFirmwareVersionMatch = url.pathname.match(/^\/api\/admin\/firmware-versions\/([^/]+)\/([^/]+)$/);
      if (req.method === 'DELETE' && deleteFirmwareVersionMatch) {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const hardware = decodeURIComponent(deleteFirmwareVersionMatch[1]).toLowerCase();
        const version = decodeURIComponent(deleteFirmwareVersionMatch[2]);
        const history = loadJson(firmwareVersionsFile, defaultFirmwareVersionHistory);
        const index = history.findIndex((item) => item.hardware === hardware && item.version === version);
        if (index === -1) {
          sendJson(res, 404, { error: 'version not found' });
          return;
        }
        const [removed] = history.splice(index, 1);
        removeDownloadFile(firmwareDir, removed.filename);
        saveJson(firmwareVersionsFile, history);

        const manifests = loadJson(otaFile, defaultOta);
        const current = syncFirmwareManifestFromHistory(manifests, history, hardware);
        saveJson(otaFile, manifests);
        sendJson(res, 200, { ok: true, [hardware]: current, items: history.filter((item) => item.hardware === hardware) });
        return;
      }

      if (req.method === 'POST' && url.pathname === '/api/admin/upload-apk') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const parts = await readMultipart(req);
        let filePart = null;
        let version = '';
        let force = false;
        let notes = '';
        for (const part of parts) {
          if (part.name === 'file' && part.filename) filePart = part;
          else if (part.name === 'version') version = part.data.toString('utf8').trim();
          else if (part.name === 'force') force = part.data.toString('utf8').trim().toLowerCase() === 'true';
          else if (part.name === 'notes') notes = part.data.toString('utf8').trim();
        }
        if (!filePart) {
          sendJson(res, 400, { error: 'missing file' });
          return;
        }
        version = sanitizeVersion(version, extractVersionFromFilename(filePart.filename) || '1.0.0');
        const apkName = `app_gif_${version}.apk`;
        const apkPath = path.join(apkDir, apkName);
        writeFileAtomicSync(apkPath, filePart.data);

        const baseUrl = getServerBaseUrl(req);
        const storeUrl = `${baseUrl}/downloads/apk/${encodeURIComponent(apkName)}`;

        let history = loadJson(appVersionsFile, defaultAppVersionHistory);
        history = upsertHistoryItem(history, {
          platform: 'android',
          version,
          filename: apkName,
          url: storeUrl,
          size: filePart.data.length,
          sha256: computeBufferSha256(filePart.data),
          force,
          notes: notes || `版本 ${version}`,
          uploadedAt: new Date().toISOString(),
        }, 'platform');
        saveJson(appVersionsFile, history);

        const versions = loadJson(versionsFile, defaultVersions);
        syncAppManifestFromHistory(versions, history, 'android');
        saveJson(versionsFile, versions);
        sendJson(res, 200, versions);
        return;
      }

      if (req.method === 'POST' && url.pathname === '/api/admin/upload-firmware') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const parts = await readMultipart(req);
        let filePart = null;
        let version = '';
        let notes = '';
        for (const part of parts) {
          if (part.name === 'file' && part.filename) filePart = part;
          else if (part.name === 'version') version = part.data.toString('utf8').trim();
          else if (part.name === 'notes') notes = part.data.toString('utf8').trim();
        }
        if (!filePart) {
          sendJson(res, 400, { error: 'missing file' });
          return;
        }
        version = sanitizeVersion(version, extractVersionFromFilename(filePart.filename) || '0.1.0');
        const fwName = `esp-baji-esp32s3-${version}.bin`;
        const fwPath = path.join(firmwareDir, fwName);
        writeFileAtomicSync(fwPath, filePart.data);

        const sha256 = await computeSha256(fwPath);
        const baseUrl = getFirmwareBaseUrl(req);
        const fwUrl = `${baseUrl}/downloads/firmware/${encodeURIComponent(fwName)}`;

        let history = loadJson(firmwareVersionsFile, defaultFirmwareVersionHistory);
        history = upsertHistoryItem(history, {
          hardware: 'esp32s3',
          version,
          filename: fwName,
          url: fwUrl,
          size: filePart.data.length,
          sha256,
          notes: notes || `固件版本 ${version}`,
          uploadedAt: new Date().toISOString(),
        }, 'hardware');
        saveJson(firmwareVersionsFile, history);

        const manifests = loadJson(otaFile, defaultOta);
        syncFirmwareManifestFromHistory(manifests, history, 'esp32s3');
        saveJson(otaFile, manifests);
        sendJson(res, 200, manifests);
        return;
      }

      const apkDownloadMatch = url.pathname.match(/^\/downloads\/apk\/(.+\.apk)$/);
      if ((req.method === 'GET' || req.method === 'HEAD') && apkDownloadMatch) {
        const apkName = path.basename(apkDownloadMatch[1]);
        const apkPath = path.join(apkDir, apkName);
        if (!fs.existsSync(apkPath)) {
          sendJson(res, 404, { error: 'apk not found' });
          return;
        }
        const stat = fs.statSync(apkPath);
        res.writeHead(200, {
          'content-type': 'application/vnd.android.package-archive',
          'content-length': stat.size,
          'content-disposition': `attachment; filename="${apkName}"`,
        });
        if (req.method === 'HEAD') {
          res.end();
          return;
        }
        fs.createReadStream(apkPath).pipe(res);
        return;
      }

      const fwDownloadMatch = url.pathname.match(/^\/downloads\/firmware\/(.+\.bin)$/);
      if ((req.method === 'GET' || req.method === 'HEAD') && fwDownloadMatch) {
        const fwName = path.basename(fwDownloadMatch[1]);
        const fwPath = path.join(firmwareDir, fwName);
        if (!fs.existsSync(fwPath)) {
          sendJson(res, 404, { error: 'firmware not found' });
          return;
        }
        const stat = fs.statSync(fwPath);
        res.writeHead(200, {
          'content-type': 'application/octet-stream',
          'content-length': stat.size,
          'content-disposition': `attachment; filename="${fwName}"`,
        });
        if (req.method === 'HEAD') {
          res.end();
          return;
        }
        fs.createReadStream(fwPath).pipe(res);
        return;
      }

      const factoryDownloadMatch = url.pathname.match(/^\/downloads\/factory\/([^/]+)\/(\d+)\/(.+)$/);
      if ((req.method === 'GET' || req.method === 'HEAD') && factoryDownloadMatch) {
        const itemId = normalizeFactoryItemId(decodeURIComponent(factoryDownloadMatch[1]));
        const revision = path.basename(factoryDownloadMatch[2]);
        const relative = factoryDownloadMatch[3].replace(/\\/g, '/');
        const filePath = path.join(factoryDownloadsDir, itemId, revision, relative);
        const root = path.resolve(factoryDownloadsDir);
        if (!path.resolve(filePath).startsWith(root + path.sep) || !fs.existsSync(filePath)) {
          sendJson(res, 404, { error: 'factory file not found' });
          return;
        }
        const stat = fs.statSync(filePath);
        const ext = path.extname(filePath).toLowerCase();
        const contentType = ext === '.png' ? 'image/png'
          : ext === '.mp4' ? 'video/mp4'
          : ext === '.eb4' ? 'application/octet-stream'
          : 'application/octet-stream';
        res.writeHead(200, {
          'content-type': contentType,
          'content-length': stat.size,
          'cache-control': 'public, max-age=31536000, immutable',
        });
        if (req.method === 'HEAD') {
          res.end();
          return;
        }
        fs.createReadStream(filePath).pipe(res);
        return;
      }

      if (req.method === 'POST' && url.pathname === '/api/assets') {
        const body = await readJsonBody(req);
        const name = sanitizeName(body.name);
        const packageBytes = decodeBase64(body.packageBase64, 'packageBase64');
        const packageSha256 = computeBufferSha256(packageBytes);
        const packageSize = Number(body.packageSize) || packageBytes.length;
        const crc32 = String(body.crc32 || '');
        const items = loadJson(metadataFile, []);
        const duplicate = findDuplicateAsset(items, packageSha256, crc32, packageSize);
        if (duplicate) {
          const nextPreviewMime = sanitizePreviewMime(body.previewMime);
          const hasIncomingPreview = typeof body.previewBase64 === 'string' && body.previewBase64.length > 0;
          const existingPreviewMissing = !duplicate.previewPath ||
            !fs.existsSync(path.join(dataDir, duplicate.previewPath));
          if (hasIncomingPreview &&
              (existingPreviewMissing || shouldReplacePreview(duplicate.previewMime, nextPreviewMime))) {
            removeRelativeFile(dataDir, duplicate.previewPath);
            const previewPath = path.join(previewsDir, `${duplicate.id}.bin`);
            fs.writeFileSync(previewPath, Buffer.from(body.previewBase64, 'base64'));
            duplicate.previewPath = path.relative(dataDir, previewPath);
            duplicate.previewMime = nextPreviewMime;
            saveJson(metadataFile, items);
          }
          sendJson(res, 200, publicAsset(duplicate));
          return;
        }

        const id = crypto.randomUUID();
        const packagePath = path.join(packagesDir, `${id}.eb4`);
        fs.writeFileSync(packagePath, packageBytes);

        let previewPath = null;
        let previewMime = null;
        if (typeof body.previewBase64 === 'string' && body.previewBase64.length > 0) {
          previewPath = path.join(previewsDir, `${id}.bin`);
          fs.writeFileSync(previewPath, Buffer.from(body.previewBase64, 'base64'));
          previewMime = sanitizePreviewMime(body.previewMime);
        }

        const item = {
          id,
          status: 'pending',
          name,
          userId: String(body.userId || 'anonymous'),
          crc32,
          packageSha256,
          packageSize,
          frameCount: Number(body.frameCount) || 0,
          fps: Number(body.fps) || 0,
          packagePath: path.relative(dataDir, packagePath),
          previewPath: previewPath ? path.relative(dataDir, previewPath) : null,
          previewMime,
          submittedAt: new Date().toISOString(),
        };
        items.unshift(item);
        saveJson(metadataFile, items);
        sendJson(res, 201, publicAsset(item));
        return;
      }

      const assetStatusMatch = url.pathname.match(/^\/api\/assets\/([^/]+)$/);
      if (req.method === 'GET' && assetStatusMatch) {
        const id = assetStatusMatch[1];
        const items = loadJson(metadataFile, []);
        const item = items.find((asset) => asset.id === id);
        sendJson(res, item ? 200 : 404, item ? publicAsset(item) : { error: 'asset not found' });
        return;
      }

      const previewMatch = url.pathname.match(/^\/api\/admin\/assets\/([^/]+)\/preview$/);
      if (req.method === 'GET' && previewMatch) {
        if (!requireAdmin(req, adminToken, url)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const id = previewMatch[1];
        const items = loadJson(metadataFile, []);
        const item = items.find((asset) => asset.id === id);
        if (!item || !item.previewPath) {
          sendJson(res, item ? 404 : 404, { error: item ? 'preview not found' : 'asset not found' });
          return;
        }
        const file = path.join(dataDir, item.previewPath);
        if (!fs.existsSync(file)) {
          sendJson(res, 404, { error: 'preview not found' });
          return;
        }
        res.writeHead(200, {
          'content-type': item.previewMime || 'application/octet-stream',
          'content-length': fs.statSync(file).size,
          'cache-control': 'no-store',
        });
        fs.createReadStream(file).pipe(res);
        return;
      }

      const packageMatch = url.pathname.match(/^\/api\/assets\/([^/]+)\/package$/);
      if (req.method === 'GET' && packageMatch) {
        const id = packageMatch[1];
        const items = loadJson(metadataFile, []);
        const item = items.find((asset) => asset.id === id);
        if (!item || item.status !== 'approved') {
          sendJson(res, item ? 403 : 404, { error: item ? 'asset not approved' : 'asset not found' });
          return;
        }
        const file = path.join(dataDir, item.packagePath);
        res.writeHead(200, {
          'content-type': 'application/octet-stream',
          'content-length': fs.statSync(file).size,
        });
        fs.createReadStream(file).pipe(res);
        return;
      }

      if (req.method === 'GET' && url.pathname === '/api/admin/assets') {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const status = url.searchParams.get('status');
        const items = loadJson(metadataFile, []);
        sendJson(res, 200, {
          items: items
            .filter((item) => !status || item.status === status)
            .map(publicAsset),
        });
        return;
      }

      const approveMatch = url.pathname.match(/^\/api\/admin\/assets\/([^/]+)\/approve$/);
      if (req.method === 'POST' && approveMatch) {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const body = await readJsonBody(req);
        const id = approveMatch[1];
        const items = loadJson(metadataFile, []);
        const item = items.find((asset) => asset.id === id);
        if (!item) {
          sendJson(res, 404, { error: 'asset not found' });
          return;
        }
        item.status = 'approved';
        item.reviewedAt = new Date().toISOString();
        item.reviewer = String(body.reviewer || 'admin');
        delete item.rejectReason;
        saveJson(metadataFile, items);
        sendJson(res, 200, publicAsset(item));
        return;
      }

      const rejectMatch = url.pathname.match(/^\/api\/admin\/assets\/([^/]+)\/reject$/);
      if (req.method === 'POST' && rejectMatch) {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const body = await readJsonBody(req);
        const id = rejectMatch[1];
        const items = loadJson(metadataFile, []);
        const item = items.find((asset) => asset.id === id);
        if (!item) {
          sendJson(res, 404, { error: 'asset not found' });
          return;
        }
        item.status = 'rejected';
        item.reviewedAt = new Date().toISOString();
        item.reviewer = String(body.reviewer || 'admin');
        item.rejectReason = String(body.reason || '内容不符合要求');
        saveJson(metadataFile, items);
        sendJson(res, 200, publicAsset(item));
        return;
      }

      const deleteMatch = url.pathname.match(/^\/api\/admin\/assets\/([^/]+)$/);
      if (req.method === 'DELETE' && deleteMatch) {
        if (!requireAdmin(req, adminToken)) {
          sendJson(res, 401, { error: 'unauthorized' });
          return;
        }
        const id = deleteMatch[1];
        const items = loadJson(metadataFile, []);
        const index = items.findIndex((asset) => asset.id === id);
        if (index === -1) {
          sendJson(res, 404, { error: 'asset not found' });
          return;
        }
        const [item] = items.splice(index, 1);
        removeRelativeFile(dataDir, item.packagePath);
        removeRelativeFile(dataDir, item.previewPath);
        saveJson(metadataFile, items);
        sendJson(res, 200, { ok: true });
        return;
      }

      sendJson(res, 404, { error: 'not found' });
    } catch (error) {
      sendJson(res, error.status || 500, { error: error.message || 'server error' });
    }
  };
}

module.exports = { createApp };
