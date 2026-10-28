import 'package:jianhe_core/jianhe_core.dart';

/// Read-only sample items shown when no local database is available.
List<JianheItem> createDemoItems([
  AppLanguage language = AppLanguage.fallback,
]) {
  final now = DateTime.utc(2026, 1, 1);
  if (language == AppLanguage.en) return _englishDemoItems(now);
  return <JianheItem>[
    JianheItem.create(
      id: 'demo-summary',
      type: ItemType.prompt,
      title: '结构化总结',
      content: '请把下面的内容整理成结构化摘要。保留关键事实，分为「核心结论、重要依据、下一步行动」三部分：\n\n{{input}}',
      rating: 5,
      category: '总结整理',
      sortOrder: 0,
      now: now,
    ),
    JianheItem.create(
      id: 'demo-polish',
      type: ItemType.prompt,
      title: '自然语言润色',
      content: '请润色以下文字。保持原意，删除重复表达，让语气自然、清楚，不要增加未经证实的信息。',
      rating: 4,
      category: '内容写作',
      sortOrder: 1,
      now: now.add(const Duration(minutes: 1)),
    ),
    JianheItem.create(
      id: 'demo-review',
      type: ItemType.prompt,
      title: '反方审阅',
      content: '请以严格的反方审阅者视角检查下面的方案，指出隐含假设、风险、证据缺口，并给出可验证的改进建议。',
      rating: 2,
      category: '分析决策',
      sortOrder: 2,
      now: now.add(const Duration(minutes: 2)),
    ),
    JianheItem.create(
      id: 'demo-skill',
      type: ItemType.skill,
      title: '内容诊断 Skill',
      content:
          '# 内容诊断\n\n## 目标\n检查内容是否清楚、可信、有行动价值。\n\n## 输出\n1. 主要问题\n2. 修改建议\n3. 改写示例',
      category: '内容写作',
      sortOrder: 0,
      now: now.add(const Duration(minutes: 3)),
    ),
    JianheItem.create(
      id: 'demo-snippet',
      type: ItemType.snippet,
      title: '个人介绍',
      content: '我是笺盒的创建者，正在打造一个本地优先、跨模型的 AI 素材与输入拼装工具。',
      category: '个人资料',
      sortOrder: 0,
      now: now.add(const Duration(minutes: 4)),
    ),
  ];
}

List<JianheItem> _englishDemoItems(DateTime now) => <JianheItem>[
  JianheItem.create(
    id: 'demo-summary',
    type: ItemType.prompt,
    title: 'Structured summary',
    content:
        'Turn the content below into a structured summary. Keep the key '
        'facts and split it into three parts: key conclusions, supporting '
        'evidence and next steps:\n\n{{input}}',
    rating: 5,
    category: 'Summaries',
    sortOrder: 0,
    now: now,
  ),
  JianheItem.create(
    id: 'demo-polish',
    type: ItemType.prompt,
    title: 'Natural polish',
    content:
        'Polish the text below. Keep the meaning, remove repetition, make '
        "the tone natural and clear, and don't add unverified information.",
    rating: 4,
    category: 'Writing',
    sortOrder: 1,
    now: now.add(const Duration(minutes: 1)),
  ),
  JianheItem.create(
    id: 'demo-review',
    type: ItemType.prompt,
    title: "Devil's advocate review",
    content:
        "Review the plan below as a strict devil's advocate. Point out "
        'hidden assumptions, risks and gaps in the evidence, and suggest '
        'improvements that can be verified.',
    rating: 2,
    category: 'Analysis',
    sortOrder: 2,
    now: now.add(const Duration(minutes: 2)),
  ),
  JianheItem.create(
    id: 'demo-skill',
    type: ItemType.skill,
    title: 'Content check skill',
    content:
        '# Content check\n\n## Goal\nCheck whether the content is clear, '
        'credible and actionable.\n\n## Output\n1. Main problems\n'
        '2. Suggested changes\n3. Rewrite example',
    category: 'Writing',
    sortOrder: 0,
    now: now.add(const Duration(minutes: 3)),
  ),
  JianheItem.create(
    id: 'demo-snippet',
    type: ItemType.snippet,
    title: 'About me',
    content:
        "I'm the creator of JianHe, building a local-first, cross-model tool "
        'for managing AI materials and composing input.',
    category: 'Personal',
    sortOrder: 0,
    now: now.add(const Duration(minutes: 4)),
  ),
];
