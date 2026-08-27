# Easy Sticky

Easy Sticky 是一款原生 macOS 轻便签：打开即写，便签可置顶并固定到所有桌面空间，支持标准复制粘贴、自动保存和多显示器位置恢复。

产品定义和完整验收口径见 [产品方案](docs/product-plan.md)。

## 已实现能力

- 多便签窗口，新建、关闭、删除、隐藏全部和恢复全部。
- 默认置顶并加入所有 macOS Spaces，可按便签切换为普通窗口或仅当前桌面。
- `⌘C`、`⌘V`、`⌘X`、`⌘A`、`⌘Z` 等系统标准文本编辑能力。
- 输入、窗口位置、尺寸、主题、置顶和桌面模式自动保存。
- 主数据损坏时从本地备份恢复；断网可完整使用，不上传便签正文。
- 外接显示器或分辨率变化后，自动将离屏便签移回可见区域。
- 菜单栏入口和四种低干扰主题。
- 全局快捷键：`⌥⌘N` 新建便签，`⌥⌘S` 显示/隐藏全部便签。

## 环境要求

- macOS 13 或更高版本。
- Swift 5.10 或兼容工具链；仅安装 Xcode Command Line Tools 即可构建。

## 开发与测试

```bash
make build
make test
make smoke
```

`make test` 使用自包含的核心测试程序，不依赖完整 Xcode 或 XCTest，覆盖数据读写与备份恢复、默认产品行为以及多显示器窗口位置校正。

`make smoke` 会先生成 `.app` 并校验签名、Info.plist、Mach-O 可执行文件和权限。如果当前终端属于 macOS GUI 会话，还会通过 LaunchServices 启动应用，使用 `.build/smoke-data` 作为临时数据目录，并在约 0.8 秒后自动退出；在无 GUI 的 SSH/自动化环境中会明确跳过界面启动。

## 生成可双击启动的应用

```bash
make app
open ".build/Easy Sticky.app"
```

打包脚本会执行 release 构建、生成 `.app` 目录并进行本机 ad-hoc 签名。将 `.build/Easy Sticky.app` 拖入 `/Applications` 后即可从 Finder、Dock 或 Launchpad 启动。

## 本地数据

正式运行时数据保存在：

```text
~/Library/Application Support/EasySticky/notes.json
~/Library/Application Support/EasySticky/notes.backup.json
```

应用不需要账号和网络权限，不会主动读取剪贴板历史；只有用户执行复制或粘贴时才通过 macOS 标准编辑能力访问当前剪贴板。
