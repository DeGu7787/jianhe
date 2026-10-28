# jianhe CLI

笺盒为 Codex、Claude Code 等本地 Agent 和终端脚本提供稳定接口。CLI 与桌面端
共用数据路径、SQLite Repository 和拼装引擎，不直接暴露数据库结构。笺盒中的
“AI 命令行接口”是一个统一开关：开启后同时允许读取内容和导入 Skill，不再拆分
读、写权限。

```text
jianhe status [--json]
jianhe item list [--type prompt|skill|snippet] [--json]
jianhe item search <query> [--type ...] [--json]
jianhe item get <id> [--raw|--json]
jianhe compose --prompt <id> [--input <text>|--input-file <path>] [--json]
jianhe skill import <path> [--title <title>] [--category <name>] [--dry-run] [--json]
jianhe skill inspect <id> [--json]
jianhe skill files <id> [--json]
jianhe skill read <id> <relative-path> [--raw|--output <path> [--force]]
jianhe skill context <id> [--json]
jianhe skill scan [--provider all|codex|claude] [--scope all|user|project] [--root <path>...] [--json]
jianhe skill index [--provider ...] [--scope ...] [--root <path>...] [--title <title>] [--category <name>] [--dry-run|--import] [--json]
jianhe skill export <id> --output <path> [--format markdown|directory|zip] [--force] [--json]
```

使用 `jianhe --help` 查看顶层命令，使用 `jianhe item --help`、
`jianhe compose --help` 或 `jianhe skill --help` 查看分类帮助；也可以在笺盒
Windows 客户端的“更多 → AI 与 Skill 接入说明”中可以离线查看和导出纯接口参考，也可一键复制包含本次执行授权的 AI 用户请求模板。

## 交给 Codex / Claude Code 的四种任务

把本说明文档作为参考附件，再用自然语言明确本次任务。Agent 应按下面的最短命令链执行。

### 1. 查看笺盒中的 Skill

```powershell
jianhe item search "<任务关键词>" --type skill --json
jianhe skill context "<skill-id>" --json
```

`context` 一次返回完整 `SKILL.md`、包元数据和全部文件清单。若入口说明引用了辅助
文件，再按需执行：

```powershell
jianhe skill read "<skill-id>" "references/guide.md" --raw
```

### 2. 调用一个 Skill

“调用”由 Agent 完成，而不是由笺盒自动执行脚本。Agent 先用 `context` 读取入口
说明，按入口中的引用读取必要辅助文件，再在当前任务权限范围内遵循说明完成工作。
Skill 中出现脚本、联网或提权步骤，不会自动获得执行授权。

### 3. 创建新 Skill 并放进笺盒

Agent 在当前可写工作区创建包含 `SKILL.md` 的目录，可附带 `scripts/`、
`references/`、`assets/` 等文件；然后先校验，成功后正式导入：

```powershell
jianhe skill import ".\my-skill" --dry-run --json
jianhe skill import ".\my-skill" --json
```

`skill import` 的 JSON 结果包含 `cloud_syncable`。云同步单个 Skill 包上限为
64 MiB（文件以 base64 编码上传，约为原始大小的 4/3），超过时为 `false` 并附带
`warning`：该 Skill 仍会导入，但只保存在本机，不会同步到其他设备。文本模式下同一
提示写到 stderr。

最小入口文件：

```markdown
---
name: example-skill
description: 说明该 Skill 适用于什么任务，以及应在何时使用
---

# 使用说明

写明 Agent 要遵循的处理流程。
```

### 4. 汇总当前 Agent 环境中的 Skill 并放进笺盒

先扫描并检查候选结果，再生成索引，最后保存：

```powershell
jianhe skill scan --json
jianhe skill index --dry-run --json
jianhe skill index --import --json
```

`scan` 默认检查以下来源：

- Codex：用户级 `~/.agents/skills`、从当前目录到仓库根的 `.agents/skills`，以及兼容目录 `$CODEX_HOME/skills` 或 `~/.codex/skills`；兼容目录中的 `.system` 不会默认纳入。
- Claude Code：`$CLAUDE_CONFIG_DIR/skills` 或 `~/.claude/skills`，以及从当前目录到仓库根的 `.claude/skills`。
- 运行时插件、额外工作目录或其他已知 Skill，可重复传入 `--root "<Skill 或容器路径>"`。CLI 不会盲扫插件缓存或整个磁盘。

扫描会读取本地 Skill 包以校验格式、文件限制和哈希，但不会执行其中的命令或脚本。
`index` 只把名称、description、来源和兼容状态写成元数据索引，不复制或执行原 Skill。
`--import` 使用固定索引 ID：首次创建，内容未变化时返回 `unchanged`，环境变化时更新
同一条 Skill，不会反复新增索引。更新时只重新生成正文；标题和分类仅在显式传入
`--title`/`--category` 时修改，否则保留用户在笺盒中的设置。索引正文由 CLI 生成，
手工修改会在下次更新时被覆盖。

## 分类（--category）使用约定

`--category` 决定 Skill 在笺盒中的归类，分类名按精确字符串匹配（区分大小写）。
为避免产生重复分类，Agent 在导入前应：

1. 先执行 `jianhe item list --json`，从返回结果的 `category` 字段了解已有分类，
   优先复用语义相同或相近的已有分类，不要自创新分类。
2. 确需新建分类时，与已有分类保持一致的语言和风格（如统一使用中文短名），长度
   不超过 40 个字符，首尾空格会被自动去除。
3. 大小写不同会被视为不同分类（`Codex` 和 `codex` 是两个分类）；写入时必须与
   已有分类的写法完全一致，不要混用全角、半角标点或多余空格。

## 权限与安全边界

笺盒只存储和读取用户自己的素材，不审核其内容。Skill 中的脚本、联网或提权步骤
不会因为存放在笺盒中而获得执行授权；Agent 执行前应自行判断并征得用户同意。

`skill read --output` 与 `skill export` 采用相同的写文件规则：默认不覆盖已有文件
（需显式传 `--force`），不写入目录或符号链接。

内容命令默认不可用。用户必须先在 Windows 桌面端“更多 → AI 命令行接口”中开启
统一命令行权限，该开关同时允许只读内容操作和 Skill 导入。`skill scan`、
`skill import --dry-run` 和 `skill index --dry-run` 不访问或修改笺盒数据库；
`skill index --import` 与正式 `skill import` 都通过同一个开关授权。

完整 Skill 包要求根目录包含 UTF-8 编码的 `SKILL.md`。正式导入会先以只读方式检查
命令行权限；权限未开启时直接拒绝，不会修改数据库。授权通过后，才会以事务方式把旧版
笺盒数据库升级到当前 schema 并写入。

旧版本中只开启了“只读”命令行权限的安装，升级后不会被自动提升为读写；需要在桌面端
重新开启统一开关。若旧版本同时开启了 Skill 导入，则保持开启。
环境索引中的名称和 description 只是路由元数据，Agent 使用前仍应读取真实来源的
`SKILL.md`，不能把索引文本本身当作额外执行权限。

退出码：

| 退出码 | 含义 |
|---:|---|
| `0` | 成功 |
| `2` | 参数或命令错误 |
| `3` | 素材或 Skill 不存在 |
| `4` | CLI 访问未启用或导入权限不足 |
| `5` | 本地存储或文件读写失败 |
| `6` | Skill 包格式、完整性或安全校验失败，或未获准覆盖输出 |

开发环境中执行：

```powershell
dart run bin\jianhe.dart --help
```
