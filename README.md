# HTools

把 UsedToken（Token 用量 / 进程监控）、常用粘贴板、ADB Bar 等小工具整合成一个原生 macOS 窗口应用（macOS 26+）。

| 侧边栏 | 来源 | 说明 |
| --- | --- | --- |
| Token 用量 | used-token | 按小时/天/周/月/总计统计 Claude Code、Codex、agy、DeepSeek Harness 的 Token，含趋势图 |
| 进程与内存 | used-token | 页面可见时每 3 秒刷新，可结束单个或全部进程 |
| 常用文本 | clipboard | 管理标签与文本；在任意应用按 `⌥ Space` 呼出原有的快速粘贴面板 |
| 跨设备粘贴板 | 新增 | Mac 自动上传文本与图片至阿里云；Android 复制、下载；仅保留最新 50 条 |
| 翻译 | HTranslate | 截图（`F4`）或粘贴图片，本机 Vision 识别文字，再用自己配置的 OpenAI 兼容接口翻译 |
| 手机调试 | adb-app | ADB / HDC 设备：截屏、录屏、内嵌实时投屏（Android 可点击/拖动操作，无需 scrcpy；鸿蒙为只读预览）、安装（可直接拖入窗口）、无线连接与配对、开发者选项、前台应用 |
| 散热背夹 | 新增 | 通过蓝牙控制黑鲨散热背夹：温度、制冷模式、风扇灯效、定时关闭、低温保护 |

关闭主窗口后 App 仍在后台运行，`⌥ Space` 依然可用；点击 Dock 图标重新打开窗口，`⌘Q` 退出。

## 构建

```bash
swift run                    # 开发运行
./scripts/build-app.sh       # 生成 dist/HTools.app（使用钥匙串中的开发证书签名）
open dist/HTools.app
```

必须用固定证书签名，否则每次重新构建后“辅助功能”（自动粘贴）和“本地网络”（无线 ADB）权限都会失效。可用 `HTOOLS_SIGN_IDENTITY` 指定证书。

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
