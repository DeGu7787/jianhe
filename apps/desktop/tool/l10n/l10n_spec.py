# Source of truth for lib/l10n/app_strings*.dart (desktop app).
# Each entry: (name, params, zh, en). `params` is '' for a getter, otherwise
# a Dart parameter list body. zh/en are Dart expressions.
#
# Edit here, then run gen_l10n.py next to this file.

S = []
def g(name, zh, en): S.append((name, '', zh, en))
def f(name, params, zh, en): S.append((name, params, zh, en))
def section(title): S.append(('#', title, '', ''))

section('General')
g('appName', "'笺盒'", "'JianHe'")
g('cancel', "'取消'", "'Cancel'")
g('delete', "'删除'", "'Delete'")
g('edit', "'编辑'", "'Edit'")
g('copy', "'复制'", "'Copy'")
g('close', "'关闭'", "'Close'")
g('done', "'完成'", "'Done'")
g('retry', "'重试'", "'Retry'")
g('remove', "'移除'", "'Remove'")
g('rename', "'重命名'", "'Rename'")
g('apply', "'应用'", "'Apply'")
g('clearSearch', "'清除搜索'", "'Clear search'")
g('uncategorized', "'未分类'", "'Uncategorized'")
g('all', "'全部'", "'All'")
g('binaryFile', "'二进制文件'", "'Binary file'")
f('typeName', 'ItemType type', """switch (type) {
    ItemType.prompt => 'Prompt',
    ItemType.skill => 'Skills',
    ItemType.snippet => '常用文本',
  }""", """switch (type) {
    ItemType.prompt => 'Prompt',
    ItemType.skill => 'Skills',
    ItemType.snippet => 'Snippets',
  }""")
f('countItems', 'int count', "'$count 项'", "count == 1 ? '1 item' : '$count items'")
f('countCategories', 'int count', "'$count 个'", "count == 1 ? '1 category' : '$count categories'")
f('countFiles', 'int count', "'$count 个文件'", "count == 1 ? '1 file' : '$count files'")
f('secondsValue', 'int seconds', "'$seconds 秒'", "'$seconds sec'")

section('Startup and global errors')
g('startupDatabaseLocked',
  "'本地数据库正被其他程序（如 jianhe 命令行、Codex 或终端）占用，'\n      '当前以只读演示数据运行。请关闭这些程序后重启笺盒。'",
  "'The local database is in use by another program (such as the jianhe '\n      'CLI, Codex or a terminal). JianHe is running with read-only demo data. '\n      'Close those programs and restart JianHe.'")
f('startupDatabaseFailed', 'String logPath',
  "'本地数据库打开或升级失败，当前以只读演示数据运行，备份与写入已停用。'\n      '详情见 $logPath'",
  "\"The local database couldn't be opened or upgraded. JianHe is running \"\n      'with read-only demo data, and backups and saving are disabled. '\n      'Details: $logPath'")
g('uiErrorTitle', "'界面出现异常'", "'Something went wrong'")
g('uiErrorBody', "'已记录该问题，内容不受影响，可重启笺盒继续使用。'",
  "\"The problem has been logged and your items aren't affected. \"\n      'Restart JianHe to continue.'")

section('Floating ball and menu')
g('menuCompose', "'快速拼装'", "'Compose'")
g('menuNew', "'新建'", "'New'")
g('menuMore', "'更多'", "'More'")
g('ballSemanticLabel', "'笺盒悬浮球'", "'JianHe floating ball'")
g('backToMenu', "'返回功能菜单'", "'Back to menu'")
g('collapsePanel', "'收起笺盒'", "'Collapse JianHe'")

section('Item list notices')
g('noticeDatabaseBusyWaiting',
  "'本地数据库正被其他程序（如 jianhe 命令行）占用，正在等待保存…'",
  "'The local database is in use by another program (such as the jianhe '\n      'CLI). Waiting to save…'")
g('noticeItemsUnreadable', "'本地素材暂时无法读取，请重启应用后再试。'",
  "\"Your items can't be read right now. Restart the app and try again.\"")
g('noticeItemDeletedElsewhere', "'该素材已被删除'", "'This item has been deleted'")
g('noticeRefreshFailed', "'素材列表刷新失败，请稍后重试'",
  "\"Couldn't refresh the list. Please try again later\"")
g('noticeReadOnlyDemo', "'本地数据库不可用，当前演示数据为只读'",
  "'The local database is unavailable, so the demo data is read-only'")
f('noticeCategoryPinned', 'String category', "'已置顶“$category”'", "'Pinned “$category”'")
f('noticeCategoryUnpinned', 'String category', "'已取消置顶“$category”'", "'Unpinned “$category”'")
g('pinCategory', "'置顶分类'", "'Pin category'")
g('unpinCategory', "'取消置顶'", "'Unpin'")
f('noticeHotKeyTaken', 'String hotKey', "'$hotKey 已被其他程序占用'",
  "'$hotKey is in use by another program'")
g('noticeComposeNeedsInput', "'先放入一段待处理文字'", "'Add some text to process first'")
g('noticeCopiedToClipboard', "'已复制到剪贴板'", "'Copied to clipboard'")
f('noticeItemCopied', 'String title', "'\"$title\"已复制'", "'Copied \"$title\"'")
g('noticeRatingSaveFailed', "'评分保存失败，请稍后重试'",
  "\"Couldn't save the rating. Please try again later\"")
g('noticeItemMissingRefreshed', "'该素材已不存在，列表已刷新'",
  "'This item no longer exists. The list has been refreshed'")

section('Skill import')
g('skillCreateDialogTitle', "'新建或导入 Skill'", "'New or import skill'")
g('skillImportFolder', "'导入 Skill 文件夹'", "'Import skill folder'")
g('skillImportFile', "'导入 ZIP 或 Markdown'", "'Import ZIP or Markdown'")
g('skillCreateManual', "'手工新建单文件 Skill'", "'Create a single-file skill'")
g('skillImportRootHint', "'文件夹和 ZIP 的根目录需要包含 SKILL.md。'",
  "'The root of the folder or ZIP must contain SKILL.md.'")
g('noticeSkillLibraryUnavailable', "'本地 Skill 仓库不可用'",
  "'The local skill library is unavailable'")
f('noticeSkillAlreadyImported', 'String title', "'已经导入过：$title'", "'Already imported: $title'")
f('noticeSkillImported', 'String title, int fileCount',
  "'已导入 $title（$fileCount 个文件）'",
  "'Imported $title (${countFiles(fileCount)})'")
f('noticeSkillImportedLocalOnly', 'String title, int fileCount, int limitMiB',
  "'已导入 $title（$fileCount 个文件）。'\n      '这个 Skill 包超过云同步单个上限 '\n      '$limitMiB MiB，只会保存在本机，不会同步到其他设备。'",
  "'Imported $title (${countFiles(fileCount)}). This skill package is over '\n      \"the $limitMiB MiB cloud sync limit, so it stays on this PC and won't \"\n      'sync to other devices.'")
g('noticeSkillPackageInvalid', "'Skill 包无效：文件结构、路径或大小不符合要求，请检查后重试'",
  "\"Invalid skill package: the file structure, paths or sizes don't meet \"\n      'the requirements. Check it and try again'")
g('noticeSkillImportFailed', "'Skill 导入失败，请检查文件后重试'",
  "'Skill import failed. Check the files and try again'")
g('skillSourceFolder', "'文件夹'", "'Folder'")
g('skillImportConfirmTitle', "'确认导入 Skill'", "'Import this skill?'")
g('detailName', "'名称'", "'Name'")
g('detailSource', "'来源'", "'Source'")
g('detailFiles', "'文件'", "'Files'")
g('detailFile', "'文件'", "'File'")
g('detailCategory', "'分类'", "'Category'")
g('detailContents', "'内容'", "'Items'")
f('fileCountAndSize', 'int count, String size', "'$count 个 · $size'", "'${countFiles(count)} · $size'")
g('skillMdPreview', "'SKILL.md 预览'", "'SKILL.md preview'")
g('confirmImport', "'确认导入'", "'Import'")
g('skillFolderDialogTitle', "'选择包含 SKILL.md 的 Skill 文件夹'",
  "'Choose a skill folder that contains SKILL.md'")
g('skillFileDialogTitle', "'选择 Skill 文件'", "'Choose a skill file'")
g('skillFileDialogMacPrompt', "'选择 Skill ZIP 或 Markdown 文件'", "'Choose a skill ZIP or Markdown file'")
g('skillFileDialogFilter',
  "'Skill 文件 (*.zip;*.md)|*.zip;*.md|ZIP 包 (*.zip)|*.zip|Markdown (*.md)|*.md'",
  "'Skill files (*.zip;*.md)|*.zip;*.md|ZIP archive (*.zip)|*.zip|'\n      'Markdown (*.md)|*.md'")
g('skillFileZenityFilter', "'Skill 文件 | *.zip *.md'", "'Skill files | *.zip *.md'")
g('skillPickerUnavailable', "'系统 Skill 选择窗口无法打开。'",
  "\"The system skill picker couldn't be opened.\"")
g('skillImportUnsupported', "'当前平台不支持导入本地 Skill 包。'",
  "\"Importing local skill packages isn't supported on this platform.\"")

section('Saving and deleting items')
g('noticeCannotSaveNoDatabase', "'本地数据库不可用，暂时无法保存'",
  "\"The local database is unavailable, so this can't be saved right now\"")
g('noticeCategoryGone', "'所选分类已不存在，请重新选择'",
  "'The selected category no longer exists. Choose another one'")
g('noticeItemCreated', "'素材已收入笺盒'", "'Saved to JianHe'")
g('noticeItemUpdated', "'素材修改已保存'", "'Changes saved'")
f('validationTitle', 'int max', "'标题不能为空，且不超过 $max 个字符'",
  "'The title is required and can be up to $max characters'")
f('validationContent', 'int max', "'内容不能为空，且不超过 $max 个字符'",
  "'The content is required and can be up to $max characters'")
f('validationCategory', 'int max', "'分类名需为 1–$max 个字符，且不能包含控制字符'",
  "'Category names must be 1–$max characters with no control characters'")
g('validationRequired', "'名称和内容都要填写'", "'Fill in both the name and the content'")
g('noticeSaveFailed', "'保存失败，请检查本地数据库'", "'Save failed. Check the local database'")
g('conflictDeletedTitle', "'素材已在别处被删除'", "'This item was deleted elsewhere'")
g('conflictModifiedTitle', "'素材已在别处被修改'", "'This item was changed elsewhere'")
g('conflictDeletedBody',
  "'你编辑期间，这条素材已被其他程序或设备删除。'\n      '“覆盖”会把你的内容另存为一条新素材；“放弃”将丢弃本次修改。'",
  "'While you were editing, another program or device deleted this item. '\n      '“Overwrite” saves your content as a new item; “Discard” throws away '\n      'your changes.'")
g('conflictModifiedBody',
  "'你编辑期间，这条素材已被其他程序（如 jianhe 命令行）或其他设备修改。'\n      '“覆盖”会用你的内容替换对方的修改；“放弃”将丢弃本次修改并载入最新内容。'",
  "'While you were editing, another program (such as the jianhe CLI) or '\n      'another device changed this item. “Overwrite” replaces those changes '\n      'with yours; “Discard” throws away your changes and loads the latest '\n      'version.'")
g('discard', "'放弃'", "'Discard'")
g('overwrite', "'覆盖'", "'Overwrite'")
g('noticeEditDiscarded', "'已放弃本次修改'", "'Changes discarded'")
g('deleteItemTitle', "'删除素材？'", "'Delete item?'")
f('deleteItemBody', 'String title', "'「$title」将被移出笺盒，此操作无法撤销。'",
  "'“$title” will be removed from JianHe. This can\\'t be undone.'")
g('noticeDeleteFailed', "'删除失败，请稍后重试'", "\"Couldn't delete. Please try again later\"")
f('noticeItemDeleted', 'String title', "'「$title」已删除'", "'Deleted “$title”'")
g('noticeSortFailed', "'排序整理失败，请稍后重试'",
  "\"Couldn't arrange the order. Please try again later\"")
g('noticeMoveFailed', "'移动保存失败，请稍后重试'",
  "\"Couldn't save the move. Please try again later\"")

section('Categories')
f('manageCategoriesTitle', 'ItemType type', "'${typeName(type)}分类管理'",
  "'${typeName(type)} categories'")
g('noCategoriesHint', "'还没有分类。点击下方\"新建分类\"开始整理素材。'",
  "'No categories yet. Click “New category” below to start organizing.'")
g('categoryActions', "'分类操作'", "'Category actions'")
g('removeCategory', "'移除分类'", "'Remove category'")
g('newCategory', "'新建分类'", "'New category'")
f('newCategoryTitle', 'ItemType type', "'新建${typeName(type)}分类'",
  "'New ${typeName(type)} category'")
g('categoryNameHint', "'例如：内容写作'", "'e.g. Writing'")
g('renameCategoryTitle', "'重命名分类'", "'Rename category'")
g('categoryNameLabel', "'分类名称'", "'Category name'")
# The Chinese dialog has always said 创建 for both create and rename.
g('categoryDialogConfirm', "'创建'", "'OK'")
f('noticeCategoryExists', 'String category', "'分类\"$category\"已经存在'",
  "'Category “$category” already exists'")
f('noticeCategoryCreated', 'String category', "'分类\"$category\"已创建'",
  "'Created category “$category”'")
f('invalidCategoryName', 'int max', "'分类名称必须为 1–$max 个字符，且不能包含控制字符'",
  "'Category names must be 1–$max characters with no control characters'")
g('noticeCategoryRenamed', "'分类已重命名'", "'Category renamed'")
g('removeCategoryTitle', "'移除分类？'", "'Remove category?'")
f('removeCategoryBody', 'String category', "'\"$category\"中的素材会保留，并移动到未分类。'",
  "'Items in “$category” are kept and moved to Uncategorized.'")
g('noticeMovedToUncategorized', "'素材已移动到未分类'", "'Items moved to Uncategorized'")
g('noticeCategoryChangeFailed', "'分类修改失败，请稍后重试'",
  "\"Couldn't change the category. Please try again later\"")

section('Offline transfer (.jianhe)')
g('noticeExportUnavailable', "'本地数据库不可用，暂时无法导出备份'",
  "\"The local database is unavailable, so nothing can be exported right now\"")
f('noticeExported', 'int count', "'已导出 $count 项内容'", "'Exported ${countItems(count)}'")
g('noticeExportFailed', "'导出失败，请重新选择保存位置'",
  "'Export failed. Choose another save location'")
g('noticeImportUnavailable', "'本地数据库不可用，暂时无法导入备份'",
  "\"The local database is unavailable, so nothing can be imported right now\"")
g('importBackupTitle', "'导入离线备份？'", "'Import transfer file?'")
g('importBackupMergeHint', "'将与本机内容合并；同一素材会保留修改时间较新的版本。'",
  "\"Merges with what's on this PC. When an item exists in both, the more \"\n      'recently modified version is kept.'")
g('mergeImport', "'合并导入'", "'Merge'")
f('noticeImportDone', 'int created, int updated, int skipped',
  "'导入完成：新增 $created，'\n      '更新 $updated，跳过 $skipped'",
  "'Import complete: $created added, $updated updated, $skipped skipped'")
f('noticeImportFormatError', 'String message', "'无法导入：$message'", "\"Can't import: $message\"")
g('noticeImportFailed', "'导入失败，请确认文件来自笺盒'",
  "'Import failed. Make sure the file was exported from JianHe'")
g('backupFileNamePrefix', "'笺盒-离线备份-'", "'JianHe-transfer-'")
g('backupDefaultFileName', "'笺盒-备份.jianhe'", "'JianHe-transfer.jianhe'")
g('backupSaveDialogTitle', "'导出笺盒离线备份'", "'Export JianHe transfer file'")
g('backupOpenDialogTitle', "'选择笺盒离线备份'", "'Choose a JianHe transfer file'")
g('backupDialogFilter', "'笺盒备份 (*.jianhe)|*.jianhe|JSON 文件 (*.json)|*.json'",
  "'JianHe transfer file (*.jianhe)|*.jianhe|JSON file (*.json)|*.json'")
g('backupZenityFilter', "'笺盒备份 | *.jianhe *.json'", "'JianHe transfer file | *.jianhe *.json'")
g('backupTooLarge', "'备份文件不能超过 100 MB。'", "'Transfer files can be up to 100 MB.'")
g('backupReadFailed', "'备份文件读取失败，请重试。'",
  "\"Couldn't read the transfer file. Please try again.\"")
g('fileDialogUnavailable', "'系统文件对话框无法打开。'",
  "\"The system file dialog couldn't be opened.\"")

section('CLI access and hotkey')
g('noticeCliEnabled', "'AI 命令行接口已开启'", "'AI CLI access is on'")
g('noticeCliDisabled', "'AI 命令行接口已关闭'", "'AI CLI access is off'")
g('hotKeyDialogTitle', "'设置唤起快捷键'", "'Set wake hotkey'")
g('hotKeyDialogPrompt', "'请直接按下新的组合键'", "'Press the new key combination'")
g('hotKeyUnsupported', "'该按键暂不支持'", "\"This key isn't supported\"")
g('hotKeyNeedsModifier', "'全局快捷键至少需要一个修饰键'",
  "'A global hotkey needs at least one modifier key'")
g('hotKeyHelp', "'支持 Ctrl、Alt、Shift 或 Win 与字母、数字、F1–F24 及常用按键组合'",
  "'Combine Ctrl, Alt, Shift or Win with a letter, number, F1–F24 or '\n      'another common key'")
g('resetToDefault', "'恢复默认'", "'Reset to default'")
g('noticeHotKeyRejected', "'新快捷键被系统或其他应用占用，已保留原快捷键'",
  "'That hotkey is in use by Windows or another app. Your previous hotkey '\n      'is kept'")
f('noticeHotKeyUpdated', 'String hotKey', "'唤起快捷键已更新为 $hotKey'",
  "'Wake hotkey changed to $hotKey'")
f('noticeAutoCollapse', 'int seconds', "'移出后 $seconds 秒自动收回'",
  "seconds == 1\n      ? 'Collapses 1 second after the pointer leaves'\n      : 'Collapses $seconds seconds after the pointer leaves'")

section('Compose panel')
g('composerSubtitle', "'用 Prompt 处理原文并复制结果'", "'Process text with a prompt and copy the result'")
g('choosePrompt', "'选择 Prompt'", "'Choose a prompt'")
g('inputLabel', "'待处理文字'", "'Text to process'")
g('paste', "'粘贴'", "'Paste'")
g('inputHint', "'把需要处理的文字放进来…'", "'Put the text you want to process here…'")
g('resultLabel', "'拼装结果'", "'Result'")
g('resultPlaceholder', "'粘贴后自动生成'", "'Appears as soon as you add text'")

section('Item browser')
f('browserSubtitle', 'ItemType type', """switch (type) {
    ItemType.prompt => '管理并使用提示词',
    ItemType.skill => '查看、复制和管理 Skill',
    ItemType.snippet => '保存常用文本，一键复制',
  }""", """switch (type) {
    ItemType.prompt => 'Manage and use your prompts',
    ItemType.skill => 'View, copy and manage skills',
    ItemType.snippet => 'Save snippets and copy them in one click',
  }""")
f('searchHint', 'ItemType type', """switch (type) {
    ItemType.prompt => '搜索 Prompt',
    ItemType.skill => '搜索 Skills',
    ItemType.snippet => '搜索常用文本',
  }""", """switch (type) {
    ItemType.prompt => 'Search prompts',
    ItemType.skill => 'Search skills',
    ItemType.snippet => 'Search snippets',
  }""")
f('newItemOfType', 'ItemType type', "'新建${typeName(type)}'", """switch (type) {
    ItemType.prompt => 'New prompt',
    ItemType.skill => 'New skill',
    ItemType.snippet => 'New snippet',
  }""")
g('ratingLabel', "'星级'", "'Rating'")
g('sortTooltip', "'排序方式'", "'Sort by'")
g('manageCategories', "'分类管理'", "'Manage categories'")
g('collapseCategories', "'收起分类'", "'Collapse categories'")
g('expandCategories', "'展开分类'", "'Expand categories'")
g('noMatchingItems', "'没有找到匹配的素材'", "'No matching items'")
g('emptyType', "'笺盒里还没有这一类素材'", "'Nothing here yet'")
g('actionCompose', "'拼装'", "'Compose'")
g('copiedCheck', "'✓ 已复制'", "'✓ Copied'")
g('actionView', "'查看'", "'View'")
g('readingSkill', "'正在读取 Skill'", "'Reading skill…'")
g('newOrImportSkill', "'新建 / 导入 Skill'", "'New / import skill'")
g('itemDetailTitle', "'素材详情'", "'Item details'")
g('noItemSelected', "'未选择素材'", "'No item selected'")
g('goBackAndSelect', "'请返回并选择一条素材'", "'Go back and choose an item'")
g('skillDetailSubtitle', "'查看并复制 Skill 文件'", "'View and copy skill files'")
g('promptDetailSubtitle', "'查看并使用 Prompt'", "'View and use this prompt'")
g('snippetDetailSubtitle', "'查看并复制常用文本'", "'View and copy this snippet'")
g('openInComposer', "'进入拼装'", "'Compose with it'")
g('copyContent', "'复制内容'", "'Copy content'")
f('sortLabel', 'ItemSortMode mode', """switch (mode) {
    ItemSortMode.smart => '智能排序',
    ItemSortMode.custom => '自定义',
    ItemSortMode.recentlyUsed => '最近使用',
    ItemSortMode.mostUsed => '最常使用',
    ItemSortMode.rating => '星级',
    ItemSortMode.recentlyUpdated => '最近修改',
    ItemSortMode.title => '名称',
  }""", """switch (mode) {
    ItemSortMode.smart => 'Smart',
    ItemSortMode.custom => 'Custom',
    ItemSortMode.recentlyUsed => 'Recently used',
    ItemSortMode.mostUsed => 'Most used',
    ItemSortMode.rating => 'Rating',
    ItemSortMode.recentlyUpdated => 'Recently modified',
    ItemSortMode.title => 'Name',
  }""")
g('chooseCategory', "'选择分类'", "'Choose category'")
f('usedTimes', 'int count', "'使用 $count 次'", "count == 1 ? 'Used once' : 'Used $count times'")
g('moreActions', "'更多操作'", "'More actions'")
g('editSkill', "'编辑 Skill'", "'Edit skill'")
g('moveUpInCustomOrder', "'在自定义排序中上移'", "'Move up in custom order'")
g('moveDownInCustomOrder', "'在自定义排序中下移'", "'Move down in custom order'")
g('clickCardForFullContent', "'点击卡片查看完整内容'", "'Click the card to see everything'")
g('ratingAllSemantic', "'显示全部星级'", "'Show all ratings'")
g('unrated', "'未评级'", "'Unrated'")
g('unratedOnlySemantic', "'只显示未评级'", "'Show unrated only'")
f('starsOrFewer', 'int stars', "'$stars 星及以下'",
  "stars == 1 ? '1 star or fewer' : '$stars stars or fewer'")
f('starCount', 'int stars', "'$stars 星'", "stars == 1 ? '1 star' : '$stars stars'")
g('clearRating', "'清除星级'", "'Clear rating'")
f('setRating', 'int stars', "'设置为 $stars 星'", "'Rate ${starCount(stars)}'")

section('Editor')
g('newSkill', "'新建 Skill'", "'New skill'")
g('newItem', "'收入新纸笺'", "'New item'")
g('editItem', "'编辑纸笺'", "'Edit item'")
g('editSkillSubtitle', "'修改 SKILL.md，保留辅助文件'", "'Edit SKILL.md; supporting files are kept'")
g('newSkillSubtitle', "'创建单文件 Skill'", "'Create a single-file skill'")
g('newItemSubtitle', "'创建 Prompt、Skill 或文本'", "'Create a prompt, skill or snippet'")
g('editItemSubtitle', "'修改名称、分类和内容'", "'Edit the name, category and content'")
g('skillTypeLocked', "'Skill 类型已锁定，避免转换时丢失完整文件包'",
  "\"The type is locked so the skill's full file package isn't lost\"")
g('creatingSingleFileSkill', "'正在新建单文件 Skill；多文件请使用导入入口'",
  "'Creating a single-file skill. For multiple files, use import instead'")
g('segmentSnippet', "'文本'", "'Snippet'")
g('skillNameLabel', "'Skill 名称'", "'Skill name'")
g('categoryOptionalLabel', "'分类（可选）'", "'Category (optional)'")
g('categoryHelper', "'只能选择当前模块已有分类'", "'Choose from the existing categories of this type'")
g('chooseExistingCategory', "'选择已有分类'", "'Choose an existing category'")
g('contentLabel', "'内容'", "'Content'")
g('skillEditHint', "'编辑 Skill 的入口说明；辅助文件不会被修改'",
  "\"Edit the skill's main instructions; supporting files aren't changed\"")
g('skillCreateHint', "'填写这个 Skill 的使用说明'", "'Describe how to use this skill'")
g('promptHint', "'需要插入原文的位置可写 {{input}}'", "'Write {{input}} where your text should go'")
g('snippetHint', "'支持 Markdown 文本'", "'Markdown is supported'")
g('deleteSkill', "'删除 Skill'", "'Delete skill'")
g('deleteItem', "'删除纸笺'", "'Delete item'")
g('createSkill', "'创建 Skill'", "'Create skill'")
g('saving', "'正在保存'", "'Saving…'")
g('saveToJianhe', "'收入笺盒'", "'Save to JianHe'")
g('saveChanges', "'保存修改'", "'Save changes'")
g('supportingFilesReadOnly', "'辅助文件（只读）'", "'Supporting files (read-only)'")
g('supportingFilesHint', "'展开查看；保存时原样保留'", "'Expand to view; kept as-is when you save'")
g('supportingFilesNoStorage', "'没有可读取的辅助文件仓库'", "'No supporting file storage is available'")
g('supportingFilesUnreadableKept', "'辅助文件暂时无法读取，保存时仍会原样保留'",
  "\"Supporting files can't be read right now; they're still kept as-is \"\n      'when you save'")
g('supportingFilesNone', "'此 Skill 没有辅助文件'", "'This skill has no supporting files'")

section('Skill package browser')
g('supportingFilesUnreadable', "'辅助文件暂时无法读取'", "\"Supporting files can't be read right now\"")
g('fileMissingOrUpdated', "'文件不存在或已被更新'", "\"The file doesn't exist or has been updated\"")
g('fileContentUnreadable', "'文件内容暂时无法读取'", "\"The file content can't be read right now\"")
g('noticeFileContentCopied', "'文件内容已复制'", "'File content copied'")
g('searchFilePaths', "'搜索文件路径'", "'Search file paths'")
g('noMatchingFiles', "'没有找到匹配的文件'", "'No matching files'")
g('fileList', "'文件列表'", "'File list'")
f('fileSize', 'String size', "'大小：$size'", "'Size: $size'")

section('More panel')
g('moreSubtitle', "'管理备份、快捷键和命令行'", "'Backups, hotkey and command line'")
g('cliAccessTitle', "'AI 命令行接口'", "'AI CLI access'")
g('cliAccessSubtitle', "'允许 Claude Code、Codex 等 AI 助手通过命令行读写笺盒技能。'",
  "'Let AI agents like Claude Code and Codex read and write your JianHe '\n      'library through the command line.'")
g('cliGuideTitle', "'AI 与 Skill 接入说明'", "'AI & Skill setup guide'")
g('cliGuideEntrySubtitle', "'了解 AI 如何调用笺盒 Skill，并导入自建或外部 Skill'",
  "'How AI uses your JianHe skills, and how to import your own or '\n      'third-party skills'")
g('cliGuidePanelSubtitle', "'让 AI 调用笺盒 Skill，或将自建、外部 Skill 导入笺盒'",
  "'Let AI use your JianHe skills, or import your own and third-party skills'")
g('exportAllTitle', "'导出全部内容'", "'Export everything'")
g('exportDisabled', "'本地数据库不可用，已停用备份导出'",
  "'The local database is unavailable, so export is turned off'")
g('exportSubtitle', "'生成 .jianhe 离线搬家包，不需要会员或云服务'",
  "'Create a .jianhe transfer file. No VIP or cloud service needed'")
g('importTransferTitle', "'导入离线备份'", "'Import transfer file'")
g('importDisabled', "'本地数据库不可用，已停用备份导入'",
  "'The local database is unavailable, so import is turned off'")
g('importSubtitle', "'安全合并 Prompt、Skills、文本、分类、星级和设置'",
  "'Safely merge prompts, skills, snippets, categories, ratings and settings'")
g('wakeHotKeyTitle', "'唤起快捷键'", "'Wake hotkey'")
f('hotKeyRegistered', 'String hotKey', "'$hotKey · 已注册'", "'$hotKey · Active'")
f('hotKeyRegistrationFailed', 'String hotKey', "'$hotKey · 注册失败'", "\"$hotKey · Couldn't register\"")
g('accountTitle', "'笺盒账号'", "'JianHe account'")
g('cloudConsoleTitle', "'云端信息管理'", "'Cloud console'")
g('cloudConsoleSubtitle', "'在浏览器中登录并管理已同步的内容'",
  "'Sign in from your browser to manage synced items'")
g('feedbackTitle', "'问题反馈'", "'Feedback'")
g('feedbackEntrySubtitle', "'用纯文字告诉我们遇到的问题或建议'",
  "'Tell us about a problem or an idea, in plain text'")
g('feedbackPanelSubtitle', "'纯文字反馈'", "'Plain-text feedback'")
g('feedbackNotConfigured', "'云服务未配置，暂时无法提交反馈。'",
  "\"The cloud service isn't set up, so feedback can't be sent right now.\"")
g('quitJianhe', "'退出笺盒'", "'Quit JianHe'")
# Bilingual on purpose: someone who installed the wrong language must still
# be able to find the switch.
g('languageTitle', "'界面语言 · Language'", "'Language · 界面语言'")
g('languageSubtitle', "'同时决定拼装分隔符的语言'", "'Also sets the language of the compose separator'")
f('noticeBrowserUnavailable', 'String url', "'无法打开浏览器，请访问 $url'",
  "\"Couldn't open your browser. Visit $url\"")
g('accountPanelSubtitleDisabled', "'本地存储不可用，云服务已停用'",
  "'Local storage is unavailable, so cloud services are turned off'")
g('accountPanelSubtitle', "'登录与 VIP 权益'", "'Sign-in and VIP'")
g('accountNotConfigured', "'云服务未配置'", "'Cloud service not set up'")
g('accountRestoring', "'正在恢复登录状态'", "'Restoring sign-in…'")
g('accountSignedOut', "'登录后可使用 VIP 云服务'", "'Sign in to use VIP cloud services'")
g('planReadOnlyGrace', "'只读宽限'", "'Read-only grace period'")
g('planFree', "'免费账号'", "'Free account'")
g('noticeCommandCopied', "'命令已复制'", "'Command copied'")
g('noticeAiRequestCopied', "'AI 请求已复制'", "'AI request copied'")
g('cliGuideFileName', "'笺盒-AI与Skill接入说明.md'", "'JianHe-AI-and-Skill-setup-guide.md'")
g('cliGuideExportDialogTitle', "'导出 AI 与 Skill 接入说明'", "'Export AI & Skill setup guide'")
g('cliGuideExportFilter', "'Markdown 文件 (*.md)|*.md|文本文件 (*.txt)|*.txt'",
  "'Markdown file (*.md)|*.md|Text file (*.txt)|*.txt'")
g('noticeCliGuideExported', "'已导出 AI 接入说明'", "'AI setup guide exported'")
g('autoCollapseTitle', "'自动收回'", "'Auto-collapse'")
g('autoCollapseSubtitle', "'鼠标移出展开内容后开始计时'", "'Starts when the pointer leaves the panel'")

section('App update')
g('updateCheck', "'检查更新'", "'Check for updates'")
f('updateCurrentVersion', 'String version', "'当前版本 $version'", "'Current version $version'")
g('updateChecking', "'正在检查更新…'", "'Checking for updates…'")
f('updateUpToDate', 'String version', "'已是最新版本（$version）'", "\"You're up to date ($version)\"")
f('updateAvailable', 'String? version', "'发现新版本 $version'", "'Version $version is available'")
f('updateAvailableHint', 'String version', "'当前版本 $version，点击后在后台下载'",
  "'Current version $version. Click to download in the background'")
f('updateDownloading', 'String? version', "'正在下载新版本 $version'", "'Downloading version $version'")
f('updateDownloadingHint', 'int percent', "'$percent% · 可以继续使用笺盒，下载完成后点击安装'",
  "'$percent% · Keep using JianHe, then click to install when it finishes'")
f('updateReady', 'String? version', "'新版本 $version 已下载，点击安装'",
  "'Version $version is downloaded. Click to install'")
g('updateReadyHint', "'安装时笺盒会自动关闭，完成后重新打开'",
  "'JianHe closes while installing and reopens when done'")
g('updateInstalling', "'正在启动安装…'", "'Starting the installer…'")
g('updateInstallingHint', "'笺盒即将关闭，安装完成后会自动重新打开'",
  "'JianHe is about to close and will reopen after installing'")
f('updateDownloadFailed', 'String? version', "'新版本 $version 下载失败'",
  "\"Couldn't download version $version\"")
g('updateCheckFailed', "'检查更新失败'", "\"Couldn't check for updates\"")
f('updateRetryHint', 'String? message', "'${message ?? '请稍后重试。'} 点击重试'",
  "'${message ?? 'Please try again later.'} Click to retry'")

# ---------------------------------------------------------------------------
# P1: account, sync, update, feedback
# ---------------------------------------------------------------------------

section('Account: sign in, register, reset')
g('accountRestoringProgress', "'正在恢复登录状态…'", "'Restoring sign-in…'")
g('resetPasswordTitle', "'重设密码'", "'Reset password'")
g('createAccountTitle', "'创建笺盒账号'", "'Create a JianHe account'")
g('signInTitle', "'登录笺盒账号'", "'Sign in to JianHe'")
g('resetPasswordIntro', "'向注册邮箱发送验证码，验证后设置新密码。'",
  "'We\\'ll email a code to your account address. Enter it to set a new password.'")
g('createAccountIntro', "'账号用于识别 VIP 权益，并在你的设备之间同步素材。'",
  "'Your account holds your VIP membership and syncs your items across devices.'")
g('signInIntro', "'登录后可查看账号与 VIP 状态。'",
  "'Sign in to see your account and VIP status.'")
g('emailLabel', "'邮箱'", "'Email'")
g('passwordLabel', "'密码'", "'Password'")
g('newPasswordLabel', "'新密码'", "'New password'")
g('passwordLengthHelper', "'10–128 个字符'", "'10–128 characters'")
g('showPassword', "'显示密码'", "'Show password'")
g('hidePassword', "'隐藏密码'", "'Hide password'")
g('pleaseWait', "'请稍候…'", "'Please wait…'")
g('registerAndSignIn', "'注册并登录'", "'Sign up and sign in'")
g('signIn', "'登录'", "'Sign in'")
g('backToSignIn', "'想起密码了？返回登录'", "'Remembered it? Back to sign-in'")
g('haveAccountSignIn', "'已有账号？直接登录'", "'Already have an account? Sign in'")
g('noAccountCreate', "'没有账号？创建一个'", "'No account? Create one'")
g('forgotPassword', "'忘记密码？'", "'Forgot password?'")
g('signInWithGoogle', "'使用 Google 登录'", "'Sign in with Google'")
g('cancelAuthorizationWait', "'取消授权等待'", "'Stop waiting for authorization'")
g('retryRestoreSignIn', "'重试恢复登录'", "'Retry restoring sign-in'")

section('Account: signed in')
g('thirdPartyAccount', "'第三方账号'", "'Third-party account'")
g('emailVerified', "'邮箱已验证'", "'Email verified'")
g('emailNotVerified', "'邮箱未验证'", "'Email not verified'")
g('privateBetaAccount', "'私测账号'", "'Private beta account'")
g('vipLifetimeActive', "'永久 VIP 已开通'", "'Lifetime VIP is active'")
g('vipActive', "'VIP 服务已开通'", "'VIP is active'")
g('vipExpiredGrace', "'VIP 已到期（只读宽限期）'", "'VIP expired (read-only grace period)'")
g('freeAccount', "'当前为免费账号'", "'Free account'")
g('vipActiveBody', "'素材和 Skill 会自动同步到你的其他设备。'",
  "'Your items and skills sync to your other devices automatically.'")
g('vipGraceBody', "'VIP 已到期：宽限期内仍可拉取云端已有数据。'",
  "'VIP has expired. During the grace period you can still download what\\'s in the cloud.'")
g('freeAccountBody', "'当前可以使用本地功能；云同步需要有效 VIP。'",
  "'All local features are available. Cloud sync requires VIP.'")
g('vipLifetimeDetail', "'永久有效'", "'Never expires'")
f('vipValidUntil', 'String date', "'有效期至 $date'", "'Valid until $date'")
g('renewVip', "'续费 / 升级 VIP'", "'Renew / upgrade VIP'")
g('getVip', "'开通 VIP'", "'Get VIP'")
g('linkGoogleAccount', "'绑定 Google 账号'", "'Link Google account'")
g('refreshAccount', "'刷新账号状态'", "'Refresh account status'")
g('signOut', "'退出登录'", "'Sign out'")
g('deleteAccount', "'注销账号'", "'Delete account'")
g('accountSecurity', "'账号安全'", "'Account security'")
g('emailNotVerifiedHint', "'邮箱尚未验证。验证后才能用邮箱找回密码。'",
  "'Your email isn\\'t verified yet. Verify it to be able to reset your password by email.'")
g('verifyEmail', "'验证邮箱'", "'Verify email'")
g('changePassword', "'修改密码'", "'Change password'")
g('cloudNotConfiguredTitle', "'云服务未配置'", "'Cloud service not set up'")
g('cloudNotConfiguredBody', "'请使用包含正式 API 地址的 Windows 安装包。'",
  "'Use a Windows installer that includes the production API address.'")
g('planBadgeReadOnly', "'只读'", "'Read-only'")
g('planBadgeFree', "'免费'", "'Free'")

section('Account: sync card')
g('syncStatusNeedsVip', "'开通 VIP 后，素材和 Skill 会自动同步到你的其他设备。'",
  "'With VIP, your items and skills sync to your other devices automatically.'")
g('syncStatusGrace', "'VIP 已到期，仍可将云端内容同步到本机。'",
  "'VIP has expired. You can still download your cloud content to this PC.'")
g('syncStatusUpdating', "'正在更新你的内容…'", "'Updating your items…'")
f('syncStatusPending', 'int count', "'有 $count 项内容等待同步。'",
  "count == 1 ? '1 item is waiting to sync.' : '$count items are waiting to sync.'")
f('syncStatusUpdated', 'int count, String time', "'已更新 $count 项内容 · $time'",
  "'Updated ${countItems(count)} · $time'")
f('syncStatusSynced', 'String time', "'内容已同步 · $time'", "'Up to date · $time'")
g('syncStatusAuto', "'你的内容会自动同步到其他设备。'", "'Your items sync to your other devices automatically.'")
g('syncStatusManual', "'自动同步已关闭，可随时手动同步。'", "'Auto sync is off. You can sync manually at any time.'")
g('multiDeviceSync', "'多设备同步'", "'Sync across devices'")
g('syncBadgeRestoreOnly', "'仅可恢复'", "'Download only'")
g('syncBadgeVipOnly', "'VIP 专享'", "'VIP only'")
g('autoSync', "'自动同步'", "'Auto sync'")
g('syncNow', "'现在同步'", "'Sync now'")
g('syncFrequency', "'同步频率'", "'Sync frequency'")
f('everyMinutes', 'int minutes', "'每 $minutes 分钟'", "'Every $minutes minutes'")
g('everyHour', "'每 1 小时'", "'Every hour'")
g('dailyAtTime', "'每天定时'", "'Daily at a set time'")
f('dailyAt', 'String time', "'每天 $time'", "'Daily at $time'")
f('nextSync', 'String time', "'下次同步：$time'", "'Next sync: $time'")
g('downloadCloudContent', "'获取云端内容'", "'Download cloud content'")
g('chooseSyncTime', "'选择同步时间'", "'Choose a sync time'")
g('ok', "'确定'", "'OK'")

section('Account: security dialogs')
g('emailCodeLabel', "'邮箱验证码'", "'Email code'")
g('sendingCode', "'发送中…'", "'Sending…'")
f('resendInSeconds', 'int seconds', "'$seconds 秒后重发'", "'Resend in ${seconds}s'")
g('getCode', "'获取验证码'", "'Get code'")
g('passwordsDoNotMatch', "'两次输入的新密码不一致。'", "'The new passwords don\\'t match.'")
g('changePasswordIntro', "'修改后，当前设备保持登录，其他设备需要用新密码重新登录。'",
  "'This PC stays signed in. Your other devices will need to sign in again with the new password.'")
g('currentPasswordLabel', "'当前密码'", "'Current password'")
g('repeatNewPasswordLabel', "'再次输入新密码'", "'Repeat new password'")
g('confirmChange', "'确认修改'", "'Change password'")
f('verifyEmailIntro', 'String email', "'验证码将发送到 $email。验证后可以用这个邮箱找回密码。'",
  "'We\\'ll send a code to $email. Once verified, you can use this address to reset your password.'")
g('verify', "'验证'", "'Verify'")
g('deleteAccountWarning',
  "'注销后将立即永久删除：账号与登录信息、云端同步的全部素材和 Skill、'\n      'VIP 权益（含未到期时长）以及订单和反馈记录，无法恢复。\\n'\n      '本机已有的素材不会被删除。'",
  "'Deleting your account immediately and permanently removes your account '\n      'and sign-in details, every item and skill synced to the cloud, your VIP '\n      'membership (including remaining time), and your order and feedback '\n      'history. This can\\'t be undone.\\nItems on this PC are not deleted.'")
g('confirmWithCurrentPassword', "'输入当前密码确认'", "'Enter your current password to confirm'")
g('useEmailCodeInstead', "'没有密码或忘记密码？改用邮箱验证码'", "'No password or forgot it? Use an email code instead'")
f('codeWillBeSentTo', 'String email', "'验证码将发送到 $email。'", "'We\\'ll send a code to $email.'")
g('usePasswordInstead', "'改用密码确认'", "'Use your password instead'")
g('deleteAccountAcknowledge', "'我已了解注销后数据和 VIP 权益无法恢复'",
  "'I understand my data and VIP membership can\\'t be recovered'")
g('deleteAccountPermanently', "'永久注销账号'", "'Delete account permanently'")

section('Account: session messages')
g('authorizationExpired', "'授权已过期，请重试。'", "'The authorization expired. Please try again.'")
g('signInCancelled', "'已取消登录。'", "'Sign-in cancelled.'")
g('emailCodeRequired', "'请先获取并填写邮箱验证码。'", "'Get an email code and enter it first.'")
g('emailCodeUnsupported', "'当前版本不支持邮箱验证码。'", "'This version doesn\\'t support email codes.'")
f('codeSent', 'String email, int minutes',
  "'验证码已发送到 $email，$minutes 分钟内有效。'\n      '没收到请检查垃圾邮件。'",
  "'Code sent to $email. It\\'s valid for $minutes minutes. '\n      'If it doesn\\'t arrive, check your spam folder.'")
g('passwordResetUnsupported', "'当前版本不支持找回密码。'", "'This version doesn\\'t support password reset.'")
g('enterEmailCode', "'请填写邮件中的验证码。'", "'Enter the code from the email.'")
g('passwordResetDone', "'密码已重设，请用新密码登录。其他设备需要重新登录。'",
  "'Your password has been reset. Sign in with the new password; your other devices will need to sign in again.'")
g('signInFirst', "'请先登录。'", "'Please sign in first.'")
g('emailVerifiedDone', "'邮箱已验证。'", "'Your email is verified.'")
g('enterCurrentPassword', "'请填写当前密码。'", "'Enter your current password.'")
g('passwordChangedDone', "'密码已修改。其他设备需要用新密码重新登录。'",
  "'Password changed. Your other devices will need to sign in again with the new password.'")
g('tryAgainShortly', "'请稍候再试。'", "'Please try again in a moment.'")
g('accountDeletedWithCloud', "'账号已注销，云端数据已删除。本机数据仍然保留。'",
  "'Your account and cloud data have been deleted. Data on this PC is kept.'")
g('accountDeleted', "'账号已注销。'", "'Account deleted.'")
g('signedOutStorageFailed', "'已退出当前界面，但安全存储清理失败，请重启后再次退出。'",
  "'Signed out here, but secure storage couldn\\'t be cleared. Restart JianHe and sign out again.'")
g('signedOutRemoteFailed', "'已退出本机；云端撤销暂时失败，令牌将在到期后失效。'",
  "'Signed out on this PC. The cloud couldn\\'t revoke the session right now; it will expire on its own.'")
g('signedOutSafely', "'已安全退出账号。'", "'Signed out.'")
g('sessionExpired', "'登录状态已失效，请重新登录。'", "'Your session has expired. Please sign in again.'")
g('credentialFailure', "'账号凭证处理失败，请重试。'", "'Something went wrong with your sign-in details. Please try again.'")
g('invalidEmail', "'请输入有效的邮箱地址，例如 name@example.com。'",
  "'Enter a valid email address, for example name@example.com.'")
f('passwordLength', 'int min, int max', "'密码长度需为 $min–$max 个字符。'",
  "'Passwords must be $min–$max characters.'")
f('newPasswordLength', 'int min, int max', "'新密码长度需为 $min–$max 个字符。'",
  "'New passwords must be $min–$max characters.'")
g('enterPassword', "'请输入密码。'", "'Enter your password.'")
f('passwordTooLong', 'int max', "'密码不能超过 $max 个字符。'", "'Passwords can be up to $max characters.'")
g('googleAccount', "'Google 账号'", "'Google account'")
g('jianheAccount', "'笺盒账号'", "'JianHe account'")
g('browserUnavailable', "'无法打开系统默认浏览器，请检查 Windows 默认浏览器设置。'",
  "'Couldn\\'t open your default browser. Check the default browser setting in Windows.'")

section('Cloud service errors raised by the client')
g('cloudTimeout', "'连接云服务超时，请检查网络后重试。'",
  "'The connection to the cloud service timed out. Check your network and try again.'")
g('cloudUnreachable', "'暂时无法连接云服务，请检查网络。'",
  "'Can\\'t reach the cloud service right now. Check your network.'")
g('cloudBadResponse', "'云服务返回了无法识别的数据。'", "'The cloud service returned data JianHe couldn\\'t read.'")
g('cloudUnavailable', "'云服务暂时不可用，请稍后重试。'",
  "'The cloud service is temporarily unavailable. Please try again later.'")
g('syncServiceUnavailable', "'云同步服务暂时不可用，请稍后重试。'",
  "'The sync service is temporarily unavailable. Please try again later.'")
g('syncServiceTimeout', "'连接云同步服务超时，请检查网络后重试。'",
  "'The connection to the sync service timed out. Check your network and try again.'")
g('syncServiceUnreachable', "'暂时无法连接云同步服务，请检查网络。'",
  "'Can\\'t reach the sync service right now. Check your network.'")
g('syncServiceBadResponse', "'云同步服务返回了无法识别的数据。'",
  "'The sync service returned data JianHe couldn\\'t read.'")
g('skillBlobMismatch', "'下载的 Skill 包校验不一致。'", "'The downloaded skill package failed its integrity check.'")
g('feedbackTimeout', "'提交反馈超时，请检查网络后重试。'",
  "'Sending feedback timed out. Check your network and try again.'")
g('feedbackUnsupported', "'当前云服务版本暂不支持问题反馈。'", "'This version of the cloud service doesn\\'t accept feedback yet.'")
g('feedbackFailed', "'反馈提交失败，请稍后重试。'", "'Couldn\\'t send your feedback. Please try again later.'")

section('Cloud sync')
g('syncInProgress', "'增量同步正在进行中，请稍候。'", "'A sync is already running. Please wait.'")
f('syncQuotaUsage', 'String used, String max', "'（已用 $used / $max）'", "' ($used of $max used)'")
f('syncQuotaFull', 'String usage, int held',
  "'云同步空间已满$usage，有 $held 项修改暂未上传。'\n      '删除不需要的内容（例如较大的 Skill 包）后会自动继续同步，本地数据不受影响。'",
  "'Your cloud sync space is full$usage, so ${countItems(held)} '\n      'haven\\'t been uploaded. Delete things you don\\'t need (such as large skill '\n      'packages) and sync continues automatically. Your local data is safe.'")
g('syncUnconfirmed', "'部分修改未能确认推送结果，将在下次同步重试。'",
  "'Some changes couldn\\'t be confirmed; they\\'ll be retried on the next sync.'")
g('syncStorageBusy', "'云端正在整理同步空间，部分 Skill 包将在下次同步时上传。'",
  "'The cloud is tidying up sync storage; some skill packages will upload on the next sync.'")
g('syncRequestInvalid', "'同步请求无效'", "'invalid sync request'")
g('syncServerLimit', "'超出服务器限制'", "'over the server limit'")
f('syncSkillRejected', 'String title, String reason',
  "'Skill「$title」的文件包上传被服务器拒绝'\n      '（$reason），'\n      '已保留待下次同步；其他内容照常同步，本地数据未受影响。'",
  "'The server refused the package of skill “$title” ($reason). It\\'s kept for '\n      'the next sync; everything else syncs as usual and local data is safe.'")
f('syncSkillTooLarge', 'String title, int limitMiB',
  "'Skill「$title」的文件包超过云同步单个上限'\n      '（$limitMiB MiB），'\n      '无法同步到云端，只保存在本机。'",
  "'The package of skill “$title” is over the $limitMiB MiB cloud sync limit, '\n      'so it stays on this PC and won\\'t sync.'")
f('syncSkillShelved', 'String title, String reason',
  "'Skill「$title」的文件包无法上传'\n      '（$reason），'\n      '已搁置；本地数据未受影响。'",
  "'The package of skill “$title” can\\'t be uploaded ($reason). It\\'s been set '\n      'aside; local data is safe.'")
f('syncNoPushResult', 'String id', "'服务器未返回 $id 的推送结果，已保留待重试。'",
  "'The server didn\\'t confirm $id; it\\'s kept for retry.'")
f('syncBatchShelved', 'String reason', "'该批修改无法同步（$reason），已搁置；本地数据未受影响。'",
  "'This batch of changes can\\'t sync ($reason) and has been set aside; local data is safe.'")
g('syncAllRejected',
  "'同步请求无效。所有修改都被服务器拒绝，常见原因：本机时钟快于标准时间 5 分钟以上，'\n      '请校准系统时间后重试。'",
  "'The server rejected every change. This usually means this PC\\'s clock is '\n      'more than 5 minutes fast. Correct the system time and try again.'")
f('syncRecordRestamped', 'String record',
  "'记录 $record 的时间戳晚于服务器时间'\n      '（本机时钟此前可能偏快），已校正后同步。'",
  "'$record was timestamped later than the server time (this PC\\'s clock may '\n      'have been fast); it was corrected and synced.'")
f('syncRecordSkipped', 'String record',
  "'服务器拒绝了记录 $record（同步请求无效），已跳过；'\n      '本地数据不受影响，其他内容照常同步。'",
  "'The server rejected $record (invalid sync request), so it was skipped. '\n      'Local data is safe and everything else syncs as usual.'")
f('syncRecordSkillPackage', 'String id', "'Skill 包 $id'", "'skill package $id'")
f('syncRecordCategory', 'String id', "'分类「$id」'", "'category “$id”'")
f('syncRecordItem', 'String id', "'条目 $id'", "'item $id'")
f('syncRecordItemTitled', 'String title, String id', "'条目「$title」（$id）'", "'item “$title” ($id)'")
f('syncSkipUnparsable', 'String id, String detail', "'跳过无法解析的远端记录 $id：$detail'",
  "'Skipped remote record $id that couldn\\'t be read: $detail'")
f('syncSkipInvalid', 'String id, String detail', "'跳过内容无效的远端记录 $id：$detail'",
  "'Skipped remote record $id with invalid content: $detail'")
f('syncSkipMissingFields', 'String id', "'跳过字段缺失的远端记录 $id。'",
  "'Skipped remote record $id with missing fields.'")
f('syncSkipOldPackage', 'String id', "'跳过 Skill 包 $id 的旧版本：云端已不再保存该版本文件。'",
  "'Skipped an old version of skill package $id; the cloud no longer stores it.'")
f('syncSkipOrphanPackage', 'String id', "'Skill 包 $id 的宿主条目不存在，已跳过。'",
  "'Skipped skill package $id because its item doesn\\'t exist.'")
g('syncGenericFailure', "'同步遇到问题，请稍后重试。'", "'Sync ran into a problem. Please try again later.'")
g('syncNeedsSignIn', "'登录后才能使用多设备同步。'", "'Sign in to sync across devices.'")
g('syncNeedsVip', "'开通 VIP 后即可使用多设备同步。'", "'Sync across devices requires VIP.'")
g('syncPartialFailure', "'部分内容未能更新，请稍后重试。'", "'Some items couldn\\'t be updated. Please try again later.'")
g('syncCancelled', "'同步已取消。'", "'Sync cancelled.'")
g('syncBusy', "'正在同步，请稍候。'", "'Syncing, please wait.'")
g('syncVipExpired', "'VIP 已到期，暂时无法将新内容同步到云端。'",
  "'VIP has expired, so new changes can\\'t be uploaded to the cloud.'")
g('syncDataMalformed', "'同步数据格式异常，请稍后重试。'", "'The sync data was malformed. Please try again later.'")
g('syncScheduleUnavailable', "'系统定时同步暂时无法启用。'", "'Scheduled sync can\\'t be turned on right now.'")
g('syncWebUnsupported', "'Web 开发版不支持本地云同步。'", "'The web development build doesn\\'t support local cloud sync.'")

section('App update messages')
g('updateCheckFailedShort', "'检查更新失败'", "'Couldn\\'t check for updates'")
g('updateDownloadFailedShort', "'下载更新失败'", "'Couldn\\'t download the update'")
g('updateWaitForSync', "'正在同步，请等同步完成后再安装。'",
  "'A sync is running. Install once it finishes.'")
g('updateWaitForCli', "'AI 助手正在使用 jianhe 命令行，请等它执行完再安装。'",
  "'An AI agent is using the jianhe CLI. Install once it\\'s done.'")
g('updateInstallerDamaged', "'安装包已损坏或被移除，请重新下载。'",
  "'The installer is damaged or missing. Please download it again.'")
g('updateCannotLaunchShort', "'无法启动安装程序'", "'Couldn\\'t start the installer'")
f('updateCheckNetwork', 'String fallback', "'$fallback，请检查网络后重试。'",
  "'$fallback. Check your network and try again.'")
g('updateCheckTimeout', "'检查更新超时，请检查网络后重试。'",
  "'Checking for updates timed out. Check your network and try again.'")
g('updateServerUnreachable', "'无法连接更新服务器，请检查网络后重试。'",
  "'Can\\'t reach the update server. Check your network and try again.'")
f('updateServerUnavailable', 'int status', "'更新服务器暂时不可用（$status），请稍后重试。'",
  "'The update server is temporarily unavailable ($status). Please try again later.'")
g('updateManifestInvalid', "'更新信息格式不正确，请稍后重试。'",
  "'The update information is malformed. Please try again later.'")
g('updateDownloadUnreachable', "'无法连接下载服务器，请检查网络后重试。'",
  "'Can\\'t reach the download server. Check your network and try again.'")
f('updateDownloadUnavailable', 'int status', "'下载服务器暂时不可用（$status），请稍后重试。'",
  "'The download server is temporarily unavailable ($status). Please try again later.'")
g('updateSizeMismatch', "'下载的安装包大小与发布信息不符，已停止下载。'",
  "'The downloaded installer\\'s size doesn\\'t match the release, so the download was stopped.'")
g('updateDownloadInterrupted', "'下载中断，请检查网络后重试。'",
  "'The download was interrupted. Check your network and try again.'")
g('updateChecksumFailed', "'安装包校验失败，已删除，请重新下载。'",
  "'The installer failed verification and was deleted. Please download it again.'")
g('updateWindowsOnly', "'自动更新仅支持 Windows。'", "'Automatic updates are only available on Windows.'")
g('updateCannotLaunch', "'无法启动安装程序，请稍后重试。'", "'Couldn\\'t start the installer. Please try again later.'")

section('Feedback')
g('feedbackSignInTitle', "'登录后提交问题反馈'", "'Sign in to send feedback'")
g('feedbackSignInBody', "'普通账号也可以提交，不需要 VIP。'", "'Any account can send feedback; VIP isn\\'t required.'")
g('goToAccount', "'前往笺盒账号'", "'Go to JianHe account'")
g('feedbackSentTitle', "'反馈提交成功'", "'Feedback sent'")
g('feedbackSentBody', "'感谢你的反馈，我们会尽快查看。'", "'Thanks for your feedback. We\\'ll take a look soon.'")
g('sendMoreFeedback', "'继续反馈'", "'Send more feedback'")
g('feedbackIntro', "'请描述你遇到的问题或建议。首版仅支持纯文字，不会自动上传本地内容或日志。'",
  "'Describe a problem or an idea. Plain text only; your local items and logs are never uploaded automatically.'")
g('feedbackHint', "'请输入问题描述…'", "'Describe the problem…'")
f('feedbackTooLong', 'int max', "'内容不能超过 $max 个字符'", "'Feedback can be up to $max characters'")
g('submitting', "'正在提交…'", "'Sending…'")
g('submitFeedback', "'提交反馈'", "'Send feedback'")
f('feedbackLengthRange', 'int max', "'请输入 1–$max 个字符的问题描述。'",
  "'Enter a description of 1–$max characters.'")

section('Cloud console (web)')
g('portalTitle', "'笺盒云端管理'", "'JianHe Cloud'")
g('portalCloudBadge', "'云端'", "'Cloud'")
g('portalAdminUnavailable', "'管理功能不可用。'", "'Administration isn\\'t available.'")
g('portalAdminTitle', "'系统管理'", "'Administration'")
g('portalNoAdmin', "'没有管理员权限。'", "'You don\\'t have administrator access.'")
g('portalRestoring', "'正在恢复云端登录状态…'", "'Restoring your cloud sign-in…'")
g('portalSignInTitle', "'登录云端管理'", "'Sign in to JianHe Cloud'")
g('portalSignInIntro', "'查看并管理同步到笺盒云端的内容'", "'View and manage what you\\'ve synced to JianHe Cloud'")
g('portalResetting', "'正在重设…'", "'Resetting…'")
g('portalSigningIn', "'正在登录…'", "'Signing in…'")
g('portalSignInNote', "'此页面只管理已同步到云端的内容。在当前浏览器登录后即可访问。'",
  "'This page only manages content synced to the cloud. Sign in with this browser to use it.'")
g('portalBackToLanding', "'返回笺盒官网'", "'Back to the JianHe website'")
g('portalIntroEyebrow', "'JIANHE CLOUD · 跨设备素材库'", "'JIANHE CLOUD · YOUR LIBRARY, EVERYWHERE'")
g('portalIntroHeadline1', "'换一台电脑，'", "'New computer,'")
g('portalIntroHeadline2', "'素材还在这里。'", "'same library.'")
g('portalIntroBody', "'登录后即可在浏览器里查看、整理同步到云端的 Prompt、Skills 与常用文本。'\n      '在这里做的修改，会自动同步回每一台登录的 Windows 电脑。'",
  "'Sign in to view and organize the prompts, skills and snippets you\\'ve synced, right in your browser. '\n      'Changes made here sync back to every Windows PC you\\'re signed in on.'")
g('portalIntroPoint1', "'Prompt、Skills、常用文本一处查看'", "'Prompts, skills and snippets in one place'")
g('portalIntroPoint2', "'网页修改，客户端自动增量同步'", "'Edit on the web; the app syncs the changes'")
g('portalIntroPoint3', "'分类、星级与完整 Skill 包一起管理'", "'Manage categories, ratings and full skill packages'")
g('portalWebsite', "'笺盒官网'", "'JianHe website'")
g('portalSignOut', "'退出登录'", "'Sign out'")
g('portalLanguageTooltip', "'切换语言'", "'Change language'")
g('portalSkillPackages', "'Skill 包管理'", "'Skill packages'")
g('portalNoSkillPackages', "'还没有同步到云端的 Skill 包。'", "'No skill packages have been synced yet.'")
g('portalDeleteTitle', "'删除云端数据？'", "'Delete from the cloud?'")
f('portalDeleteBody', 'String title', "'“$title”将进入同步删除流程，其他已登录设备同步后也会删除对应内容。'",
  "'“$title” will be deleted. Your other signed-in devices will delete it too when they sync.'")
g('portalConfirmDelete', "'确认删除'", "'Delete'")
g('portalOverviewEyebrow', "'CLOUD LIBRARY · 已同步到云端'", "'CLOUD LIBRARY · SYNCED'")
g('portalOverviewTitle', "'我的云端资料库'", "'My cloud library'")
g('portalOverviewBody', "'修改会通过同步流传递到 Windows 客户端，在这里新建、编辑或删除的内容，'\n      '其他登录的电脑同步后会自动更新。'",
  "'Changes flow to the Windows app through sync. Anything you create, edit or delete here '\n      'updates on your other signed-in PCs the next time they sync.'")
g('portalMetricItems', "'素材'", "'Items'")
g('portalMetricCategories', "'分类'", "'Categories'")
g('portalMetricPackages', "'Skill 包'", "'Skill packages'")
g('portalQuota', "'云端同步空间'", "'Cloud sync storage'")
g('portalFilterAll', "'全部素材'", "'All items'")
g('portalSearchHint', "'搜索标题、正文或分类'", "'Search titles, content or categories'")
g('portalRefresh', "'刷新'", "'Refresh'")
g('portalNewItem', "'新建素材'", "'New item'")
g('portalManageCategories', "'分类管理'", "'Categories'")
g('portalCategoryKicker', "'分类'", "'Category'")
g('portalAllCategories', "'全部分类'", "'All categories'")
f('portalLibraryCount', 'int count', "'云端素材 · $count'", "'Cloud items · $count'")
f('portalSearchCount', 'int count', "'搜索结果 · $count'", "'Search results · $count'")
g('portalRecentFirst', "'按最近更新'", "'Recently updated'")
g('portalNoContent', "'（无正文）'", "'(No content)'")
g('portalEmptyTitle', "'没有找到云端内容'", "'Nothing in the cloud yet'")
g('portalEmptyBody', "'可以新建素材，或先在 Windows 客户端执行同步。'",
  "'Create an item here, or sync from the Windows app first.'")
g('portalEmptyCreate', "'新建一条素材'", "'Create an item'")
g('portalFooterNote', "'© 2026 笺盒 JianHe · 云端修改会同步到你登录的每一台设备'",
  "'© 2026 JianHe · Cloud changes sync to every device you\\'re signed in on'")
g('portalFooterLanding', "'笺盒官网 · 下载 Windows 版 ↗'", "'JianHe website · Download for Windows ↗'")
f('portalDeleteCategoryTitle', 'String name', "'删除分类“$name”？'", "'Delete the category “$name”?'")
g('portalDeleteEmptyCategoryBody', "'其他登录的设备同步后也会删除这个分类。'",
  "'Your other signed-in devices will delete this category too when they sync.'")
f('portalDeleteCategoryBody', 'int count', "'其中 $count 条素材会保留，并移动到未分类。其他登录的设备同步后也会删除这个分类。'",
  "'${count == 1 ? 'Its 1 item is' : 'Its $count items are'} kept and moved to Uncategorized. Your other signed-in devices will delete this category too when they sync.'")
g('portalDeleteCategory', "'删除分类'", "'Delete category'")
f('portalNewCategoryHint', 'String type', "'新的 $type 分类名称'", "'New $type category name'")
g('portalCreate', "'新建'", "'Create'")
f('portalNoCategories', 'String type', "'$type 还没有分类，在上方输入名称新建。'",
  "'No $type categories yet. Enter a name above to create one.'")
g('portalCategoriesNote', "'素材只能选择这里已有的分类。删除分类不会删除素材，它们会移动到未分类。'",
  "'Items can only use categories listed here. Deleting a category keeps its items and moves them to Uncategorized.'")
f('portalCategoryItemCount', 'int count', "count == 0 ? '暂无素材' : '$count 条素材'",
  "count == 0 ? 'No items' : count == 1 ? '1 item' : '$count items'")
g('portalSave', "'保存'", "'Save'")
g('portalViewOrEdit', "'查看或编辑'", "'View or edit'")
f('portalTitleInvalid', 'int max', "'标题不能为空，且不超过 $max 个字符'", "'Enter a title of up to $max characters'")
f('portalContentInvalid', 'int max', "'内容不能为空，且不超过 $max 个字符'", "'Enter content of up to $max characters'")
f('portalCategoryInvalid', 'int max', "'分类名需为 1–$max 个字符，且不能包含控制字符'",
  "'Category names must be 1–$max characters with no control characters'")
g('portalCheckFields', "'请检查标题、内容和分类后重试'", "'Check the title, content and category, then try again'")
g('portalCannotSave', "'内容无法保存，请检查后重试'", "'This item couldn\\'t be saved. Check it and try again'")
g('portalNewItemTitle', "'新建云端素材'", "'New cloud item'")
g('portalEditItemTitle', "'编辑云端素材'", "'Edit cloud item'")
g('portalTypeLabel', "'类型'", "'Type'")
g('portalTitleLabel', "'标题'", "'Title'")
f('portalNoCategoriesForType', 'String type', "'$type 还没有分类，可在「分类管理」中新建。'",
  "'No $type categories yet. Create one under Categories.'")
g('portalNeedCategory', "'需要新分类？请在「分类管理」中新建。'", "'Need a new category? Create it under Categories.'")
g('portalSaveToCloud', "'保存到云端'", "'Save to cloud'")
g('portalManageSkillPackage', "'管理 Skill 包'", "'Manage skill package'")
g('portalSkillPackageLoadFailed', "'Skill 包载入失败，请关闭后重试。'", "'The skill package couldn\\'t be loaded. Close this and try again.'")
g('portalSupportFiles', "'辅助文件'", "'Supporting files'")
g('portalAddTextFile', "'添加文本文件'", "'Add text file'")
g('portalNoSupportFiles', "'此 Skill 包没有辅助文件。'", "'This skill package has no supporting files.'")
g('portalSavePackage', "'保存整包'", "'Save package'")
g('portalRelativePath', "'相对路径'", "'Relative path'")
g('portalMediaType', "'媒体类型'", "'Media type'")
g('portalDeleteFile', "'删除文件'", "'Delete file'")
g('portalFileContent', "'文件内容'", "'File content'")
g('portalBinaryFileNote', "'二进制文件仅保留原内容；可以修改路径、媒体类型或删除。'",
  "'Binary files keep their original content; you can change the path or media type, or delete them.'")
f('portalCategoryOf', 'String type', "'$type 分类'", "'$type category'")
g('portalSkillPackage', "'Skill 包'", "'Skill package'")
g('portalUntitledPackage', "'未命名 Skill 包'", "'Untitled skill package'")
f('portalSkippedRecords', 'int count', "'有 $count 条云端记录格式异常，已安全跳过。'",
  "count == 1 ? '1 cloud record was malformed and skipped.' : '$count cloud records were malformed and skipped.'")
g('portalDataMalformed', "'云端数据格式异常，请稍后重试。'", "'The cloud data is malformed. Please try again later.'")
g('portalPackageIncomplete', "'Skill 包数据不完整，无法保存到云端。'", "'The skill package is incomplete and can\\'t be saved to the cloud.'")
f('portalCategoryNameInvalid', 'int max', "'分类名称需为 1–$max 个字符，且不能包含控制字符。'",
  "'Category names must be 1–$max characters with no control characters.'")
f('portalCategoryExists', 'String name', "'分类“$name”已存在。'", "'The category “$name” already exists.'")
g('portalPackageUnreadable', "'Skill 包内容无法解析。'", "'The skill package couldn\\'t be read.'")
g('portalPackageSkillMissing', "'Skill 包对应的 Skill 素材不存在，无法保存。'",
  "'The skill this package belongs to no longer exists, so it can\\'t be saved.'")
g('portalVipRequired', "'修改云端数据需要有效 VIP。'", "'Changing cloud data needs an active VIP membership.'")
g('portalPackageSaveFailed', "'Skill 包保存失败。'", "'The skill package couldn\\'t be saved.'")
g('portalSaveInProgress', "'已有保存操作正在进行，请稍候。'", "'Another save is in progress. Please wait.'")
g('portalSessionExpired', "'网页登录状态已失效，请重新登录。'", "'Your web sign-in has expired. Please sign in again.'")
g('portalNothingToSave', "'没有需要保存的修改。'", "'There are no changes to save.'")
g('portalConflictReloaded', "'云端已有更新版本，页面已重新载入。'", "'The cloud has a newer version; the page was reloaded.'")
f('portalPartialPush', 'int pushed, int total', "'已推送 $pushed/$total 条修改，剩余部分未保存，请重试。'",
  "'Saved $pushed of $total changes; the rest weren\\'t saved. Please try again.'")
g('portalSaveFailed', "'保存失败，请稍后重试。'", "'Couldn\\'t save. Please try again later.'")
