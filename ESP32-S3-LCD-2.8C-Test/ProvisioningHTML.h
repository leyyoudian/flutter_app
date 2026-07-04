#pragma once

static const char WIFI_PROVISIONING_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>设备配网</title>
    <style>
        :root {
            color-scheme: dark;
            --bg: #050614;
            --panel: rgba(19, 26, 52, 0.9);
            --accent: #54ffe8;
            --accent-secondary: #8c5bff;
            --text-primary: #eaf6ff;
            --text-muted: #9aa8c6;
            --danger: #ff6b81;
            --success: #79f6c0;
        }
        * { box-sizing: border-box; }
        body {
            font-family: 'Space Grotesk', 'Microsoft YaHei', sans-serif;
            margin: 0;
            min-height: 100vh;
            padding: 24px;
            background: radial-gradient(circle at 20% 20%, rgba(142, 91, 255, 0.25), transparent 60%),
                        radial-gradient(circle at 80% 0%, rgba(84, 255, 232, 0.25), transparent 55%),
                        linear-gradient(135deg, #03050f, #050614);
            color: var(--text-primary);
            display: flex;
            justify-content: center;
            align-items: center;
        }
        .container {
            width: min(420px, 100%);
            background: var(--panel);
            border-radius: 20px;
            padding: 28px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.45);
            border: 1px solid rgba(255, 255, 255, 0.06);
        }
        .hero { text-align: left; margin-bottom: 28px; }
        .hero .eyebrow {
            letter-spacing: 0.3em;
            font-size: 12px;
            text-transform: uppercase;
            color: var(--accent);
            margin: 0 0 6px;
        }
        .hero h1 { margin: 0; font-size: 28px; font-weight: 600; }
        .hero .subtitle { margin: 8px 0 0; color: var(--text-muted); font-size: 14px; }
        .form-group { margin-bottom: 18px; }
        label { display: block; font-size: 14px; color: var(--text-muted); margin-bottom: 6px; }
        select, input[type="password"] {
            width: 100%;
            padding: 12px 14px;
            border-radius: 10px;
            border: 1px solid rgba(255, 255, 255, 0.08);
            background: rgba(0, 0, 0, 0.25);
            color: var(--text-primary);
            font-size: 15px;
            transition: border 0.2s ease;
        }
        select:focus, input:focus { outline: none; border-color: var(--accent); }
        .actions { display: flex; gap: 12px; flex-wrap: wrap; }
        button {
            flex: 1;
            padding: 14px;
            border-radius: 12px;
            border: none;
            font-size: 15px;
            font-weight: 600;
            cursor: pointer;
            transition: transform 0.15s ease, opacity 0.15s ease;
        }
        button.primary { background: linear-gradient(120deg, var(--accent-secondary), var(--accent)); color: #050614; }
        button.ghost { background: rgba(255, 255, 255, 0.08); color: var(--text-primary); }
        button.danger { background: rgba(255, 107, 129, 0.14); color: var(--danger); }
        button:active { transform: translateY(1px); opacity: 0.9; }
        #status {
            margin-top: 18px;
            padding: 12px 14px;
            border-radius: 10px;
            font-size: 14px;
            display: none;
            text-align: center;
        }
        #status.info { color: var(--accent); background: rgba(84, 255, 232, 0.08); }
        #status.error { color: var(--danger); background: rgba(255, 107, 129, 0.08); }
        #status.success { color: var(--success); background: rgba(121, 246, 192, 0.08); }
        @media (max-width: 480px) {
            body { padding: 16px; }
            .container { padding: 22px; }
            .actions { flex-direction: column; }
        }
    </style>
</head>
<body>
    <div class="container">
        <header class="hero">
            <p class="eyebrow">WANOU DEVICE</p>
            <h1>Wi-Fi 配网</h1>
            <p class="subtitle">选择网络、输入密码后连接</p>
        </header>

        <div class="form-group">
            <label for="ssid">可用网络</label>
            <select id="ssid">
                <option value="">正在扫描网络...</option>
            </select>
        </div>

        <div class="form-group">
            <label for="password">Wi-Fi 密码</label>
            <input type="password" id="password" placeholder="请输入密码">
        </div>

        <div class="actions">
            <button id="submit" class="primary">连接 Wi-Fi</button>
            <button id="rescanBtn" class="ghost" onclick="scanWiFi(true)">重新扫描</button>
            <button id="clearBtn" class="danger">清除已保存 Wi-Fi</button>
        </div>

        <div id="status" class="info"></div>
    </div>

    <script>
        // 页面加载时初始化
        window.addEventListener('DOMContentLoaded', function() {
            console.log('页面加载完成');
            
            // 自动扫描WiFi
            scanWiFi(false);
            
            // 绑定按钮点击事件
            document.getElementById('submit').addEventListener('click', function() {
                connectWiFi();
            });
            document.getElementById('clearBtn').addEventListener('click', function() {
                clearProvisioning();
            });
        });

       // 修改 scanWiFi 函数
function scanWiFi(forceRescan = false) {
    const url = '/scan' + (forceRescan ? '?force=true' : '');
    
    fetch(url)
        .then(response => response.json())
        .then(data => {
            console.log('扫描结果:', data);
            
            if (data.success) {
                if (data.status === 'scaning') {
                    // 仍在扫描，1.5秒后重试
                    setTimeout(() => scanWiFi(false), 1500);
                    updateStatus('正在扫描网络...', 'info');
                } 
                else if (data.status === 'completed' || data.data) {
                    // 扫描完成
                    updateStatus('扫描完成', 'success');
                    updateNetworkList(data.data || []);
                }
            }
        })
        .catch(error => {
            console.error('扫描失败:', error);
            updateStatus('扫描失败，2秒后重试', 'error');
            setTimeout(() => scanWiFi(false), 2000);
        });
}

// 更新网络列表
function updateNetworkList(networks) {
    const select = document.getElementById('ssid');
    
    // 保存当前选中的值
    const currentValue = select.value;
    
    // 清空选项（保留第一个提示选项）
    if (select.options.length > 0 && select.options[0].value === '') {
        select.innerHTML = '';
        select.appendChild(new Option('请选择网络...', ''));
    } else {
        select.innerHTML = '<option value="">请选择网络...</option>';
    }
    
    if (networks.length > 0) {
        // 按信号强度排序
        networks.sort((a, b) => b.rssi - a.rssi);
        
        networks.forEach(function(network) {
            const signal = getSignalStrength(network.rssi);
            const option = new Option(
                `${network.ssid} (${signal}, Ch${network.channel})`,
                network.ssid
            );
            select.appendChild(option);
        });
        
        // 恢复之前选中的值
        if (currentValue) {
            select.value = currentValue;
        }
    } else {
        select.innerHTML = '<option value="">未发现网络</option>';
    }
}

// 添加重新扫描按钮
function addRescanButton() {
    if (document.getElementById('rescanBtn')) {
        return; // 按钮已存在
    }
    
    const submitBtn = document.getElementById('submit');
    const rescanBtn = document.createElement('button');
    rescanBtn.id = 'rescanBtn';
    rescanBtn.textContent = '重新扫描';
    rescanBtn.style.cssText = `
        width: 100%;
        padding: 12px;
        margin-top: 10px;
        background: linear-gradient(90deg, #3498db, #2980b9);
        color: white;
        border: none;
        border-radius: 5px;
        font-size: 14px;
        cursor: pointer;
    `;
    
    rescanBtn.onclick = function() {
        updateStatus('重新扫描中...', 'info');
        scanWiFi(true); // 强制重新扫描
    };
    
    submitBtn.parentNode.insertBefore(rescanBtn, submitBtn.nextSibling);
}

// 获取信号强度描述
function getSignalStrength(rssi) {
    if (rssi >= -50) return '强';
    if (rssi >= -60) return '良好';
    if (rssi >= -70) return '一般';
    return '弱';
}

// 更新状态显示
function updateStatus(message, type) {
    const statusDiv = document.getElementById('status');
    if (!statusDiv) return;
    
    statusDiv.textContent = message;
    statusDiv.style.display = 'block';
    statusDiv.style.color = type === 'error' ? '#e74c3c' : 
                           type === 'success' ? '#2ecc71' : '#3498db';
}
        // 连接WiFi
        function connectWiFi() {
            const ssid = document.getElementById('ssid').value;
            const password = document.getElementById('password').value;
            
            if (!ssid || ssid === '') {
                showStatus('请选择Wi-Fi网络', 'error');
                return;
            }
            
            showStatus('正在保存配置...', 'info');
            
            const params = new URLSearchParams({
                wifi_name: ssid,
                wifi_pwd: password,
            });
            
            fetch('/set_config?' + params.toString())
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        showStatus('配置已保存，正在等待设备连接路由器...', 'info');
                        pollConnectionStatus(0);
                    } else {
                        showStatus('保存失败: ' + (data.message || '未知错误'), 'error');
                    }
                })
                .catch(error => {
                    showStatus('保存配置失败，请保持连接 ESP-DotLoop-Setup 后重试', 'error');
                });
        }

        function clearProvisioning() {
            if (!confirm('确定清除设备里保存的 Wi-Fi 吗？清除后设备会重新开启配网热点。')) {
                return;
            }

            showStatus('正在清除已保存 Wi-Fi...', 'info');
            fetch('/clear_config?t=' + Date.now(), { cache: 'no-store' })
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        showStatus('已清除，设备正在重新开启 ESP-DotLoop-Setup 配网热点', 'success');
                    } else {
                        showStatus('清除失败: ' + (data.message || '未知错误'), 'error');
                    }
                })
                .catch(error => {
                    showStatus('清除请求已发送，若页面断开请重新连接 ESP-DotLoop-Setup', 'info');
                });
        }

        function pollConnectionStatus(attempt) {
            fetch('/wifi_status?t=' + Date.now(), { cache: 'no-store' })
                .then(response => response.json())
                .then(data => {
                    if (data.connected) {
                        const ipText = data.ip ? `IP：${data.ip}` : '已连接到路由器';
                        showStatus('配网成功，' + ipText, 'success');
                        setTimeout(() => {
                            document.body.innerHTML = '<div style="text-align: center; padding: 50px;"><h1>配网成功</h1><p>设备已连接到 Wi-Fi。手机可以切回原来的网络后打开 App 使用。</p></div>';
                        }, 1200);
                        return;
                    }

                    if (attempt >= 30) {
                        const reason = data.reason ? `（原因码 ${data.reason}）` : '';
                        showStatus('暂未连接成功' + reason + '，请确认密码或重新选择网络', 'error');
                        return;
                    }

                    const message = data.connecting
                        ? '正在连接路由器...'
                        : '等待设备重新尝试连接...';
                    showStatus(message, 'info');
                    setTimeout(() => pollConnectionStatus(attempt + 1), 1000);
                })
                .catch(error => {
                    if (attempt >= 30) {
                        showStatus('无法读取设备状态，请重新连接 ESP-DotLoop-Setup 后查看', 'error');
                        return;
                    }
                    setTimeout(() => pollConnectionStatus(attempt + 1), 1000);
                });
        }

        // 显示状态信息
        function showStatus(message, type) {
            const statusDiv = document.getElementById('status');
            statusDiv.textContent = message;
            statusDiv.style.display = 'block';
            statusDiv.style.color = type === 'error' ? '#ff6b6b' : 
                                   type === 'success' ? '#51cf66' : '#339af0';
        }
    </script>
</body>
</html>
)rawliteral";
