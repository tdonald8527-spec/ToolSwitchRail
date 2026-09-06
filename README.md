# Tool Switch Rail for macOS — Command Line Tools 版

不需要安装完整 Xcode。只要 Mac 已有 Apple Command Line Tools 和 Swift，即可通过 `build.command` 生成可直接双击运行的原生 macOS `.app`。

## 你当前的环境

已确认：

- `/Library/Developer/CommandLineTools`
- Apple Swift 6.4
- Apple Silicon / arm64

因此可以直接使用本版本。

## 第一次使用

1. 解压整个 `ToolSwitchRail` 文件夹。
2. 双击 `build.command`。
3. Terminal 会自动编译，并在 `Dist/` 生成：
   `Tool Switch Rail.app`
4. 双击该 `.app` 运行。
5. 第一次运行后，在：
   `系统设置 → 隐私与安全性 → 辅助功能`
   允许 **Tool Switch Rail**。
6. 再点击侧轨中的工具图标测试窗口切换。

如果 macOS 因为下载文件的安全属性阻止双击脚本，可以在 Terminal 中进入该目录后执行：

```bash
chmod +x build.command run.command
./build.command
```

## 以后怎么用

正常使用只双击：

`Dist/Tool Switch Rail.app`

不需要每次编译。

只有源码更新后才重新双击 `build.command`。

也提供 `run.command`：如果还没构建，它会先自动构建，然后启动 App。

## 当前功能

- 原生 SwiftUI + AppKit，不使用 Electron
- 56px 左侧轻量毛玻璃轨
- 自动跟随 macOS Light / Dark appearance
- 桌面 App：按 `appName` / `bundleIdentifier` 启动、寻找、聚焦窗口
- Web：使用 Google Chrome `--app=<url>` 创建独立网页窗口
- Web 窗口按 `titleContains` 精确匹配
- 不 hide 整个 Chrome
- 所有登记工具归位到同一个 content frame
- 切换时最小化其他登记窗口
- `Cmd + Option + 1...9` 全局快捷键
- JSON 配置约 1 秒自动热重载
- 桌面 App 默认读取官方 App 图标
- Web 可使用 SF Symbol 或自定义图标路径
- 工具图标状态点（Unknown / Idle / Working / Needs Input / Needs Approval / Completed / Error）
- 顶部极简 Needs You 面板：仅 Needs Input / Needs Approval，Open 只切回对应窗口
- 状态只读本地 hooks / log / SQLite / session；无可靠源显示 Unknown，不用 Accessibility 猜任务语义

## 配置文件

第一次运行后会自动创建：

`~/Library/Application Support/ToolSwitchRail/config.json`

侧轨底部 `+` 或齿轮可以打开它。

新增工具主要只需在 `tools` 数组里加一项。

### 桌面 App

```json
{
  "id": "codex",
  "name": "Codex",
  "kind": "app",
  "appName": "Codex",
  "bundleIdentifier": null,
  "url": null,
  "titleContains": [],
  "symbolName": "shippingbox",
  "iconPath": null,
  "enabled": true
}
```

### Web App

```json
{
  "id": "chatgpt-web",
  "name": "ChatGPT",
  "kind": "web",
  "appName": null,
  "bundleIdentifier": null,
  "url": "https://chatgpt.com",
  "titleContains": ["ChatGPT"],
  "symbolName": "message",
  "iconPath": null,
  "enabled": true
}
```

多个网页即使都由 Chrome 承载，也只控制标题匹配的窗口。

## 默认工具

- Codex
- Hermes
- Antigravity
- WorkBuddy
- Grok Bot
- ChatGPT Web
- Gemini Web
- Grok Web

App 实际名称如果与默认值不同，只改 `appName`；如果知道真实 Bundle ID，填入 `bundleIdentifier` 会更稳定。

## 明确不做

- iframe / WebView 嵌套官方网站
- 修改官方 App 安装包、asar、插件或 DOM
- 消息合并
- 账号打通
- 跨工具上下文
- hide 整个 Chrome

## 当前边界

侧轨与官方 App 仍然是两个真正的 macOS 窗口，只是窗口位置和尺寸被拼接成“一个窗口”的视觉效果。这是保持官方程序完全独立、仍可正常更新的前提。

某些 Electron App 如果不接受 macOS Accessibility API 的 resize/minimize，需要针对实际窗口形态做兼容，不需要推翻架构。
