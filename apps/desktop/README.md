# 笺盒桌面端

Windows MVP 的 Ball-first Flutter 客户端。应用启动时只有一个 88×88 的系统级悬浮球，不打开传统主窗口。点击悬浮球后，快速拼装、Prompt、Skills、常用文本、新建和更多设置沿着悬浮球展开；具体功能以贴着球的“纸笺”面板承载。

Windows runner 负责无边框、透明色键、始终置顶、不显示任务栏、动态尺寸、原生拖动和左右边缘吸附。Flutter 负责悬浮球状态机与业务内容。

“更多 → 笺盒账号”支持注册、登录、自动恢复登录、VIP 权益刷新和退出。VIP 用户的 Prompt、Skills、常用文本、分类、星级与排序会在启动、本地修改、悬浮球唤醒以及 Windows 系统定时任务中自动同步到云端和其他已登录设备；系统任务支持每 15/30/60 分钟或每天指定时间，并在应用退出后继续工作。临时网络故障会自动退避重试。设置、快捷键、CLI 授权与使用记录仍保留在本机。官方构建默认连接 `https://jianhe.neodaas.com`；可用 `--dart-define=JIANHE_API_BASE_URL=<HTTPS 根地址>` 指向其他兼容服务。

鼠标移出悬浮球后，其透明度降至 48%；重新进入时恢复不透明。展开状态下移出窗口会启动自动收回倒计时，默认 4 秒；重新进入会取消本次倒计时。用户可在“更多 → 自动收回”中将时间设置为 0–60 秒（0 为移出即收回，内部保留约 150 毫秒去抖）。

Prompt、Skills 和常用文本均支持分类、0–5 星评级、搜索和个性化排序。星级筛选默认显示所选星级及以下的已评级素材，并按星级从高到低展示；未评级素材可单独查看。

桌面应用打开 `%APPDATA%\JianHe\jianhe.db`；首次运行会写入少量演示素材。设置 `JIANHE_DATA_DIR` 可在开发或测试时覆盖数据目录。

```powershell
# 国内网络可选：使用 Flutter 中国镜像
# $env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
# $env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
flutter run -d windows
```

当前 Windows 版默认使用 `Ctrl + Shift + Space` 全局唤起快捷菜单，可在“更多”设置中录入自定义组合键或恢复默认。Inno Setup 安装包会收集 Flutter、SQLite 和安全存储插件运行库；面向公开分发前仍需配置正式代码签名。仍待实现的原生能力包括：系统托盘、单实例生命周期和位置持久化。macOS 和移动端尚未进入当前代码库。
