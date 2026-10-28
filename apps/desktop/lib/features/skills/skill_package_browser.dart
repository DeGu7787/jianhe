import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jianhe_core/jianhe_core.dart';

import '../../l10n/app_strings.dart';

class SkillPackageBrowser extends StatefulWidget {
  const SkillPackageBrowser({
    super.key,
    required this.skill,
    required this.repository,
    required this.onNotice,
  });

  final JianheItem skill;
  final SkillPackageRepository? repository;
  final ValueChanged<String> onNotice;

  @override
  State<SkillPackageBrowser> createState() => _SkillPackageBrowserState();
}

class _SkillPackageBrowserState extends State<SkillPackageBrowser> {
  final _searchController = TextEditingController();
  List<SkillFileMetadata> _files = const <SkillFileMetadata>[];
  SkillFileMetadata? _selected;
  Uint8List? _selectedBytes;
  bool _loadingFiles = true;
  bool _loadingContent = false;
  String? _filesError;
  String? _contentError;
  int _contentRequest = 0;

  SkillFileMetadata get _entrypoint => SkillFileMetadata(
    relativePath: SkillPackage.defaultEntrypoint,
    mediaType: 'text/markdown',
    byteLength: utf8.encode(widget.skill.content).length,
    contentHash: widget.skill.contentHash,
  );

  List<SkillFileMetadata> get _visibleFiles {
    final query = _searchController.text.trim().toLowerCase();
    final files = <SkillFileMetadata>[_entrypoint, ..._files];
    if (query.isEmpty) return files;
    return files
        .where((file) => file.relativePath.toLowerCase().contains(query))
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshSearch);
    _loadFiles();
  }

  @override
  void didUpdateWidget(covariant SkillPackageBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.skill.id != widget.skill.id ||
        oldWidget.repository != widget.repository) {
      _selected = null;
      _selectedBytes = null;
      _searchController.clear();
      _loadFiles();
    }
  }

  @override
  void dispose() {
    _contentRequest++;
    _searchController
      ..removeListener(_refreshSearch)
      ..dispose();
    super.dispose();
  }

  void _refreshSearch() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFiles() async {
    setState(() {
      _loadingFiles = true;
      _filesError = null;
    });
    try {
      final files =
          await widget.repository?.listFiles(widget.skill.id) ??
          const <SkillFileMetadata>[];
      if (!mounted) return;
      setState(() {
        _files = files;
        _loadingFiles = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _files = const <SkillFileMetadata>[];
        _filesError = AppStrings.current.supportingFilesUnreadable;
        _loadingFiles = false;
      });
    }
  }

  Future<void> _openFile(SkillFileMetadata metadata) async {
    final request = ++_contentRequest;
    setState(() {
      _selected = metadata;
      _selectedBytes = null;
      _contentError = null;
      _loadingContent = metadata.relativePath != SkillPackage.defaultEntrypoint;
    });
    if (metadata.relativePath == SkillPackage.defaultEntrypoint) {
      setState(
        () => _selectedBytes = Uint8List.fromList(
          utf8.encode(widget.skill.content),
        ),
      );
      return;
    }

    try {
      final file = await widget.repository?.readFile(
        widget.skill.id,
        metadata.relativePath,
      );
      if (!mounted || request != _contentRequest) return;
      setState(() {
        _loadingContent = false;
        if (file == null) {
          _contentError = AppStrings.current.fileMissingOrUpdated;
        } else {
          _selectedBytes = file.content;
        }
      });
    } on Object {
      if (!mounted || request != _contentRequest) return;
      setState(() {
        _loadingContent = false;
        _contentError = AppStrings.current.fileContentUnreadable;
      });
    }
  }

  void _closePreview() {
    _contentRequest++;
    setState(() {
      _selected = null;
      _selectedBytes = null;
      _loadingContent = false;
      _contentError = null;
    });
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    widget.onNotice(AppStrings.current.noticeFileContentCopied);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return selected != null
        ? _buildPreview(context, selected)
        : _buildFileList(context);
  }

  Widget _buildFileList(BuildContext context) {
    final files = _visibleFiles;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: TextField(
            key: const Key('skill-file-search'),
            controller: _searchController,
            decoration: InputDecoration(
              hintText: AppStrings.of(context).searchFilePaths,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: AppStrings.of(context).clearSearch,
                      onPressed: _searchController.clear,
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
          child: Row(
            children: <Widget>[
              Text(
                AppStrings.of(context).countFiles(_files.length + 1),
                style: const TextStyle(color: Color(0xFF81796E), fontSize: 12),
              ),
              const Spacer(),
              if (_loadingFiles)
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        if (_filesError != null)
          MaterialBanner(
            key: const Key('skill-files-error'),
            content: Text(_filesError!),
            actions: <Widget>[
              TextButton(
                onPressed: _loadFiles,
                child: Text(AppStrings.of(context).retry),
              ),
            ],
          ),
        Expanded(
          child: files.isEmpty
              ? Center(
                  child: Text(
                    AppStrings.of(context).noMatchingFiles,
                    style: const TextStyle(color: Color(0xFF81796E)),
                  ),
                )
              : ListView.separated(
                  key: const Key('skill-file-list'),
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
                  itemCount: files.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 5),
                  itemBuilder: (context, index) {
                    final file = files[index];
                    final shape = RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: Color(0xFFE7DDCF)),
                    );
                    return Material(
                      color: Colors.white,
                      shape: shape,
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        key: Key('skill-file-${file.relativePath}'),
                        onTap: () => _openFile(file),
                        shape: shape,
                        leading: Icon(
                          _fileIcon(file),
                          color: const Color(0xFF4C72B8),
                        ),
                        title: Text(
                          file.relativePath,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${_typeLabel(file)} · ${_formatBytes(file.byteLength)}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          size: 19,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context, SkillFileMetadata metadata) {
    final bytes = _selectedBytes;
    final text = bytes == null ? null : _decodeText(metadata, bytes);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 6),
          child: Row(
            children: <Widget>[
              TextButton.icon(
                key: const Key('skill-file-preview-back'),
                onPressed: _closePreview,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: Text(AppStrings.of(context).fileList),
              ),
              const Spacer(),
              Text(
                _formatBytes(metadata.byteLength),
                style: const TextStyle(color: Color(0xFF81796E), fontSize: 11),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 9),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              metadata.relativePath,
              key: const Key('skill-file-preview-path'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loadingContent
              ? const Center(child: CircularProgressIndicator())
              : _contentError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _contentError!,
                      key: const Key('skill-file-content-error'),
                      style: const TextStyle(color: Color(0xFF81796E)),
                    ),
                  ),
                )
              : bytes == null
              ? const SizedBox.shrink()
              : _buildContent(metadata, bytes, text),
        ),
        if (text != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
            child: FilledButton.icon(
              key: const Key('copy-skill-file'),
              onPressed: () => _copyText(text),
              icon: const Icon(Icons.copy_rounded, size: 17),
              label: Text(AppStrings.of(context).copyContent),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(42),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildContent(
    SkillFileMetadata metadata,
    Uint8List bytes,
    String? text,
  ) {
    if (text != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          key: const Key('skill-file-text-preview'),
          style: const TextStyle(fontSize: 13, height: 1.55),
        ),
      );
    }
    if (_isRasterImage(metadata)) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 4,
        child: Center(
          child: Image.memory(
            bytes,
            key: const Key('skill-file-image-preview'),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => _binarySummary(metadata),
          ),
        ),
      );
    }
    return _binarySummary(metadata);
  }

  Widget _binarySummary(SkillFileMetadata metadata) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.insert_drive_file_outlined,
              size: 46,
              color: Color(0xFF81796E),
            ),
            const SizedBox(height: 12),
            Text(
              _typeLabel(metadata),
              key: const Key('skill-file-binary-type'),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.of(context).fileSize(_formatBytes(metadata.byteLength)),
              style: const TextStyle(color: Color(0xFF81796E)),
            ),
          ],
        ),
      ),
    );
  }

  String? _decodeText(SkillFileMetadata metadata, Uint8List bytes) {
    if (!_isText(metadata)) return null;
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return null;
    }
  }

  bool _isText(SkillFileMetadata metadata) {
    final mediaType = metadata.mediaType?.toLowerCase();
    return mediaType?.startsWith('text/') == true ||
        mediaType == 'application/json' ||
        mediaType == 'application/yaml' ||
        mediaType == 'image/svg+xml';
  }

  bool _isRasterImage(SkillFileMetadata metadata) {
    return const <String>{
      'image/png',
      'image/jpeg',
      'image/gif',
    }.contains(metadata.mediaType?.toLowerCase());
  }

  IconData _fileIcon(SkillFileMetadata metadata) {
    if (_isRasterImage(metadata)) return Icons.image_outlined;
    if (_isText(metadata)) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _typeLabel(SkillFileMetadata metadata) {
    return metadata.mediaType ?? AppStrings.current.binaryFile;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
