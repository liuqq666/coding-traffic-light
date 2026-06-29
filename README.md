# codex-status-light

一个 macOS 桌面悬浮状态灯，用来显示 Codex 当前工作状态。

## 状态

- 黄灯：Codex 正在干活。
- 绿灯：任务完成，可以验收；默认 10 分钟后自动变暗。
- 红灯：正在等你回复、确认、授权或补文件；先闪烁 10 秒。
- 全暗：空闲。

状态文件：

```text
~/Library/Application Support/CodexStatusLight/state.json
```

偏好设置：

```text
~/Library/Application Support/CodexStatusLight/preferences.json
```

## 安装

下载后双击根目录里的：

```text
install.command
```

它会自动完成：

- 编译并安装悬浮灯。
- 设置开机自动启动。
- 安装 `codex-light` / `codex-light-run` / `codex-light-hook` 命令。
- 把 Codex hooks 写入 `~/.codex/config.toml`。

最后打开 Codex，运行一次：

```text
/hooks
```

按提示信任这些 hooks。之后用 Codex 时状态灯就会自动变化。

也可以用命令行安装：

```bash
git clone https://github.com/liuqq666/coding-traffic-light.git
cd coding-traffic-light
./install.command
```

如果命令找不到，把这一行加入 `~/.zshrc`：

```bash
export PATH="$HOME/.codex/bin:$PATH"
```

## 打开

安装后会自动启动悬浮灯。也可以手动运行：

```bash
launchctl kickstart -k "gui/$(id -u)/com.liuqq666.codex-status-light"
codex-light show
```

## 命令行控制

```bash
codex-light working
codex-light done
codex-light waiting
codex-light idle
codex-light status
codex-light quit
codex-light show
codex-light reset-position
codex-light clear-sessions
```

如果悬浮灯没有出现在屏幕上，先试：

```bash
codex-light reset-position
codex-light show
```

也可以包一层运行命令：

```bash
codex-light-run npm run build
codex-light-run python3 script.py
```

规则：

- 命令开始：黄灯。
- 命令成功：绿灯。
- 命令失败：红灯。

## 接入 Codex hooks

安装脚本会自动把 `examples/codex-hooks.example.toml` 写入 `~/.codex/config.toml`。
你只需要在 Codex 里运行一次 `/hooks`，按提示信任这些 hooks。

规则：

- `UserPromptSubmit` / `PreToolUse`：黄灯。
- `PermissionRequest`：红灯。
- `Stop` / `SubagentStop`：绿灯；如果最后回复像是在等待用户，则保持红灯。

多会话时会按会话聚合：

- 任意会话在等你：红灯。
- 否则任意会话在工作：黄灯。
- 否则最近完成：绿灯。
- 都没有活动：空闲。

## 卸载

```bash
./scripts/uninstall.command
```

## 第一版范围

- 原生 macOS 悬浮窗。
- 可拖动，位置会保存。
- 单击或右键菜单可放大、缩小、重置大小，大小会保存。
- 始终置顶，可跨 Space 显示。
- 双击循环切换状态。
- 右键菜单切换状态。
- 命令行和 Codex hooks 控制状态。
- 静音按钮，设置会保存。
