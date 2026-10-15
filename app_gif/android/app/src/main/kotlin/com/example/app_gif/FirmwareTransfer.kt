package com.example.app_gif

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** Bounded, file-backed OTA. Internet download finishes before joining the badge AP. */
internal class FirmwareTransfer(
    private val directory: File,
    private val internet: (URL) -> HttpURLConnection,
    private val device: (URL) -> HttpURLConnection,
    private val diagnostic: (String) -> Unit = {},
) {
    class Failure(val code: String, message: String) : IOException(message)

    private fun connection(url: URL, remote: Boolean) =
        (if (remote) internet(url) else device(url)).apply {
            connectTimeout = 10_000
            readTimeout = 120_000
            instanceFollowRedirects = false
        }

    private fun response(conn: HttpURLConnection): JSONObject {
        val status = conn.responseCode
        val text = (if (status in 200..299) conn.inputStream else conn.errorStream)
            ?.bufferedReader()?.use { it.readText().take(8192) } ?: ""
        if (status !in 200..299) {
            val detail = runCatching { JSONObject(text).optString("error") }.getOrDefault("")
            throw Failure(if (status == 404) "firmware_unavailable" else if (status >= 500) "network_unavailable" else "firmware_rejected",
                if (status == 404) "该设备型号暂无可用固件" else "固件请求失败 HTTP $status ${detail.take(160)}")
        }
        return JSONObject(text)
    }

    private fun validate(meta: Map<String, Any?>) {
        val hardware = meta["hardware"] as? String
        val version = meta["version"] as? String ?: ""
        val sha = meta["sha256"] as? String ?: ""
        val size = (meta["size"] as? Number)?.toLong() ?: 0
        val url = runCatching { URL(meta["url"] as? String ?: "") }.getOrNull()
        if (hardware != "esp32p4-2.8" || version.isBlank() || version.length > 31 ||
            !sha.matches(Regex("[0-9a-fA-F]{64}")) || size !in 288..3L * 1024 * 1024 ||
            url == null || url.protocol !in listOf("http", "https") || url.host.isBlank()) {
            throw Failure("firmware_invalid", "固件清单不完整或设备型号不匹配")
        }
    }

    fun check(backend: String, hardware: String): Map<String, Any?> {
        if (hardware != "esp32p4-2.8") throw Failure("firmware_invalid", "暂不支持此设备型号")
        val conn = connection(URL("${backend.trimEnd('/')}/api/ota/manifest?hardware=$hardware"), true)
        try {
            val data = response(conn)
            val meta = mapOf("hardware" to data.optString("hardware"), "version" to data.optString("version"),
                "url" to data.optString("url"), "sha256" to data.optString("sha256"),
                "size" to data.optLong("size"), "notes" to data.optString("notes"))
            validate(meta)
            return meta
        } finally { conn.disconnect() }
    }

    private fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = input.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }

    private fun verify(file: File, meta: Map<String, Any?>) {
        if (file.length() != (meta["size"] as Number).toLong() ||
            !digest(file).equals(meta["sha256"] as String, ignoreCase = true)) {
            throw Failure("firmware_invalid", "固件长度或 SHA256 校验失败，请重新下载")
        }
        file.inputStream().use { input ->
            val header = ByteArray(288)
            java.io.DataInputStream(input).readFully(header)
            fun field(offset: Int, length: Int) = header.copyOfRange(offset, offset + length)
                .takeWhile { it.toInt() != 0 }.toByteArray().toString(Charsets.UTF_8)
            if ((header[0].toInt() and 255) != 0xe9 || field(48, 32) != meta["version"] ||
                field(80, 32) != "esp32-p4c5-dotloop") {
                throw Failure("firmware_invalid", "固件内容与版本清单不一致")
            }
        }
    }

    fun download(meta: Map<String, Any?>): Map<String, Any?> {
        validate(meta)
        directory.mkdirs()
        val file = File(directory, "${meta["sha256"]}.bin")
        if (file.exists() && runCatching { verify(file, meta) }.isSuccess) return mapOf("assetPath" to file.absolutePath)
        val partial = File(directory, "${meta["sha256"]}.part")
        val conn = connection(URL(meta["url"] as String), true)
        try {
            val status = conn.responseCode
            if (status != 200) { response(conn); throw Failure("firmware_invalid", "固件下载响应错误") }
            val expected = (meta["size"] as Number).toLong()
            val contentLength = (conn.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L)
            if (contentLength >= 0 && contentLength != expected) throw Failure("firmware_invalid", "固件下载长度不匹配")
            conn.inputStream.use { input -> partial.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > expected) throw Failure("firmware_invalid", "固件超出清单长度")
                    output.write(buffer, 0, count)
                }
            } }
            verify(partial, meta)
            if (file.exists()) file.delete()
            if (!partial.renameTo(file)) throw IOException("固件缓存保存失败")
            return mapOf("assetPath" to file.absolutePath)
        } finally { conn.disconnect(); partial.delete() }
    }

    fun upload(meta: Map<String, Any?>, host: String): Map<String, Any?> {
        val started = System.nanoTime()
        fun log(message: String) = diagnostic("${(System.nanoTime() - started) / 1_000_000}ms $message")
        validate(meta)
        val file = File(meta["assetPath"] as? String ?: "")
        // Only a verified download owned by this application may be flashed.
        if (file.canonicalFile.parentFile != directory.canonicalFile) throw Failure("firmware_invalid", "固件缓存地址无效")
        verify(file, meta)
        log("preflight version=${meta["version"]} bytes=${file.length()}")
        val statusConn = connection(URL("http://$host/ota/status"), false)
        try {
            if (statusConn.responseCode == 404) throw Failure("firmware_unsupported", "设备当前固件不支持手机更新，请先安装支持更新的固件")
            val status = response(statusConn)
            if (!status.optBoolean("relay") || status.optString("hardware") != meta["hardware"] ||
                status.optString("deviceId") != meta["deviceId"] || status.optLong("maxSize") < file.length()) {
                throw Failure("firmware_invalid", "热点设备身份或固件型号不匹配，已停止更新")
            }
            if (status.optBoolean("otaActive")) throw Failure("firmware_busy", "设备正在更新，请稍后重试")
            log("preflight verified")
        } finally { statusConn.disconnect() }
        val conn = connection(URL("http://$host/ota/upload"), false)
        var sent = 0L
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/octet-stream")
            conn.setRequestProperty("X-OTA-Hardware", meta["hardware"] as String)
            conn.setRequestProperty("X-OTA-Version", meta["version"] as String)
            conn.setRequestProperty("X-OTA-SHA256", meta["sha256"] as String)
            conn.setFixedLengthStreamingMode(file.length())
            log("upload start")
            conn.outputStream.use { output -> file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    sent += count
                    if (sent % (256 * 1024) == 0L || sent == file.length()) log("upload bytes=$sent/${file.length()}")
                }
            } }
            log("body sent; awaiting device verification")
            val reply = response(conn)
            if (!reply.optBoolean("success") || reply.optString("version") != meta["version"]) {
                throw Failure("firmware_rejected", "设备未确认固件更新成功")
            }
            log("device confirmed version=${reply.optString("version")}")
            return mapOf("success" to true, "version" to reply.optString("version"), "rebooting" to true)
        } catch (error: Failure) {
            log("device rejected code=${error.code} sent=$sent/${file.length()}")
            throw error
        } catch (error: org.json.JSONException) {
            log("invalid acknowledgement sent=$sent/${file.length()}")
            throw Failure("firmware_result_unknown",
                "固件已传送，但设备确认响应不完整。设备可能已更新并重启，请重新连接并查看实际固件版本后再决定是否重试。")
        } catch (error: IOException) {
            log("transport failure=${error.javaClass.simpleName} sent=$sent/${file.length()}")
            // A lost HTTP response after sending the whole image cannot prove
            // failure: the device may already have verified it and rebooted.
            // Never retry this POST automatically.
            if (sent == file.length()) throw Failure("firmware_result_unknown",
                "固件已传送，但手机未收到更新结果。设备可能已更新并重启，请重新连接并查看实际固件版本后再决定是否重试。")
            throw Failure("firmware_transfer_interrupted", "固件传输中断（$sent/${file.length()} 字节），请保持手机连接设备热点后重试。")
        } finally { conn.disconnect() }
    }
}
