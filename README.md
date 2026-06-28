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

```bash
git clone https://github.com/liuqq666/codex-status-light.git
cd codex-status-light
./scripts/install.command
```

如果命令找不到，把这一行加入 `~/.zshrc`：

```bash
export PATH="$HOME/.codex/bin:$PATH"
```

## 打开

安装后会自动启动悬浮灯。也可以手动运行：

```bash
open "$HOME/Library/Application Support/CodexStatusLight/CodexStatusLight"
```

## 命令行控制

```bash
codex-light working
codex-light done
codex-light waiting
codex-light idle
codex-light status
codex-light quit
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

把 `examples/codex-hooks.example.toml` 的内容加入 `~/.codex/config.toml`。
然后在 Codex 里运行 `/hooks`，按提示信任这些 hooks。

规则：

- `UserPromptSubmit` / `PreToolUse`：黄灯。
- `PermissionRequest`：红灯。
- `Stop` / `SubagentStop`：绿灯；如果最后回复像是在等待用户，则保持红灯。

## 卸载

```bash
./scripts/uninstall.command
```

## 第一版范围

- 原生 macOS 悬浮窗。
- 可拖动，位置会保存。
- 始终置顶，可跨 Space 显示。
- 双击循环切换状态。
- 右键菜单切换状态。
- 命令行和 Codex hooks 控制状态。
- 静音按钮，设置会保存。
