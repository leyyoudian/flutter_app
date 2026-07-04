# ESP BAJI Server

本地服务端先覆盖三件事：

- `GET /api/version?platform=android|ios`：App 远程版本检查。
- `POST /api/assets`：App 提交用户自定义素材，状态默认为 `pending`。
- `GET /api/admin/assets?status=pending`、`POST /api/admin/assets/:id/approve|reject`：管理员审核。
- `GET /api/ota/manifest?hardware=esp32s3`：ESP32 固件 OTA manifest。

本地启动：

```bash
npm test
npm start
```

部署到正式服务器时，建议把 `server/data` 换成数据库和对象存储，并把 `ESP_BAJI_ADMIN_TOKEN` 设置为强随机值。
