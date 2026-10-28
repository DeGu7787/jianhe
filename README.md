# 笺盒 JianHe

> 你的 AI 铅笔盒：收纳、拼装并随时调用你的 Prompt、Skills 与常用文本。

笺盒是一个**本地优先**的 Windows 桌面工具。它常驻为一个置顶悬浮球，
10 秒内完成“找到 Prompt → 加入原文 → 预览 → 复制”；同时提供 `jianhe`
命令行，让 Claude Code、Codex 等本地 Agent 直接搜索、读取和导入你的
Prompt 与 Skills。

[English](#english) · 官网与下载：<https://jianhe.neodaas.com>

## 功能

- **悬浮球入口**：启动后只有一个可拖动、自动吸边的置顶悬浮球，功能沿球展开；
  支持全局快捷键（默认 `Ctrl + Shift + Space`）。
- **快速拼装**：选择 Prompt、粘贴原文，实时预览最终内容并一键复制；
  Prompt 中的 `{{input}}` 会被替换为原文。
- **统一素材库**：Prompt、Skills（含完整 Skill 包）与常用文本，支持分类、
  0–5 星评级、搜索和自定义排序。
- **AI 命令行**：`jianhe` CLI 为本地 Agent 提供稳定、机器可读的接口，
  可导入 Skill 文件夹 / ZIP、索引 Claude Code 与 Codex 的 Skills，
  并导出为 Markdown、目录或 ZIP。默认关闭，需在应用内授权开启。
- **数据属于你**：全部数据保存在本机 SQLite；`.jianhe` 离线搬家包
  无需账号即可完整迁移到另一台电脑。
- **中英双语界面**。

## 下载

从 [官网](https://jianhe.neodaas.com) 或本仓库的 Releases 下载 Windows 安装包。
安装器可选择把 `jianhe` CLI 加入用户 `PATH`，无需管理员权限。

## 从源码构建

需要 Windows 10/11、Flutter 3.44.x stable，以及 Visual Studio 的
“使用 C++ 的桌面开发”工作负载。

```powershell
flutter pub get
flutter run -d windows -t apps\desktop\lib\main.dart
```

构建包含桌面程序与 `jianhe.exe` CLI 的 Release：

```powershell
.\apps\desktop\scripts\build_windows_release.ps1
```

测试命令与贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 项目结构

```text
apps/
├── desktop/          # Flutter Windows 客户端
└── cli/              # jianhe 命令行
packages/
├── jianhe_core/      # 领域模型、查询接口与拼装规则（纯 Dart）
├── jianhe_storage/   # SQLite 本地存储
└── jianhe_skill_io/  # 完整 Skill 包的导入、校验与导出
docs/
└── cloud-sync-protocol-v1.md   # 云同步协议说明
```

## 云同步（官方付费服务）

本地功能完全免费，无需登录。开通 VIP 后，Prompt、Skills、常用文本与分类
可通过官方云服务在多台设备间自动同步；这是项目持续开发的主要收入来源。

- 同步服务端**不在本仓库中**；客户端中的账号与同步代码是官方 API 的客户端。
- 隐私说明：当前版本的同步数据经 TLS 加密传输，在服务端以**明文**保存，
  由账号鉴权保护。如果你不希望内容离开本机，不开通同步即可，
  也可以使用 `.jianhe` 离线搬家包手动迁移。
- 构建时可用 `--dart-define=JIANHE_API_BASE_URL=<HTTPS 根地址>`
  指向其他兼容服务。

## 参与贡献

欢迎 Issue 与 Pull Request，请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

本仓库的代码以 [Apache License 2.0](LICENSE) 授权，
Copyright 2026 芜湖鸠江区德谷科技坊（个体工商户）。

“笺盒”“JianHe”名称与 Logo 不在开源授权范围内，fork 后对外发布请更换名称与图标，
详见 [TRADEMARK.md](TRADEMARK.md)。

---

## English

**JianHe (笺盒)** is a local-first Windows desktop tool for managing and
assembling your AI prompts, Skills and text snippets. It lives as an
always-on-top floating ball: pick a prompt, paste your text, preview and copy
in seconds. The `jianhe` CLI gives local agents such as Claude Code and Codex
a stable, machine-readable interface to search, read and import your prompts
and Skills.

- All data stays on your machine (SQLite). A `.jianhe` archive moves
  everything to another PC without an account.
- Optional paid cloud sync across devices is provided by the official
  service; the sync server is not part of this repository.
- Build from source with Flutter 3.44.x on Windows:
  `flutter pub get`, then
  `flutter run -d windows -t apps\desktop\lib\main.dart`.

Code is licensed under the [Apache License 2.0](LICENSE). The "笺盒" / "JianHe"
names and logo are not covered by that license; see [TRADEMARK.md](TRADEMARK.md).
