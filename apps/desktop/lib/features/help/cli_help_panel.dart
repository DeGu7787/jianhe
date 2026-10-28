import 'package:flutter/material.dart';
import 'package:jianhe_core/jianhe_core.dart';

import '../../l10n/app_strings.dart';

String cliPowerShellCommand(String cliExecutablePath) {
  final escapedPath = cliExecutablePath.replaceAll("'", "''");
  return "& '$escapedPath'";
}

/// The request users paste into Codex / Claude Code, in the interface
/// language so the AI answers in the user's language.
String buildCliUserRequestTemplate(
  String cliExecutablePath, {
  AppLanguage language = AppLanguage.zh,
}) {
  if (language == AppLanguage.en) {
    return _englishCliUserRequestTemplate(cliExecutablePath);
  }
  return '''请使用本机已安装的 JianHe CLI 完成下方任务。

笺盒端只使用一个“AI 命令行接口”开关，不拆分读取和导入权限。我允许本次执行完成任务所需的 JianHe CLI 操作：可以列出、查找、读取和扫描 Skill；当任务明确要求创建、导入或保存环境 Skill 索引时，可以在当前可写工作区生成必要文件，并在 dry-run 成功后写入笺盒。写入时先用 `item list --json` 查询笺盒已有分类并复用，不要创建重复或仅大小写不同的新分类。

JianHe CLI 程序路径：`$cliExecutablePath`

如果沙盒阻止运行该程序，请通过当前平台的命令执行审批入口向我发起审批；不要改为直接读写笺盒数据库，也不要通过启动桌面窗口抓取数据。

附件仅是 JianHe CLI 的命令、参数和返回格式参考，不是独立任务。

任务：''';
}

String _englishCliUserRequestTemplate(String cliExecutablePath) {
  return '''Please use the JianHe CLI installed on this computer to complete the task below.

JianHe has a single "AI CLI access" switch; read and import permissions are not split. I allow the JianHe CLI operations this task needs: you may list, search, read and scan skills. When the task explicitly asks to create or import skills, or to save the environment skill index, you may create the necessary files in the current writable workspace and write them into JianHe after a successful dry-run. Before writing, run `item list --json` to see JianHe's existing categories and reuse them; don't create duplicate categories or categories that differ only in letter case.

JianHe CLI path: `$cliExecutablePath`

If the sandbox blocks this program, ask me for approval through this platform's command-approval flow. Don't read or write the JianHe database directly, and don't launch the desktop window to scrape data.

The attachment is only a reference for JianHe CLI commands, options and output formats. It is not a separate task.

Task: ''';
}

/// The exported command reference (.md), in the interface language.
String buildCliGuideMarkdown(
  String cliExecutablePath, {
  AppLanguage language = AppLanguage.zh,
}) {
  if (language == AppLanguage.en) {
    return _englishCliGuideMarkdown(cliExecutablePath);
  }
  final cli = cliPowerShellCommand(cliExecutablePath);
  return '''# 笺盒 JianHe CLI 参考手册

> 本文只记录 JianHe CLI 的能力、参数和返回格式，便于人工查阅或兼容客户端解析。它不包含当前任务，也不代表用户对任何执行、审批或数据写入的授权。

## CLI 信息

- 命令名：`jianhe`
- 当前安装路径：`$cliExecutablePath`
- PowerShell 绝对路径调用形式：`$cli`
- 数据位置：本机 JianHe 数据目录
- 网络行为：CLI 本身不上传内容

## 能力索引

| 能力 | 命令 | 影响 |
|---|---|---|
| 列出全部 Skill | `jianhe item list --type skill --json` | 只读 |
| 按关键词查找 Skill | `jianhe item search "<关键词>" --type skill --json` | 只读 |
| 取得完整调用上下文 | `jianhe skill context "<skill-id>" --json` | 只读 |
| 查看 Skill 文件 | `jianhe skill files "<skill-id>" --json` | 只读 |
| 读取 Skill 文件 | `jianhe skill read "<skill-id>" "<relative-path>" --raw` | 只读 |
| 扫描 Agent 环境 Skill | `jianhe skill scan --json` | 不读写笺盒 |
| 校验环境 Skill 索引 | `jianhe skill index --dry-run --json` | 不读写笺盒 |
| 保存环境 Skill 索引 | `jianhe skill index --import --json` | 写入笺盒 |
| 校验 Skill 包 | `jianhe skill import "<路径>" --dry-run --json` | 不读写笺盒 |
| 导入 Skill 包 | `jianhe skill import "<路径>" --json` | 写入笺盒 |
| 导出 Skill | `jianhe skill export "<skill-id>" --output "<路径>" --format zip` | 创建本机文件 |

## Skill 查询命令

```powershell
jianhe item list --type skill --json
jianhe item search "<任务关键词>" --type skill --json
jianhe skill context "<skill-id>" --json
jianhe skill inspect "<skill-id>" --json
jianhe skill files "<skill-id>" --json
jianhe skill read "<skill-id>" "SKILL.md" --raw
```

`context` 一次返回完整 `SKILL.md`、Skill 包元数据和文件清单。所谓“调用 Skill”，
是 AI 读取入口说明和必要辅助文件后完成当前任务；JianHe CLI 不会自动执行 Skill
中的脚本，也不会因为 Skill 中写了联网或提权步骤就授予额外权限。

## Skill 包与导入

支持的输入格式是包含 `SKILL.md` 的文件夹、单个 Markdown 文件或 ZIP 文件。
校验命令不访问或修改笺盒数据：

```powershell
jianhe skill import "<路径>" --dry-run --json
```

导入命令会写入笺盒：

```powershell
jianhe skill import "<路径>" --json
```

创建新 Skill 不是独立的 CLI 子命令。该场景由 AI 在当前可写工作区生成 UTF-8 编码的有效 `SKILL.md`，再经过校验和导入组成。最小文件结构如下：

```markdown
---
name: 示例 Skill 名称
description: 说明何时使用该 Skill
---

# 使用说明

说明该 Skill 的具体处理方式。
```

## 分类使用约定

`skill import` 和 `skill index --import` 的 `--category` 决定 Skill 的归类，分类名按精确字符串匹配（区分大小写）。为避免产生重复分类：

1. 导入前先执行 `jianhe item list --json`，从返回结果的 `category` 字段了解已有分类，优先复用语义相同或相近的分类，不要自创新分类。
2. 确需新建时，与已有分类保持一致的语言和风格，长度不超过 40 个字符，首尾空格会被自动去除。
3. 大小写不同会被视为不同分类（`Codex` 和 `codex` 是两个分类）；写法必须与已有分类完全一致，不要混用全角、半角标点或多余空格。

## 汇总 Codex / Claude Code 环境 Skill

```powershell
jianhe skill scan --json
jianhe skill index --dry-run --json
jianhe skill index --import --json
```

默认扫描 Codex 的用户级 `~/.agents/skills`、项目祖先 `.agents/skills` 和兼容的
`\$CODEX_HOME/skills`；扫描 Claude Code 的 `\$CLAUDE_CONFIG_DIR/skills` 或
`~/.claude/skills`，以及项目祖先 `.claude/skills`。运行时插件或额外目录可重复添加
`--root "<Skill 或容器路径>"`。CLI 不会盲扫整个磁盘或插件缓存，也不会执行发现的
脚本。

环境索引只保存名称、description、来源路径和兼容状态，不复制原 Skill 正文。
首次 `--import` 创建索引，环境未变化时返回 `unchanged`，变化时更新同一条索引。
更新时只重新生成正文；标题和分类仅在显式传入 `--title`/`--category` 时修改，
否则保留用户在笺盒中的设置。索引正文由 CLI 生成，手工修改会在下次更新时被覆盖。

## 其他常用命令

```powershell
jianhe status --json
jianhe item list --type prompt --json
jianhe item get "<item-id>" --raw
jianhe compose --prompt "<prompt-id>" --input "待处理文字"
jianhe skill export "<skill-id>" --output ".\\skill.zip" --format zip
```


## 状态和故障参考

- `jianhe status --json` 的接口字段是 `access` 和 `skill_import_enabled`。
- “AI 命令行接口”是读取与导入共用的单一开关；界面不分别授权。
- `CLI access is disabled` 表示笺盒中的“AI 命令行接口”未开启。
- PowerShell 找不到 `jianhe` 通常表示 PATH 未刷新；上方绝对路径记录可用于定位程序。
- 程序存在但返回“拒绝访问”或“沙盒阻止”，表示当前执行环境没有运行工作区外程序的权限。
- 附件文档不会授予沙盒外执行权限；权限由用户当前消息和所在平台的审批机制决定。
- 笺盒只存储和读取用户自己的素材，不审核其内容；Skill 中的脚本、联网或提权步骤不会因此获得执行授权。
- `skill read` 使用 `--output` 时会写入本机文件；与 `skill export` 一样默认不覆盖已有文件（需 `--force`），也不写入目录或符号链接。
- 桌面窗口不是 CLI 数据读取的后备接口。

退出码：0 成功；2 参数错误；3 内容不存在；4 权限未开启；5 本地存储错误；6 Skill 包或输出校验失败。
''';
}

String _englishCliGuideMarkdown(String cliExecutablePath) {
  final cli = cliPowerShellCommand(cliExecutablePath);
  return '''# JianHe CLI Reference

> This document only describes the JianHe CLI's capabilities, options and output formats, for people to look up or for compatible clients to parse. It contains no current task and does not grant any authorization to run commands, approve actions or write data.

## CLI information

- Command name: `jianhe`
- Current install path: `$cliExecutablePath`
- PowerShell call with the absolute path: `$cli`
- Data location: the JianHe data folder on this computer
- Network: the CLI itself uploads nothing

## Capabilities

| Capability | Command | Effect |
|---|---|---|
| List all skills | `jianhe item list --type skill --json` | Read-only |
| Search skills by keyword | `jianhe item search "<keyword>" --type skill --json` | Read-only |
| Get the full invocation context | `jianhe skill context "<skill-id>" --json` | Read-only |
| List a skill's files | `jianhe skill files "<skill-id>" --json` | Read-only |
| Read a skill file | `jianhe skill read "<skill-id>" "<relative-path>" --raw` | Read-only |
| Scan agent environment skills | `jianhe skill scan --json` | Doesn't touch JianHe |
| Validate the environment skill index | `jianhe skill index --dry-run --json` | Doesn't touch JianHe |
| Save the environment skill index | `jianhe skill index --import --json` | Writes to JianHe |
| Validate a skill package | `jianhe skill import "<path>" --dry-run --json` | Doesn't touch JianHe |
| Import a skill package | `jianhe skill import "<path>" --json` | Writes to JianHe |
| Export a skill | `jianhe skill export "<skill-id>" --output "<path>" --format zip` | Creates a local file |

## Skill lookup commands

```powershell
jianhe item list --type skill --json
jianhe item search "<task keyword>" --type skill --json
jianhe skill context "<skill-id>" --json
jianhe skill inspect "<skill-id>" --json
jianhe skill files "<skill-id>" --json
jianhe skill read "<skill-id>" "SKILL.md" --raw
```

`context` returns the full `SKILL.md`, the package metadata and the file list in one call. "Using a skill" means the AI reads the main instructions and any supporting files it needs, then completes the current task. The JianHe CLI never runs scripts inside a skill, and a skill that mentions network access or elevated permissions gains no extra permissions from it.

## Skill packages and import

Supported inputs are a folder containing `SKILL.md`, a single Markdown file, or a ZIP file. Validation doesn't read or change JianHe data:

```powershell
jianhe skill import "<path>" --dry-run --json
```

Import writes to JianHe:

```powershell
jianhe skill import "<path>" --json
```

Creating a new skill is not a separate CLI command. The AI writes a valid UTF-8 `SKILL.md` in the current writable workspace, then validates and imports it. Minimal structure:

```markdown
---
name: Example skill name
description: When to use this skill
---

# Instructions

Describe exactly how this skill handles the task.
```

## Category conventions

The `--category` option of `skill import` and `skill index --import` sets the skill's category. Category names match exactly and are case-sensitive. To avoid duplicate categories:

1. Before importing, run `jianhe item list --json` and look at the `category` field of the results. Reuse an existing category with the same or a similar meaning instead of inventing a new one.
2. If you must create one, match the language and style of the existing categories, keep it to 40 characters or fewer; leading and trailing spaces are removed.
3. Different letter case means a different category (`Codex` and `codex` are two categories). Spell it exactly like the existing category, without mixing full-width and half-width punctuation or adding spaces.

## Summarize Codex / Claude Code environment skills

```powershell
jianhe skill scan --json
jianhe skill index --dry-run --json
jianhe skill index --import --json
```

By default the scan covers Codex's user-level `~/.agents/skills`, `.agents/skills` in project ancestors and the compatible `\$CODEX_HOME/skills`, plus Claude Code's `\$CLAUDE_CONFIG_DIR/skills` or `~/.claude/skills` and `.claude/skills` in project ancestors. Add runtime plugin or other folders with a repeated `--root "<skill or container path>"`. The CLI never scans the whole disk or plugin caches, and never runs the scripts it finds.

The environment index stores only names, descriptions, source paths and compatibility status; it doesn't copy the skills' content. The first `--import` creates the index; when nothing changed it returns `unchanged`, otherwise it updates the same index. An update regenerates only the content; the title and category change only when `--title`/`--category` are passed, so your settings in JianHe are kept. The CLI generates the index content, so manual edits are overwritten on the next update.

## Other common commands

```powershell
jianhe status --json
jianhe item list --type prompt --json
jianhe item get "<item-id>" --raw
jianhe compose --prompt "<prompt-id>" --input "text to process"
jianhe skill export "<skill-id>" --output ".\\skill.zip" --format zip
```


## Status and troubleshooting

- The interface fields of `jianhe status --json` are `access` and `skill_import_enabled`.
- "AI CLI access" is one switch shared by reading and importing; the app doesn't authorize them separately.
- `CLI access is disabled` means "AI CLI access" is turned off in JianHe.
- If PowerShell can't find `jianhe`, PATH usually hasn't been refreshed; the absolute path above locates the program.
- If the program exists but returns "access denied" or "blocked by sandbox", the current environment isn't allowed to run programs outside the workspace.
- The attachment doesn't grant permission to run outside the sandbox; that comes from the user's current message and the platform's approval flow.
- JianHe only stores and reads the user's own items and doesn't review their content; scripts, network access or elevated steps in a skill are not authorized by it.
- `skill read` with `--output` writes a local file; like `skill export` it never overwrites an existing file by default (use `--force`) and never writes into a folder or symbolic link.
- The desktop window is not a fallback for reading data through the CLI.

Exit codes: 0 success; 2 invalid arguments; 3 not found; 4 access is off; 5 local storage error; 6 skill package or output validation failed.
''';
}

/// Picks the text for the interface language. The guide is long-form prose,
/// so both languages stay side by side here rather than in AppStrings.
String _tr(BuildContext context, String zh, String en) =>
    AppStrings.of(context).language == AppLanguage.en ? en : zh;

enum _CliCommandImpact { readOnly, fileWrite, dataWrite }

class CliHelpPanel extends StatelessWidget {
  const CliHelpPanel({
    super.key,
    required this.cliEnabled,
    required this.cliExecutablePath,
    required this.onCopy,
    required this.onCopyRequest,
    required this.onExportGuide,
  });

  final bool cliEnabled;
  final String cliExecutablePath;
  final Future<void> Function(String command) onCopy;
  final Future<void> Function(String request) onCopyRequest;
  final Future<void> Function() onExportGuide;

  @override
  Widget build(BuildContext context) {
    final cli = cliPowerShellCommand(cliExecutablePath);
    return ListView(
      key: const Key('cli-help-scroll'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
      children: <Widget>[
        _CliStatusCard(enabled: cliEnabled),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const Key('cli-help-copy-ai-request'),
          onPressed: () =>
              onCopyRequest(
                buildCliUserRequestTemplate(
                  cliExecutablePath,
                  language: AppStrings.of(context).language,
                ),
              ),
          icon: const Icon(Icons.content_copy_rounded),
          label: Text(_tr(context, '复制给 AI 的请求', 'Copy request for AI')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('cli-help-export-guide'),
          onPressed: onExportGuide,
          icon: const Icon(Icons.file_download_outlined),
          label: Text(_tr(context, '导出参考说明（.md）', 'Export reference (.md)')),
        ),
        const SizedBox(height: 8),
        _CliTip(
          title: _tr(context, '请求和参考文档要分开', 'Keep the request and the reference apart'),
          content: _tr(context, '先复制上方请求并粘贴到用户消息，在“任务：”后填写需求；导出的 Markdown 只作为命令参考附件。', 'Copy the request above, paste it into your message and describe your task after “Task:”. Attach the exported Markdown only as a command reference.'),
        ),
        _CliSectionTitle(
          title: _tr(context, '首次使用与故障排查', 'First use and troubleshooting'),
          description: _tr(context, '正常任务可直接使用下方命令；只有命令失败时，才需要核对安装、PATH 和接口状态。', 'For normal tasks, use the commands below directly. Check the installation, PATH and access status only when a command fails.'),
        ),
        _CliTip(
          title: _tr(context, 'Codex / Claude Code 任务权限', 'Codex / Claude Code task permissions'),
          content:
              _tr(context, 'PATH 配置不等于当前任务拥有执行权限。首次拒绝时，AI 应申请沙盒外命令执行权限，而不是附件或文件读取权限；无审批入口或你拒绝后才停止。', "Being on PATH doesn't mean the current task may run the CLI. If it's refused the first time, the AI should ask for permission to run commands outside the sandbox, not for attachment or file access, and stop only if there's no approval flow or you decline."),
        ),
        _CliTip(
          title: _tr(context, '读取和导入共用一个开关', 'One switch for reading and importing'),
          content:
              _tr(context, '笺盒只提供一个“AI 命令行接口”开关；开启后读取、拼装和 Skill 导入同时可用，是否实际写入仍以你当前交给 AI 的任务为准。', "JianHe has a single “AI CLI access” switch. When it's on, reading, composing and skill import all work; whether anything is actually written still depends on the task you give the AI."),
        ),
        _CliCommandCard(
          copyKey: const Key('cli-help-copy-version'),
          label: _tr(context, '确认 JianHe CLI 已正确安装', 'Check that the JianHe CLI is installed'),
          description: _tr(context, '成功后会显示当前安装的 JianHe CLI 版本号。', 'Shows the installed JianHe CLI version.'),
          command: '$cli --version',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          copyKey: const Key('cli-help-copy-status'),
          label: _tr(context, '检查 AI 命令行接口状态', 'Check AI CLI access status'),
          description: _tr(context, '显示接口权限和本地数据库状态，不会读取任何素材正文。', 'Shows the access setting and local database status without reading any item content.'),
          command: '$cli status',
          onCopy: onCopy,
        ),
        _CliSectionTitle(
          title: _tr(context, '查询和调用 Skill', 'Find and use skills'),
          description: _tr(context, '先取得真实 Skill ID，再一次加载入口说明和文件清单；只按入口引用补读辅助文件。', 'Get the real skill ID first, then load the main instructions and file list in one call. Read supporting files only when the instructions refer to them.'),
        ),
        _CliCommandCard(
          label: _tr(context, '列出笺盒中的全部 Skill', 'List all skills in JianHe'),
          description: _tr(context, '返回全部 Skill 的名称、ID 和摘要信息，不会修改笺盒。', "Returns every skill's name, ID and summary without changing JianHe."),
          command: '$cli item list --type skill --json',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '按关键词查找可用 Skill', 'Search skills by keyword'),
          description: _tr(context, '供 Claude Code、Codex 等 AI 助手查找匹配的 Skill，并取得 Skill ID。', 'Lets AI agents like Claude Code and Codex find matching skills and get their IDs.'),
          replaceHint: _tr(context, '把“关键词”换成你要查找的内容', "Replace “keyword” with what you're looking for"),
          command: '$cli item search "${_tr(context, '关键词', 'keyword')}" --type skill --json',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '取得调用 Skill 所需的完整上下文', 'Get everything needed to use a skill'),
          description: _tr(context, '一次返回完整 SKILL.md、包元数据和文件清单，不会执行其中的脚本。', 'Returns the full SKILL.md, package metadata and file list in one call without running any scripts.'),
          replaceHint: _tr(context, '把 <skill-id> 换成搜索结果中的真实 Skill ID', 'Replace <skill-id> with a real skill ID from the search results'),
          command: '$cli skill context "<skill-id>" --json',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '查看 Skill 的基本信息', "Show a skill's basic information"),
          description: _tr(context, '显示名称、分类、文件数量、更新时间和完整性哈希，不读取文件正文。', 'Shows the name, category, file count, update time and integrity hash without reading file contents.'),
          replaceHint: _tr(context, '把 <skill-id> 换成搜索结果中的真实 Skill ID', 'Replace <skill-id> with a real skill ID from the search results'),
          command: '$cli skill inspect "<skill-id>" --json',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '查看 Skill 包含哪些文件', "List a skill's files"),
          description: _tr(context, '列出入口文件、参考资料、脚本和资源文件，但不会执行或打开它们。', 'Lists the main file, references, scripts and assets without running or opening them.'),
          replaceHint: _tr(context, '把 <skill-id> 换成真实 Skill ID', 'Replace <skill-id> with a real skill ID'),
          command: '$cli skill files "<skill-id>" --json',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '读取 Skill 的主要使用说明', "Read a skill's main instructions"),
          description: _tr(context, '读取入口文件 SKILL.md；AI 应先理解它，再按需读取辅助文件。', 'Reads the main file SKILL.md. The AI should understand it first, then read supporting files as needed.'),
          replaceHint: _tr(context, '把 <skill-id> 换成真实 Skill ID', 'Replace <skill-id> with a real skill ID'),
          command: '$cli skill read "<skill-id>" "SKILL.md" --raw',
          onCopy: onCopy,
        ),
        _CliSectionTitle(
          title: _tr(context, 'AI 使用 Prompt 处理内容', 'Let AI process content with a prompt'),
          description: _tr(context, 'AI 可以读取已有 Prompt，并把文字或 UTF-8 文本文件交给指定 Prompt 拼装。', 'AI can read your prompts and compose text or a UTF-8 text file with a chosen prompt.'),
        ),
        _CliCommandCard(
          label: _tr(context, '获取 Prompt 清单和 ID', 'Get the prompt list and IDs'),
          description: _tr(context, '返回笺盒中的 Prompt；后续处理文字时需要使用其中的 ID。', "Returns the prompts in JianHe; you'll need one of these IDs to process text."),
          command: '$cli item list --type prompt --json',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '读取一条素材的完整正文', "Read an item's full content"),
          description: _tr(context, '根据真实素材 ID 输出完整内容，而不是列表中的摘要信息。', 'Prints the full content for a real item ID, not the summary shown in lists.'),
          replaceHint: _tr(context, '把 <item-id> 换成列表或搜索结果中的真实 ID', 'Replace <item-id> with a real ID from a list or search result'),
          command: '$cli item get "<item-id>" --raw',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '用指定 Prompt 处理一段文字', 'Process text with a prompt'),
          description: _tr(context, '把输入文字交给指定 Prompt，并在终端输出拼装结果。', 'Composes the input text with the chosen prompt and prints the result in the terminal.'),
          replaceHint: _tr(context, '替换 <prompt-id> 和“待处理文字”', 'Replace <prompt-id> and “text to process”'),
          command: '$cli compose --prompt "<prompt-id>" --input '
              '"${_tr(context, '待处理文字', 'text to process')}"',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '用指定 Prompt 处理文本文件', 'Process a text file with a prompt'),
          description: _tr(context, '读取本机 UTF-8 文本文件，并将文件内容作为 Prompt 输入。', 'Reads a local UTF-8 text file and uses its content as the prompt input.'),
          replaceHint: _tr(context, '替换 <prompt-id>，并把 input.txt 换成真实文件路径', 'Replace <prompt-id>, and input.txt with a real file path'),
          command:
              '$cli compose --prompt "<prompt-id>" --input-file "input.txt"',
          onCopy: onCopy,
        ),
        _CliSectionTitle(
          title: _tr(context, '创建或导入 Skill', 'Create or import skills'),
          description: _tr(context, '用户要求把 Skill 放进笺盒时，可先校验来源文件，再执行正式导入。', 'When you ask for a skill to be added to JianHe, the AI can validate the source first, then import it.'),
        ),
        _CliCommandCard(
          label: _tr(context, '检查 Skill 是否符合导入要求', 'Check that a skill can be imported'),
          description: _tr(context, '检查文件夹结构和 SKILL.md，只验证，不会保存或修改笺盒内容。', 'Checks the folder structure and SKILL.md. Validation only; nothing in JianHe is saved or changed.'),
          replaceHint: _tr(context, '把 .\\my-skill 换成真实 Skill 文件夹、Markdown 或 ZIP 路径', 'Replace .\\my-skill with a real skill folder, Markdown or ZIP path'),
          command: '$cli skill import ".\\my-skill" --dry-run',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '把自建或外部 Skill 正式保存到笺盒', 'Save your own or a third-party skill to JianHe'),
          description: _tr(context, '此命令会写入笺盒；用户当前任务已要求导入时可直接执行。', 'This command writes to JianHe. Run it directly when your current task asks for the import.'),
          replaceHint: _tr(context, '把 .\\my-skill 换成已经验证通过的真实路径', 'Replace .\\my-skill with the real path that passed validation'),
          impact: _CliCommandImpact.dataWrite,
          command: '$cli skill import ".\\my-skill"',
          onCopy: onCopy,
        ),
        _CliTip(
          title: _tr(context, '分类要复用，不要新建', 'Reuse categories instead of creating new ones'),
          content:
              _tr(context, '导入前先用 item list --json 查看已有分类并优先复用；分类名区分大小写、按精确匹配，写法要与已有分类完全一致，避免产生重复分类。', 'Before importing, run item list --json to see existing categories and reuse them. Category names are case-sensitive and must match exactly, so spell them like the existing ones to avoid duplicates.'),
        ),
        _CliSectionTitle(
          title: _tr(context, '汇总当前 Agent 环境 Skill', 'Summarize the skills in your agent environment'),
          description: _tr(context, '扫描 Codex 与 Claude Code 的标准用户/项目目录，生成元数据索引，并按需保存到笺盒。', 'Scans the standard user and project folders of Codex and Claude Code, builds a metadata index and saves it to JianHe when asked.'),
        ),
        _CliCommandCard(
          label: _tr(context, '扫描当前环境中的 Skill', 'Scan skills in the current environment'),
          description: _tr(context, '返回名称、description、来源、兼容性和包校验结果；不会执行脚本，也不会读写笺盒数据库。', "Returns names, descriptions, sources, compatibility and package checks. Runs no scripts and doesn't touch the JianHe database."),
          command: '$cli skill scan --json',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '检查将要生成的环境 Skill 索引', 'Preview the environment skill index'),
          description: _tr(context, '生成并校验索引内容，不访问或修改笺盒数据库。', 'Builds and validates the index content without reading or changing the JianHe database.'),
          command: '$cli skill index --dry-run --json',
          onCopy: onCopy,
        ),
        _CliCommandCard(
          label: _tr(context, '把环境 Skill 索引保存到笺盒', 'Save the environment skill index to JianHe'),
          description: _tr(context, '首次创建一条索引；以后环境发生变化时更新同一条，不重复新增。', 'Creates one index the first time, then updates that same index when the environment changes instead of adding new ones.'),
          impact: _CliCommandImpact.dataWrite,
          command: '$cli skill index --import --json',
          onCopy: onCopy,
        ),
        _CliTip(
          title: _tr(context, '插件和额外 Skill 目录', 'Plugins and extra skill folders'),
          content:
              _tr(context, 'CLI 不盲扫整个磁盘或插件缓存。Codex / Claude Code 已知某个额外 Skill 或容器路径时，可在 scan 和 index 命令中重复添加 --root "路径"。', 'The CLI never scans the whole disk or plugin caches. When Codex / Claude Code knows an extra skill or container path, add --root "path" (repeatable) to the scan and index commands.'),
        ),
        _CliCommandCard(
          label: _tr(context, '把完整 Skill 导出为 ZIP', 'Export a complete skill as ZIP'),
          description: _tr(context, '在本机创建 ZIP 文件，方便备份或移动；不会修改笺盒中的原 Skill。', "Creates a ZIP file on this computer for backup or moving; the skill in JianHe isn't changed."),
          replaceHint: _tr(context, '替换 <skill-id> 和输出路径 .\\skill.zip', 'Replace <skill-id> and the output path .\\skill.zip'),
          impact: _CliCommandImpact.fileWrite,
          command:
              '$cli skill export "<skill-id>" --output ".\\skill.zip" --format zip',
          onCopy: onCopy,
        ),
        _CliSectionTitle(
          title: _tr(context, '完整命令参考', 'Full command reference'),
          description: _tr(context, '需要查看其他命令或参数时，通过帮助命令进入对应分类。', 'To see other commands or options, use the help command for each category.'),
        ),
        _CliCommandCard(
          copyKey: const Key('cli-help-copy-top-help'),
          label: _tr(context, '查看全部命令分类', 'Show all command categories'),
          description: _tr(context, '显示当前版本支持的命令和进一步帮助入口。', 'Shows the commands in this version and where to get more help.'),
          command: '$cli --help',
          onCopy: onCopy,
        ),
        _CliSectionTitle(
          title: _tr(context, '常见问题', 'FAQ'),
          description: _tr(context, '接口只在本机读写数据；是否向网络发送内容取决于所使用的 AI 助手。', 'The CLI only reads and writes data on this computer; whether anything is sent over the network depends on your AI agent.'),
        ),
        _CliTip(
          title: _tr(context, '“调用 Skill”是什么意思', 'What “using a skill” means'),
          content: _tr(context, 'AI 会读取 SKILL.md 及必要的辅助文件，再按照说明完成任务；笺盒不会自动执行 Skill 中的脚本。', 'The AI reads SKILL.md and any supporting files it needs, then follows the instructions. JianHe never runs scripts in a skill automatically.'),
        ),
        _CliTip(
          title: _tr(context, '找不到 jianhe 命令', "The jianhe command isn't found"),
          content:
              _tr(context, '先使用本页给出的 CLI 绝对路径。绝对路径不存在时才需重新安装；程序存在但被拒绝启动时，应先申请任务执行权限，不能直接判定为不可用。', "Use the absolute CLI path on this page first. Reinstall only if that path doesn't exist. If the program exists but is refused, ask for permission to run it; that doesn't mean the CLI is unavailable."),
        ),
        _CliTip(
          title: _tr(context, '提示 CLI access is disabled', '“CLI access is disabled”'),
          content: _tr(context, '在笺盒“更多”中开启“AI 命令行接口”，再重新执行命令。', 'Turn on “AI CLI access” under More in JianHe, then run the command again.'),
        ),
        _CliTip(
          title: _tr(context, '输出文件已经存在', 'The output file already exists'),
          content: _tr(context, '确认可以覆盖后，在 Skill 导出命令末尾添加 --force。', "If it's OK to overwrite it, add --force to the end of the skill export command."),
        ),
        _CliTip(
          title: _tr(context, '退出码', 'Exit codes'),
          content: _tr(context, '0 成功；2 参数错误；3 内容不存在；4 权限未开启；5 本地存储错误；6 Skill 包或输出校验失败。', '0 success; 2 invalid arguments; 3 not found; 4 access is off; 5 local storage error; 6 skill package or output validation failed.'),
        ),
      ],
    );
  }
}

class _CliStatusCard extends StatelessWidget {
  const _CliStatusCard({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? const Color(0xFF32765B) : const Color(0xFF9A5B34);
    return Container(
      key: const Key('cli-help-access-status'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            enabled ? Icons.check_circle_outline_rounded : Icons.info_outline,
            color: color,
            size: 21,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              enabled
                  ? _tr(context, 'AI 命令行接口已开启，可以读取、拼装及导入 Skill。', 'AI CLI access is on. Reading, composing and skill import are available.')
                  : _tr(context, 'AI 命令行接口未开启；帮助和 status 命令仍可使用。', 'AI CLI access is off. Help and the status command still work.'),
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CliSectionTitle extends StatelessWidget {
  const _CliSectionTitle({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            description,
            style: const TextStyle(color: Color(0xFF81796E), fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _CliCommandCard extends StatelessWidget {
  const _CliCommandCard({
    this.copyKey,
    required this.label,
    required this.description,
    this.replaceHint,
    this.impact = _CliCommandImpact.readOnly,
    required this.command,
    required this.onCopy,
  });

  final Key? copyKey;
  final String label;
  final String description;
  final String? replaceHint;
  final _CliCommandImpact impact;
  final String command;
  final Future<void> Function(String command) onCopy;

  @override
  Widget build(BuildContext context) {
    final (impactLabel, impactColor, impactIcon) = switch (impact) {
      _CliCommandImpact.readOnly => (
        _tr(context, '只读取，不修改笺盒', "Read-only, doesn't change JianHe"),
        const Color(0xFF32765B),
        Icons.visibility_outlined,
      ),
      _CliCommandImpact.fileWrite => (
        _tr(context, '会在本机创建文件', 'Creates a file on this computer'),
        const Color(0xFF9A5B34),
        Icons.save_alt_rounded,
      ),
      _CliCommandImpact.dataWrite => (
        _tr(context, '会写入笺盒', 'Writes to JianHe'),
        const Color(0xFFA53E36),
        Icons.warning_amber_rounded,
      ),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(11, 9, 6, 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5DCD0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF292620),
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            description,
            style: const TextStyle(
              color: Color(0xFF6F675E),
              fontSize: 11.5,
              height: 1.4,
            ),
          ),
          if (replaceHint != null) ...<Widget>[
            const SizedBox(height: 5),
            Text(
              '${_tr(context, '需要替换：', '')}$replaceHint',
              style: const TextStyle(
                color: Color(0xFF9A5B34),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 7),
          SelectableText(
            command,
            style: const TextStyle(
              color: Color(0xFF292620),
              fontFamily: 'Consolas',
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: impactColor.withValues(alpha: .09),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(impactIcon, size: 13, color: impactColor),
                    const SizedBox(width: 4),
                    Text(
                      impactLabel,
                      style: TextStyle(
                        color: impactColor,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              IconButton(
                key: copyKey,
                tooltip: _tr(context, '复制命令', 'Copy command'),
                visualDensity: VisualDensity.compact,
                onPressed: () => onCopy(command),
                icon: const Icon(Icons.copy_rounded, size: 17),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CliTip extends StatelessWidget {
  const _CliTip({required this.title, required this.content});

  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: '$title${_tr(context, '：', ': ')}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            TextSpan(text: content),
          ],
        ),
        style: const TextStyle(
          color: Color(0xFF5F584F),
          fontSize: 11.5,
          height: 1.45,
        ),
      ),
    );
  }
}
