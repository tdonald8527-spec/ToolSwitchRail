# Tool Switch Rail for macOS

A lightweight native macOS switching rail for people who work across multiple desktop AI agents.

Tool Switch Rail keeps each desktop agent in its own official native or web-app environment while providing one narrow side rail for fast switching, window positioning, status awareness, and workspace control. It is built with SwiftUI + AppKit and intentionally avoids iframe/WebView embedding, client injection, DOM modification, or patching third-party applications.

> Project status: early-stage open source. The project is actively developed and currently maintained by the repository owner.

## Why this project exists

AI power users increasingly work across several independent desktop agents at the same time. The result is constant window switching, overlapping layouts, duplicated navigation, and poor visibility into which agent needs attention.

Tool Switch Rail provides a thin desktop switching and coordination layer instead of creating yet another AI client:

- keeps third-party tools independent and updatable;
- provides a compact 56 pt switching rail;
- repositions registered windows into a consistent workspace;
- minimizes other registered windows when switching;
- exposes lightweight local status indicators where a reliable local signal is available;
- lets users add, remove, and reorder applications without rebuilding the app.

## Core principles

- **Native, lightweight macOS utility** — SwiftUI + AppKit, no Electron runtime.
- **Non-invasive** — no code injection, no modified app bundles, no patched `asar`, no DOM manipulation, no iframe embedding.
- **Local-first** — configuration and status probes are local. The project does not upload third-party application data.
- **Read-only agent probes** — supported probes inspect local process, heartbeat, log, SQLite, or persistence signals without modifying third-party business data.
- **Thin coordination layer** — Tool Switch Rail is not an agent orchestrator and does not attempt to replace the desktop agents it works alongside.

## Current capabilities

### Native workspace rail

- Approx. 56 pt floating side rail that stays visible while you use other apps.
- Switching shows exactly one tool: the selected app is placed in the workspace and the other registered apps are hidden (`workspace.minimizeOtherRegisteredWindows`, on by default).
- The rail is positioned from the window's **actual** frame after placement, so it never covers an app that refused a size or position.
- Moving/resizing the active window keeps the rail aligned; only your own drags/resizes change where the next tool is placed.
- One clearly labelled **Collapse workspace** button (`Cmd + Option + M`); full-screen / restore and window sizes live in the settings menu.
- Per-tool light/dark background matching; the rail follows the macOS appearance automatically.

### App management

- Add any macOS `.app` through the native file picker.
- Remove an app from its right-click menu or the settings menu. Removal is immediate and can be undone from the "Removed · Undo" toast for 5 seconds — no confirmation dialogs.
- Drag to reorder apps and persist the order.
- One settings menu, identical from the rail gear, the dashboard gear and a right-click on the menu-bar icon.
- Keyboard switching with `Cmd + Option + 1...9`.
- Show/minimize Tool Switch Rail with `Cmd + Option + M`.

### Status dashboard

The menu-bar popover shows every registered app with one of four states — **Not started / Launching / Current / Running** — the same words used in the rail tooltips. Click a card to switch, right-click to remove. Missing Accessibility permission is shown as a hint with a direct link to System Settings, only when it is actually missing.

Status detection is deliberately conservative: it is best-effort telemetry, not an official API or guarantee of third-party application state. Probe behavior can change when third-party applications change their local persistence formats.

### Feedback and motion

- Errors (window not found, app could not be opened, permission missing) appear as a small non-blocking toast next to the rail with a **Retry** / **Open Settings** action, then fade away. Nothing blocks what you are doing.
- One motion vocabulary for the whole app (`UI/Experience.swift` → `Motion`): `quick` for press/hover, `standard` for selection, reordering, insert/remove and toasts, `fade` for colour and opacity. Dragging and resizing follow the pointer directly.
- Respects **Reduce motion**: movement becomes short cross-fades and nothing loops.

### Design principles

Complexity belongs to the system, not the user: decide what the system can decide, hide what is not useful right now, do what can be done for the user, keep the same thing the same everywhere, give every press a response that can be taken back, never interrupt, make frequent actions easy and destructive ones hard to hit by accident, and let the interface explain itself.

## Requirements

Currently tested with:

- macOS Sonoma / Sequoia
- Apple Silicon (`arm64`)
- Apple Command Line Tools
- Swift 6.4

The project can be built without installing the full Xcode application when the required Apple Command Line Tools and Swift toolchain are available.

## Build and run

```bash
chmod +x build.command run.command
./build.command
```

The build script generates:

```text
Dist/Tool Switch Rail.app
```

On first launch, macOS may require Accessibility permission so the app can coordinate third-party application windows:

`System Settings → Privacy & Security → Accessibility → Tool Switch Rail`

To build, install into `/Applications` and relaunch in one step (log in `build-and-install.log`):

```bash
./build-and-install.command
```

For incremental build + launch from `Dist/`:

```bash
./run.command
```

> Building with only the Command Line Tools: the SwiftUI macro plugin is not included, so `@State` fails to compile ("StateMacro could not be found"). Use `@StateObject` with a small `ObservableObject` instead.

## Configuration

Runtime configuration is stored at:

```text
~/Library/Application Support/ToolSwitchRail/config.json
```

A sample configuration is available in [`config.example.json`](config.example.json).

Example:

```json
{
  "tools": [
    {
      "appName": "Example Agent",
      "backgroundColor": "#181818",
      "bundleIdentifier": "com.example.agent",
      "enabled": true,
      "hotkeyIndex": 1,
      "id": "example-agent",
      "kind": "app",
      "name": "Example Agent",
      "symbolName": "circle"
    }
  ],
  "workspace": {
    "appearance": "system",
    "heightFraction": 0.82,
    "minimizeOtherRegisteredWindows": true,
    "minimumHeight": 680,
    "minimumWidth": 960,
    "railWidth": 56,
    "widthFraction": 0.84
  }
}
```

The configuration file supports hot reload while Tool Switch Rail is running.

## Privacy and third-party applications

Tool Switch Rail is not affiliated with or endorsed by the developers of the third-party applications it can launch or observe.

The rail does not require users to provide third-party API keys for ordinary window switching. Optional status integrations rely on locally available runtime signals and are read-only by design. Users should review the source and local permissions before enabling integrations that inspect application state.

## Contributing

Bug reports, compatibility findings, probe improvements, documentation fixes, and focused pull requests are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

Because several integrations depend on undocumented local runtime formats, please include the application version and macOS version when reporting a status-detection problem. Do not attach private chat content, credentials, tokens, or complete personal log files.

## Security

Please see [`SECURITY.md`](SECURITY.md) before reporting a security issue. Do not publish credentials, private logs, or exploit details in a public issue.

## License

Tool Switch Rail is released under the [MIT License](LICENSE).

---

## 中文简介

Tool Switch Rail 是一个原生 macOS 多桌面 Agent 切换栏。它的核心用途是在多个独立桌面 Agent 之间快速切换，并把它们的窗口统一到同一个工作区域，而不是重新做一套 AI 客户端或 Agent 平台。

核心边界：

- 不嵌入第三方网页或客户端；
- 不修改第三方应用包、DOM 或内部代码；
- 不接管 Agent 自己的任务拆解和调度；
- 状态探测只读取本地可用信号，并按 best-effort 方式工作；
- 保留各工具自己的账号、更新机制、权限和官方界面。

快速开始：

```bash
chmod +x build.command run.command
./build.command
```

编译后会在 `Dist/` 生成 `Tool Switch Rail.app`。首次运行如需窗口协同，请在 macOS“隐私与安全性 → 辅助功能”中授权。