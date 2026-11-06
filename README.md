# HTools

把 UsedToken（Token 用量 / 进程监控）、常用粘贴板、ADB Bar 等小工具整合成一个原生 macOS 窗口应用（macOS 26+）。

| 侧边栏 | 来源 | 说明 |
| --- | --- | --- |
| Token 用量 | used-token | 按小时/天/周/月/总计统计 Claude Code、Codex、agy、DeepSeek Harness 的 Token，含趋势图与时区选择 |
| 进程与内存 | used-token | 页面可见时每 3 秒刷新，可结束单个或全部进程 |
| 常用文本 | clipboard | 管理标签与文本；在任意应用按 `⌥ Space` 呼出原有的快速粘贴面板 |
| 跨设备粘贴板 | 新增 | Mac 自动上传文本与图片至阿里云；Android 复制、下载；仅保留最新 50 条 |
| 翻译 | HTranslate | 截图（`F4`）或粘贴图片，本机 Vision 识别文字，再用自己配置的 OpenAI 兼容接口翻译 |
| 手机调试 | adb-app | ADB / HDC 设备：截屏、录屏、内嵌实时投屏（Android 可点击/拖动操作，无需 scrcpy；鸿蒙为只读预览）、安装（Android 支持 APK / AAB，可直接拖入窗口）、无线连接与配对、开发者选项、前台应用 |
| 散热背夹 | 新增 | 通过蓝牙控制黑鲨散热背夹：温度、制冷模式、风扇灯效、定时关闭、低温保护 |

安装 AAB 需要 `bundletool` 和 Java，可通过 `brew install bundletool` 安装。生成的 APK 使用本机 Android 调试密钥；如果尚无调试密钥，可先用 Android Studio 构建一次调试版应用。手机上已有应用的签名不一致时无法覆盖安装，卸载已有应用会删除其数据。AAB 安装完成后需要手动打开应用。

关闭主窗口后 App 仍在后台运行，`⌥ Space` 依然可用；点击 Dock 图标重新打开窗口，`⌘Q` 退出。

## 构建

```bash
swift run                    # 开发运行
./scripts/build-app.sh       # 生成 dist/HTools.app（使用钥匙串中的开发证书签名）
open dist/HTools.app
```

必须用固定证书签名，否则每次重新构建后“辅助功能”（自动粘贴）和“本地网络”（无线 ADB）权限都会失效。可用 `HTOOLS_SIGN_IDENTITY` 指定证书。

## MCP：在 HCode 中使用 HTools

HTools 可作为本机只读 MCP 服务运行，无需打开图形界面。先用 `./scripts/build-app.sh` 构建，然后在 HCode 的 MCP 管理中为对应的 AI 添加命令形式的服务：

- 名称：`htools`
- 命令：`/你的/HTools.app/Contents/MacOS/HTools`（使用实际 app 的绝对路径）
- 参数：`--mcp`

例如，本项目的构建产物为 `dist/HTools.app/Contents/MacOS/HTools`，配置时请填写其绝对路径。也可用开发版 `.build/debug/HTools` 的绝对路径，但清理或移动构建目录后需要重新构建。配置后新建或重启相应 AI 会话，再询问“今天 token 用量是多少？”等问题。不同 Provider 和受限会话能否加载外部 MCP 取决于 HCode 的配置。

Token 用量页面可选择统计时区，默认跟随系统；该设置也适用于菜单栏和 MCP 的 Token 查询。

HTools 侧边栏的“MCP 管理”页面提供连接信息和工具开关。关闭工具后，服务会拒绝新的调用；重新连接 MCP 客户端可刷新工具列表。MCP 服务由客户端启动，页面不显示客户端连接状态。

目前提供 `get_token_usage`、`list_ai_processes`、`list_tasks`、`list_devices`、`get_device_info`、`get_foreground_app`、`capture_device_screen`、`upload_to_pgyer` 以及 Stetho 网络抓包工具组（`list_stetho_targets`、`capture_stetho_requests`、`start_stetho_capture`、`get_stetho_requests`、`stop_stetho_capture`）。手机截图返回 MCP 图片内容，支持 Android 和鸿蒙；实际展示和识图取决于客户端及模型是否支持图片。多台设备连接时，先用设备列表取得 ID，并在设备信息、前台应用查询、截图或抓包时指定 ID；只有一台已连接设备时可以省略。Stetho 抓包支持自动发现手机上集成 Stetho 的应用，可单次即时抓取（默认 10 秒并自动读取响应正文）或建立后台会话持续记录，支持按 URL 和状态码过滤、提取请求标头、cURL 及格式化正文，停止后自动释放端口转发。待办读取磁盘上已保存的数据，不修改任务；界面中尚未保存的编辑可能暂时不出现。蒲公英上传支持 APK、IPA 与 HAP 安装包，自动读取钥匙串中保存的 API Key（也可传参指定），返回下载链接、二维码及分享文案，并同步记录至应用历史列表。

用量依赖本机可读取的历史记录，DeepSeek 统计还需要 `zstd`；来源缺失或解析失败可能导致结果不完整，结果并非账单。设备列表复用 HTools 的 ADB/HDC 实现，桥接工具执行失败时可能返回空列表。MCP 服务不写入 HTools 的用量缓存，也不返回进程命令行或配置密钥。工具及后续计划见 [MCP 计划](docs/HTools-MCP计划.md)。

常用文本数据沿用原路径 `~/Library/Application Support/com.mino.CommonClipboard/items.json`，无需迁移。

## 参与开发

**界面开发必须遵循 [apple-design](https://github.com/emilkowalski/skills/blob/main/skills/apple-design/SKILL.md)**：
即时响应、可打断的弹簧动画、尊重“减弱动态效果”、系统材质与语义色、反馈分四类（状态 / 完成 / 警告 / 错误）。
共享的组件与动效参数集中在 `Sources/HTools/App/DesignSystem.swift`，新增界面请优先复用。
具体对应关系和其他约定见 [CLAUDE.md](CLAUDE.md)。

## 跨设备粘贴板

打开侧边栏“跨设备粘贴板”，配置 HTTPS 地址与密钥，开启“自动同步”。
之后复制的文本和图片会上传，关闭主窗口后仍继续同步；可随时暂停。
断网时保留最新 50 条待上传记录并自动重试。

Android 项目位于 [Android/Clipboard](Android/Clipboard)，在小纸夹首页点击“云端”。
在 Mac 页面点“添加 Android 设备”，为每台手机生成独立配对信息，在手机“连接”中粘贴；可在设备列表中单独撤销。
云端记录可复制或下载，Android 图片复制支持接收图片的应用。

服务器只保留最新 50 条，超出的记录及图片自动删除。
部署、可选天数过期设置与 API 见 [服务说明](server/README.md)。

## 翻译

由独立项目 HTranslate 合并而来。按 `F4`（或截图时点工具栏的翻译按钮 / `⌘E`）框选区域，
文字在本机识别后自动翻译，结果显示在侧边栏“翻译”页；也可以直接输入文字，或 `⇧⌘V` 识别剪贴板图片。
快捷键与截图共用一组预设（`F1 / F3 / F4` 或 `⌃⌥A / ⌃⌥P / ⌃⌥T`），在“截图”页切换。

在翻译页点模型名 → “接口设置…”管理接口：支持多组 OpenAI 兼容 Chat Completions 配置、每组多个模型、流式输出和推理强度。
API Key 只存 Keychain（沿用 HTranslate 的 `com.mino.HTranslate.api-key`），首次运行会自动导入 HTranslate 已保存的配置。

## Stetho 网络抓包

在“手机调试”中连接 Android 设备，点击“打开 Stetho 抓包”，选择应用 / 进程后开始抓包，再操作手机上的应用。
支持 USB 和无线 ADB，可筛选 URL、方法与状态码，查看请求头、请求正文、响应正文（JSON 自动格式化），以及复制 URL 和 cURL。

手机应用需已初始化 Stetho，并接入相应的网络拦截器（例如 OkHttp 的 StethoInterceptor）；无需设置代理或安装证书。
只记录开始抓包后、通过 Stetho 上报的 HTTP / HTTPS 请求，最近 500 条保留在内存中；开始新一轮抓包会清空旧记录。
响应正文在选中“响应正文”时读取，请在停止抓包前查看。单条响应正文上限为 1 MB，正文缓存合计最多 16 MB。
关闭抓包窗口会断开连接并清理该会话创建的 ADB 端口转发。

## 散热背夹

打开侧边栏“散热背夹”，HTools 会搜索附近的背夹，点“连接”即可；之后进入页面会自动连上次的背夹。
背夹被手机连着时不会广播，需要先在手机上断开。

这是非官方实现，与黑鲨无关。协议由实机抓包得到，目前只在 Black Shark MagCooler 4Pro 上验证过，其他型号可能不兼容。
