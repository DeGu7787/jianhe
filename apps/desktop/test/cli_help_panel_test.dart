import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/features/help/cli_help_panel.dart';

void main() {
  const cliPath = r"C:\Program Files\JianHe user's build\cli\bin\jianhe.exe";

  test('PowerShell CLI command safely quotes the absolute path', () {
    expect(
      cliPowerShellCommand(cliPath),
      r"& 'C:\Program Files\JianHe user''s build\cli\bin\jianhe.exe'",
    );
  });

  test('user request carries authorization outside the attachment', () {
    final request = buildCliUserRequestTemplate(cliPath);

    expect(request, startsWith('请使用本机已安装的 JianHe CLI'));
    expect(request, contains('我允许本次执行'));
    expect(request, contains('不拆分读取和导入权限'));
    expect(request, contains('可以列出、查找、读取和扫描 Skill'));
    expect(request, contains('任务明确要求创建、导入或保存环境 Skill 索引时'));
    expect(request, contains('命令执行审批入口向我发起审批'));
    expect(request, contains('`$cliPath`'));
    expect(request, contains('附件仅是 JianHe CLI'));
    expect(request, endsWith('任务：'));
  });

  test(
    'exported guide is factual reference rather than user authorization',
    () {
      final guide = buildCliGuideMarkdown(cliPath);
      final cli = cliPowerShellCommand(cliPath);

      expect(guide, startsWith('# 笺盒 JianHe CLI 参考手册'));
      expect(guide, contains('不包含当前任务'));
      expect(guide, contains('不代表用户对任何执行、审批或数据写入的授权'));
      expect(guide, contains('当前安装路径：`$cliPath`'));
      expect(guide, contains('PowerShell 绝对路径调用形式：`$cli`'));
      expect(guide, contains('jianhe item list --type skill --json'));
      expect(guide, contains('jianhe item search'));
      expect(guide, contains('jianhe skill context'));
      expect(guide, contains('jianhe skill scan --json'));
      expect(guide, contains('jianhe skill index --dry-run --json'));
      expect(guide, contains('jianhe skill index --import --json'));
      expect(guide, contains('jianhe skill import'));
      expect(guide, contains('创建新 Skill 不是独立的 CLI 子命令'));
      expect(guide, contains('name: 示例 Skill 名称'));
      expect(guide, contains('读取与导入共用的单一开关'));
      expect(guide, contains('不会盲扫整个磁盘或插件缓存'));
      expect(guide, contains('不会执行发现的\n脚本'));
      expect(guide, contains('变化时更新同一条索引'));
      expect(guide, contains('`access` 和 `skill_import_enabled`'));
      expect(guide, isNot(contains('cli_access_mode')));
      expect(guide, contains('附件文档不会授予沙盒外执行权限'));
      expect(guide, isNot(contains('智能体应')));
      expect(guide, isNot(contains('向我发起审批')));
      expect(guide, isNot(contains('无需再询问')));
    },
  );

  test('English request and guide keep the same authorization boundary', () {
    final request = buildCliUserRequestTemplate(
      cliPath,
      language: AppLanguage.en,
    );
    expect(request, startsWith('Please use the JianHe CLI'));
    expect(request, contains('I allow the JianHe CLI operations'));
    expect(request, contains('`$cliPath`'));
    expect(request, contains('command-approval flow'));
    expect(request, contains('The attachment is only a reference'));
    expect(request, endsWith('Task: '));
    expect(request, isNot(matches(RegExp('[\u4e00-\u9fff]'))));

    final guide = buildCliGuideMarkdown(cliPath, language: AppLanguage.en);
    expect(guide, startsWith('# JianHe CLI Reference'));
    expect(guide, contains('does not grant any authorization'));
    expect(guide, contains('Current install path: `$cliPath`'));
    expect(guide, contains(cliPowerShellCommand(cliPath)));
    expect(guide, contains(r'`$CODEX_HOME/skills`'));
    expect(guide, contains(r'--output ".\skill.zip"'));
    expect(guide, isNot(matches(RegExp('[\u4e00-\u9fff]'))));
  });
}
