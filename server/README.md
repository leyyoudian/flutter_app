# ESP BAJI Server

服务端覆盖以下能力：

- `GET /api/version?platform=android|ios`：App 远程版本检查。
- `POST /api/assets`：App 提交用户自定义素材，状态默认为 `pending`。
- `GET /api/admin/assets?status=pending`、`POST /api/admin/assets/:id/approve|reject`：管理员审核。
- `GET /api/ota/manifest?hardware=esp32s3`：ESP32 固件 OTA manifest。
- `GET /api/factory-catalog?hardware=esp32s3|esp32p4`：按硬件返回官方素材包。
- `POST /api/transcode`：流式接收视频，按 S3/P4 生成不同 EBAJ4 包。

本地启动：

```bash
npm test
npm start
```

部署到正式服务器时，建议把 `server/data` 换成数据库和对象存储，并把 `ESP_BAJI_ADMIN_TOKEN` 设置为强随机值。

## 正式部署网络

- 公网放行 TCP 80：当前固件使用 HTTP OTA/API，迁移阶段必须保留。
- 公网放行 TCP 443：用于 App HTTPS API，配置证书后逐步切换。
- TCP 22 仅对白名单管理地址放行，不应全网开放。
- Node 监听的 TCP 8787 只允许本机/内网访问，由 Nginx 反向代理；不要公网放行。
- 设备局域网端口 3333/3334 不属于云服务器安全组，不要在云服务器放行。

Nginx 的 `/api/transcode` 必须至少配置 `client_max_body_size 1024m`、
`proxy_request_buffering off` 和足够长的超时，否则大视频会被代理层拒绝或完整缓冲：

```nginx
location / {
    client_max_body_size 1024m;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

服务器需要 Node.js 18+、FFmpeg/FFprobe，并将 `server/data` 持久化备份。
