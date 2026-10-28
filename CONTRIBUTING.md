# 参与贡献

感谢你愿意改进笺盒！提 Issue、修 Bug、补测试、改文档、做翻译都很欢迎。

## 开始之前

- **较大的改动请先开 Issue 讨论**，确认方向后再写代码，避免白费功夫。
- **安全漏洞不要公开提 Issue**，请按 [SECURITY.md](SECURITY.md) 私下报告。
- 云同步服务端不在本仓库中。客户端里的账号、同步与 VIP 代码是官方服务的
  API 客户端，欢迎修 Bug，但请不要提交绕过服务端权益校验的改动。

## 开发环境

- Windows 10/11 x64
- Flutter 3.44.x stable（Dart 3.12），并安装 Visual Studio 的
  “使用 C++ 的桌面开发”工作负载
- 国内网络可设置 `PUB_HOSTED_URL=https://pub.flutter-io.cn` 和
  `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`

```powershell
flutter pub get                          # 在仓库根目录执行（Dart workspace）
flutter run -d windows -t apps\desktop\lib\main.dart
```

## 测试

请在提交前跑通相关测试。各包需在自己的目录里执行，`sqlite3` 的原生资产
需要以存储包或 CLI 包为工作目录解析：

```powershell
cd packages\jianhe_core;     dart test; cd ..\..
cd packages\jianhe_skill_io; dart test; cd ..\..
cd packages\jianhe_storage;  dart test; cd ..\..
cd apps\cli;                 dart test; cd ..\..
cd apps\desktop;             flutter test; flutter analyze; cd ..\..
```

## 提交规范

- 提交信息沿用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)，
  例如 `fix(cli): ...`、`feat(desktop): ...`；
- 一个 PR 只做一件事，附上动机和测试方式；
- 界面文案需同时更新中英文（`apps/desktop/tool/l10n/`）。

## 开发者原创声明（DCO）

本项目不要求签署 CLA，而是使用
[Developer Certificate of Origin 1.1](https://developercertificate.org/)。
每个提交都需要带上签名行，表示你有权以本项目的许可证提交这段代码：

```text
Signed-off-by: 你的名字 <你的邮箱>
```

使用 `git commit -s` 即可自动添加。你的贡献将以
[Apache License 2.0](LICENSE) 授权，与项目其余部分一致。
