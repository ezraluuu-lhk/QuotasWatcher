# QuotasWatcher

[English](README.md)

一个很小的 macOS 工具，用来在 Touch Bar 或菜单栏查看 Codex 额度。

如果你还在用带 Touch Bar 的 MacBook，QuotasWatcher 会把 Codex 剩余额度显示在那里。没有 Touch Bar 的 Mac 上，它会退回到菜单栏。

打开它，看着下一个 5 小时额度窗口，然后有效率地焦虑。

Claude Code 支持：没有。我不喜欢 Anthropic；如果你需要那个版本，可以自己 vibe 一个。

## 截图

![QuotasWatcher 菜单栏弹窗](docs/assets/menu-zh-Hans.png)

![QuotasWatcher Touch Bar 额度显示](docs/assets/touchbar-zh-Hans.png)

## 构建

```bash
swift test
Scripts/check-localizations.sh
swift build -c release
Scripts/package-app.sh
```

打包后的 app 会生成在：

```text
dist/QuotasWatcher.app
```

从 Finder 打开整个 `.app`，或者运行：

```bash
open dist/QuotasWatcher.app
```

不要直接打开 `dist/QuotasWatcher.app/Contents/MacOS/QuotasWatcher`。那是 app 内部的 Unix 可执行文件；Finder 会打开 Terminal，并显示类似 `.../Contents/MacOS/QuotasWatcher ; exit;` 的内容。

## 需求

- macOS 13 或更高版本。
- 已安装并登录 Codex CLI/app-server。
- QuotasWatcher 会这样启动 Codex：

```bash
codex app-server --listen stdio://
```

二进制查找顺序：

1. `/Applications/Codex.app/Contents/Resources/codex`
2. `/usr/local/bin/codex`
3. `/opt/homebrew/bin/codex`
4. `PATH` 里的 `codex`

## 行为

菜单栏项目会显示 5 小时额度剩余百分比。弹窗里有两行分段电量条：

- `5小时`
- `周限额`

每行显示剩余百分比和重置时间。剩余额度按 `100 - usedPercent` 计算。刷新时会保留旧数据，直到新数据成功返回后再替换。应用每 5 分钟自动刷新一次，也提供手动刷新和退出操作。

启动后，在 macOS 菜单栏靠近时钟的位置找 `Codex --%` 或 `Codex NN%`。点击它可以打开额度弹窗；右键可以刷新或退出。

Touch Bar 内容是上下文相关的：先点击 QuotasWatcher 菜单栏项目，让弹窗成为当前活动 app。macOS 为当前 app 显示物理 Touch Bar 时，Touch Bar 会同步显示两行额度。

弹窗和右键菜单里有 `复制错误` 和 `复制日志`，方便排查问题。日志写入：

```text
~/Library/Application Support/QuotasWatcher/QuotasWatcher.log
```

## 本地化

QuotasWatcher 使用 macOS 原生 `.lproj` 本地化文件：

```text
Sources/QuotasWatcher/Resources/en.lproj/Localizable.strings
Sources/QuotasWatcher/Resources/zh-Hans.lproj/Localizable.strings
```

提交 PR 前运行：

```bash
Scripts/check-localizations.sh
```

打包脚本会把这些 `.lproj` 目录复制到 `dist/QuotasWatcher.app/Contents/Resources`。

## 许可证

MIT。见 [LICENSE](LICENSE)。

## 故障排查

- `Codex binary was not found.`：安装 Codex，或者确认 `codex` 在上面的查找路径中。
- `Not initialized`：app-server 要求先发送 JSON-RPC `initialize`，再调用 `account/rateLimits/read`；QuotasWatcher 会自动发送。如果出现这个错误，更新 Codex 并重启 app。
- `failed to fetch codex rate limits`：Codex app-server 无法访问 ChatGPT 后端，或当前未登录。检查网络，并先交互式运行一次 Codex 确认登录状态。
- Touch Bar 没有内容：先点击 QuotasWatcher 菜单栏项目，让弹窗处于活动状态。Touch Bar 也依赖硬件和 macOS 的 Touch Bar 可用性；没有物理 Touch Bar 的 Mac 不会显示。
