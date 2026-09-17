const fs = require('node:fs');
const path = require('node:path');

const sourceRoot = path.resolve(process.argv[2] || '.migration/old-server-20260917');
const outputRoot = path.resolve(process.argv[3] || '.tmp/server-migration-payload');
const publicBase = String(process.argv[4] || 'http://47.108.204.22').replace(/\/$/, '');

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function rewriteUrls(value) {
  if (Array.isArray(value)) return value.map(rewriteUrls);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [key, rewriteUrls(nested)]),
    );
  }
  if (typeof value === 'string' && /^https?:\/\/60\.205\.122\.153(?:\/|$)/.test(value)) {
    return `${publicBase}${new URL(value).pathname}`;
  }
  return value;
}

fs.rmSync(outputRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(outputRoot, 'data'), { recursive: true });
fs.cpSync(path.join(sourceRoot, 'downloads'), path.join(outputRoot, 'data', 'downloads'), {
  recursive: true,
});

const manifestRoot = path.join(sourceRoot, 'manifest');
const versions = rewriteUrls(readJson(path.join(manifestRoot, 'versions.json')));
const ota = rewriteUrls(readJson(path.join(manifestRoot, 'ota.json')));
const appHistoryByPlatform = rewriteUrls(readJson(path.join(manifestRoot, 'app_history.json')));
const firmwareHistoryByHardware = rewriteUrls(readJson(path.join(manifestRoot, 'firmware_history.json')));
const factoryCatalogs = rewriteUrls(readJson(path.join(manifestRoot, 'factory_catalogs.json')));

const appHistory = Object.values(appHistoryByPlatform).flatMap((entry) => entry.items || []);
const firmwareHistory = Object.values(firmwareHistoryByHardware).flatMap(
  (entry) => entry.items || [],
);
const factoryCatalog = factoryCatalogs.esp32s3;
for (const item of factoryCatalog.items || []) {
  for (const file of item.deviceFiles || []) file.hardware = 'esp32s3';
}

writeJson(path.join(outputRoot, 'data', 'versions.json'), versions);
writeJson(path.join(outputRoot, 'data', 'ota.json'), ota);
writeJson(path.join(outputRoot, 'data', 'app_versions.json'), appHistory);
writeJson(path.join(outputRoot, 'data', 'firmware_versions.json'), firmwareHistory);
writeJson(path.join(outputRoot, 'data', 'factory_catalog.json'), factoryCatalog);
writeJson(path.join(outputRoot, 'data', 'assets', 'metadata.json'), []);

const sourceServer = path.resolve('server');
fs.mkdirSync(path.join(outputRoot, 'app'), { recursive: true });
fs.cpSync(path.join(sourceServer, 'src'), path.join(outputRoot, 'app', 'src'), {
  recursive: true,
});
fs.copyFileSync(
  path.join(sourceServer, 'package.json'),
  path.join(outputRoot, 'app', 'package.json'),
);

const files = [];
let totalBytes = 0;
for (const entry of fs.readdirSync(outputRoot, { recursive: true, withFileTypes: true })) {
  if (!entry.isFile()) continue;
  const file = path.join(entry.parentPath, entry.name);
  const size = fs.statSync(file).size;
  totalBytes += size;
  files.push({ path: path.relative(outputRoot, file).replace(/\\/g, '/'), size });
}
writeJson(path.join(outputRoot, 'payload.json'), {
  generatedAt: new Date().toISOString(),
  source: sourceRoot,
  publicBase,
  fileCount: files.length,
  totalBytes,
  files,
});

console.log(JSON.stringify({ outputRoot, fileCount: files.length, totalBytes }, null, 2));
