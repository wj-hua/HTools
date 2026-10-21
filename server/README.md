# 跨设备粘贴板服务

Mac HTools 自动上传文本和图片，Android 小纸夹读取、复制和下载。
使用 Python 标准库、SQLite、现有 Nginx HTTPS，不增加第三方运行时依赖。

## 当前部署

- 阿里云：`/opt/mino-clipboard/clipboard_server.py`
- systemd：`mino-clipboard.service`，开机自动启动、失败自动重启。
- 数据库：`/var/lib/mino-clipboard/clipboard.sqlite3`，由专用系统用户管理。
- 环境配置：`/etc/mino-clipboard.env`（权限 600），密钥不写入代码。
- HTTPS：`https://www.gtcode.xyz/clipboard-api`。
- 服务监听 Docker 网桥 `10.255.1.1:18081`，由现有 `vibecoding` Nginx 代理。
- 原 Nginx 配置备份：`/opt/vibecoding/nginx.conf.clipboard-backup-*`。

```sh
systemctl status mino-clipboard
journalctl -u mino-clipboard --since '10 minutes ago'
systemctl restart mino-clipboard
```

环境配置格式（密钥使用随机生成的至少 32 字符）：

```ini
CLIPBOARD_TOKEN=<随机密钥>
CLIPBOARD_HOST=10.255.1.1
CLIPBOARD_PORT=18081
CLIPBOARD_RETENTION_DAYS=0
```

`CLIPBOARD_RETENTION_DAYS=0` 表示不额外按天数过期。无论天数配置如何，
云端始终仅保留最新 50 条。若改为 7 或 30，超过该天数也会自动删除。
上传和读取时清理，同时每分钟执行一次后台清理。
文本和图片直接存于同一 SQLite 记录，删除时一起清除；启用 `secure_delete`，
释放的数据库页可复用，数据库文件不会每次删除后立即缩小。

Nginx HTTPS server 中的代理配置：

```nginx
location /clipboard-api/ {
    client_max_body_size 21m;
    proxy_pass http://10.255.1.1:18081/;
    proxy_set_header Host $host;
    proxy_set_header Authorization $http_authorization;
    proxy_connect_timeout 5s;
    proxy_read_timeout 35s;
    proxy_send_timeout 35s;
}
```

## API

每个请求都须使用 `Authorization: Bearer <密钥>`，响应禁止缓存。
`CLIPBOARD_TOKEN` 是 Mac 的主密钥；每台 Android 设备使用 Mac 签发的独立密钥，
服务器只保存其 SHA-256 摘要，可单独撤销。设备密钥只能访问记录，不能管理设备。

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/items` | 按上传顺序返回最新 50 条及清理策略 |
| PUT | `/items/{uuid}` | 上传 UTF-8 文本（1 MB）或 PNG 图片（20 MB） |
| GET | `/items/{uuid}/content` | 下载原始内容 |
| DELETE | `/items/{uuid}` | 删除记录及内容 |
| GET | `/devices` | 列出设备及最近连接时间（仅主密钥） |
| POST | `/devices` | `{"name": "..."}` 新建设备，仅此次返回设备密钥（仅主密钥） |
| DELETE | `/devices/{uuid}` | 撤销设备（仅主密钥） |

PUT 使用 `Content-Type: text/plain; charset=utf-8` 或 `image/png`，请求体为原始内容。
同一 UUID 重试不会增加记录或改变顺序。时间由服务器记录，单位为毫秒。
已被清理的记录返回 404；错误或已撤销的密钥返回 401；设备密钥调用设备接口返回 403。

## 客户端

Mac 的连接密钥保存在 macOS 钥匙串。首次部署的配对文件保存在本机
`~/Library/Application Support/com.mino.HTools/cloud-clipboard-connection.json`（600），
属于本机私有配置，不进入 Git。
Android 连接配置存于应用私有目录，禁止应用备份。
在 Mac 页面点“添加 Android 设备”，为每台设备生成独立的配对信息，在 Android 的“云端 → 连接”中粘贴；
设备列表显示最近连接时间，可单独撤销。

Mac 开启自动同步后，每秒检查剪贴板变化，跳过系统标记的隐藏、临时、自动生成内容。
启动/恢复同步时不上传之前的剪贴板。配对密钥不会上传。
断网时最多保留 50 条待上传记录，写入私有本地文件，重启后继续重试。
暂停后可清空待同步记录；上传中的单条请求可能会完成。
图片统一转为 PNG，最多 4000 万像素、20 MB；文本最多 1 MB。

Android 云端页面前台每 10 秒刷新，也可手动刷新；后台不监听剪贴板。
Android 10+ 复制图片通过系统 MediaStore 保存到“小纸夹粘贴板”相册，最多保留最近复制的 50 张。
重复复制复用图片；仅删除本应用创建的该相册缓存，独立下载文件不受影响。
Android 8/9 使用只读、按 URI 授权的 ContentProvider 和最多 50 张私有图片缓存。
为兼容系统剪贴板分享入口，复制时向已安装的微信显式授予该图片的读取权限，缓存淘汰时撤销。
系统文件保存窗口支持保存文本和图片，不需要共享存储权限。
已下载到用户选择位置的文件不会跟随云端记录删除。

## 已执行验证

Mac 固定证书签名构建；Android `assembleDebug lintDebug`；
独立临时数据库验证最新 50 条、图片内容清理、按天过期、鉴权、重复上传幂等、删除；
实际阿里云 HTTPS 接口和错误密钥拒绝访问；Mac 真实剪贴板文本、图片自动上传；
Android 模拟器展示、文本复制后完整粘贴、图片复制及系统文件保存窗口下载（与 Mac 原图逐字节一致）；
服务离线时本地落盘、Mac 重启后继续上传且清理队列文件；Mac 和 Android 浅色、深色截图检查。
连接的实体手机已升级安装并配对；实体手机锁屏，界面操作验证使用模拟器完成。
测试云端记录已删除。

Android 1.1.2 已在实体手机验证微信状态图片预览和发送给朋友的图片确认弹窗，
随后取消，未发送消息或发布状态。仅授予 URI 权限的 1.1.1 未能解决微信资源解析问题，
1.1.2 通过系统图片 URI 解决。
