# Tool Switch Rail for macOS — Command Line Tools 版

专为 macOS 打造的高性能多桌面 Agent 侧边切换栏工作台。
不需要安装完整 Xcode，只要 Mac 已有 Apple Command Line Tools 和 Swift，即可通过 `./build.command` 生成可直接双击运行的原生 macOS `.app`。

---

## 你的当前环境

已确认支持：
- macOS Sonoma / Sequoia (Apple Silicon / arm64)
- `/Library/Developer/CommandLineTools`
- Apple Swift 6.4

---

## 快速开始

1. 进入 `ToolSwitchRail` 根目录。
2. 双击或执行 `./build.command`：
   ```bash
   chmod +x build.command run.command
   ./build.command
   ```
3. 编译完成后在 `Dist/` 自动生成：
   `Dist/Tool Switch Rail.app`
4. 首次运行后，请前往：
   `系统设置 → 隐私与安全性 → 辅助功能`
   允许 **Tool Switch Rail**。
5. 也可直接运行 `./run.command`：自动增量编译并启动。

---

## 核心功能与架构特性

### 1. 原生无缝大窗口融合
- **极轻量原生架构**：采用纯原生 **SwiftUI + AppKit** 构建，杜绝 Electron 内存与性能开销。
- **视觉无缝拼合**：Rail 宽度约 56px，采用 `.floating` 浮动窗口层级并向右延伸 1px 无缝贴合，彻底移除发丝分割线，使侧栏与官方客户端在视觉上融为一体。
- **动态色彩联动**：内置各应用（Antigravity、ChatGPT、Hermes、Grok Bot、WorkBuddy 等）专属浅色与深色背景色，随激活工具与外观模式毫秒级自适应。
- **窗口吸附与协同**：移动或调整右侧主窗口时，左轨自动吸附跟随；切换工具时新窗口自动归位至同一 content frame，并将其他登记窗口自动最小化。

### 2. 系统级外观无感秒切
- **SkyLight 底层 C API**：内置 `SLSSetAppearanceThemeLegacy` 底层调用，**无需任何 AppleScript 权限弹窗**，一键实现 macOS 全局深色/浅色模式实时切换，并即时同步更新 Rail 材质与工具配色。

### 3. 原生状态栏 Popover 运行看板
- **2 列紧凑网格（2-Column Grid）**：顶部状态栏点击即可展开原生毛玻璃 Popover 看板，卡片布局紧凑规范。
- **系统快捷控制**：集成系统深浅外观切换、侧边栏显示/最小化快捷卡片。
- **多入口应用管理**：底部直接提供 `+ 添加应用` 与显式的 `— 移除应用 ⌵` 下拉菜单。

### 4. 桌面 Agent 深度非侵入式状态监控
全生命周期监测 5 大主流桌面 Agent，严格通过只读本地心跳、日志、SQLite 与持久化文件监测状态，**不注入、不修改官方代码**：
- **Antigravity**：监控会话 steps SQLite 与 annotations `.pbtxt`，实时识别执行中/空闲与最新会话标题。
- **Hermes**：只读 `state.db` 中的 session turn lease 租约与 token 用量，实时识别 working / idle。
- **Grok Bot**：监测 `sand-session-marker.json` 存活心跳与 PID，纯 Swift Base32 解码本地持久化文件，提取当前助手（如「投资台」）并实时监控流式输出。
- **WorkBuddy**：监控 `~/.workbuddy/sessions/` 心跳、`artifact-index` 产出成果，结合工作区日志 `runId != (none)` 与确认事件实时判定。
- **ChatGPT (Mac)**：监控 `com.openai.codex` 进程与今日会话日志流式生成。
- **全局运行兜底**：任何运行中的应用均可靠显示 `.idle` 实心就绪点，杜绝死灰色未知状态。

### 5. 灵活的应用增删与重排
- **添加应用**：点击底部的 `+` 按钮，通过原生 macOS 文件选择器自由选取 `/Applications` 下的任意 `.app`。
- **多通道移除应用**：
  1. **Rail 图标右键**：直接右键任意图标弹出「从 Rail 移除」。
  2. **状态栏看板一键移除**：点击看板底部 `— 移除应用 ⌵` 下拉菜单，单机任意项即刻删除。
  3. **看板卡片右键**：右键任意 Agent 卡片弹出「从 Rail 移除」。
  4. **齿轮设置菜单**：点击 Rail 底部设置齿轮，在「从 Rail 移除应用」子菜单中直接选择删除。
- **拖拽重排**：长按并纵向拖动 Rail 图标，平滑交互式重排应用顺序并持久化。

---

## 快捷键

- `Cmd + Option + 1...9`：快速切换至对应序号的桌面工具。
- `Cmd + Option + M`：显示 / 最小化 Tool Switch Rail。

---

## 配置文件

配置文件位于：
`~/Library/Application Support/ToolSwitchRail/config.json`

支持约 1 秒文件监听热重载，在 Rail 底部齿轮菜单中可直接点击「打开配置文件」进行高级定制。

```json
{
  "browser" : {
    "appName" : "Google Chrome",
    "bundleIdentifier" : "com.google.Chrome"
  },
  "tools" : [
    {
      "appName" : "Antigravity",
      "backgroundColor" : "#181818",
      "bundleIdentifier" : "com.google.antigravity",
      "enabled" : true,
      "hotkeyIndex" : 1,
      "id" : "antigravity",
      "kind" : "app",
      "name" : "Antigravity",
      "symbolName" : "a.circle"
    }
  ],
  "workspace" : {
    "appearance" : "system",
    "heightFraction" : 0.82,
    "minimizeOtherRegisteredWindows" : true,
    "minimumHeight" : 680,
    "minimumWidth" : 960,
    "railWidth" : 56,
    "widthFraction" : 0.84
  }
}
```

---

## 明确设计原则

- **绝不篡改官方应用**：不注入官方客户端、不破解 asar、不修改 DOM、不嵌入 iframe。
- **零安全与更新冲突**：官方客户端正常自动更新升级，绝不影响 Tool Switch Rail 的吸附与调度。
- **纯本地只读探测**：数据监控仅读取官方落地的本地会话与日志，不上报、不修改业务数据。
