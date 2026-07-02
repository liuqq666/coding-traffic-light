# codex-status-light

一个 macOS 桌面悬浮状态灯，用来显示 Codex 当前工作状态。

## 状态

- 黄灯：Codex 正在干活。
- 绿灯：任务完成，可以验收；默认 10 分钟后自动变暗。
- 红灯：正在等你回复、确认、授权或补文件；默认闪烁，未处理一段时间后自动加快。
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

### 一键安装配置

把下面这一行复制给 Codex 执行，它会自动下载安装到 `~/.codex/codex-status-light`，并完成编译、开机自启、命令安装和 Codex hooks 配置：

```bash
/bin/zsh -lc 'set -e; d="$HOME/.codex/codex-status-light"; if [ -d "$d/.git" ]; then git -C "$d" pull --ff-only; else mkdir -p "$(dirname "$d")"; git clone https://github.com/liuqq666/coding-traffic-light.git "$d"; fi; cd "$d"; ./install.command'
```

首次使用 hooks 时，Codex 会要求你信任一次。出现提示时，在 Codex 里运行：

```text
/hooks
```

按提示确认即可。这个信任步骤是 Codex 对非托管 command hooks 的安全确认，普通安装脚本不会替你绕过；hooks 新增或变化后也需要重新确认。

### 手动安装

下载后双击根目录里的：

```text
install.command
```

它会自动完成：

- 编译并安装悬浮灯。
- 设置开机自动启动。
- 安装 `codex-light` / `codex-light-run` / `codex-light-hook` 命令。
- 把 Codex hooks 写入 `~/.codex/config.toml`。
- Codex hook 收到事件时会自动拉起状态灯；如果状态灯没在运行，打开 Codex 后第一次会话活动会把它启动。

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
codex-light settings
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
- hooks 会记录会话 id、工作目录、事件来源、工具名和一段摘要，用于右键会话菜单。
- hooks 会在更新状态前自动确认状态灯进程已启动。
- 如果 transcript 里已有 `token_count`，会记录 5 小时额度余量和重刷时间。

多会话按独立会话管理：

- 每个 Codex 会话按 `session_id` 单独记录 `state`、`updated_at`、`acknowledged_at` 和摘要信息。
- 只管理非归档、未过期、可打开的会话；已归档会话会被过滤，避免点击后 Codex 卡在 loading。
- 未查看的 waiting 会话点亮红灯。
- 未查看的 working 会话点亮黄灯。
- 未查看的 done 会话点亮绿灯。
- 多个状态同时存在时，对应的多个灯会同时亮。
- 打开某条会话后会写入 `acknowledged_at`，这条会话不再点亮对应灯；后续该会话有新事件时会重新点亮。
- 如果所有会话都已查看或已过期，状态灯变暗。

## 交互

- 单击某个灯面：打开该颜色对应状态的最新未查看 Codex 会话。
- 右键某个灯面：列出该状态下所有非归档活跃会话，可以选择打开或全部标记已查看。
- 点击打开会话后，会把这条会话标记为已查看，该条闪烁会停止；后续有新事件时会重新提醒。
- 右键灯外：打开全局菜单，可以切换状态、调整大小、设置闪烁、打开设置窗口、静音或退出。
- 右侧额度竖条：靠近灯壳显示剩余百分比；hover tooltip 会显示 5 小时窗口和本地重刷时间，可在全局菜单或设置窗口关闭，默认开启。
- 左下角拖拽：按比例缩放浮窗。

## 设置

右键菜单里打开「设置...」可以调整：

- 浮窗大小。
- 点击会话后是否停止闪烁。
- 红灯未处理后是否自动加快。
- 是否显示额度条。
- 红灯加快阈值。
- 绿灯自动变暗时间。
- 会话过期时间。
- 静音、找回浮窗、清空会话。

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
- 右键菜单切换状态、打开会话列表和设置。
- 命令行和 Codex hooks 控制状态。
- 静音按钮，设置会保存。
