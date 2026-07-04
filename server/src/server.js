const http = require('node:http');
const path = require('node:path');
const { createApp } = require('./app');

const port = Number(process.env.PORT || 8787);
const host = process.env.HOST || '0.0.0.0';
const dataDir = process.env.ESP_BAJI_DATA_DIR || path.join(__dirname, '..', 'data');
const app = createApp({
  dataDir,
  adminToken: process.env.ESP_BAJI_ADMIN_TOKEN || '123456',
});

http.createServer(app).listen(port, host, () => {
  console.log(`ESP BAJI server listening on http://${host}:${port}`);
  console.log(`Data directory: ${dataDir}`);
});
