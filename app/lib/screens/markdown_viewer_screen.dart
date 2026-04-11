import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;

/// 全屏Markdown文件查看器，类似Claude的Artifact弹窗
class MarkdownViewerScreen extends StatefulWidget {
  final String title;
  final String? url;              // 从服务器下载
  final Map<String, String>? headers;
  final String? localPath;        // 从本地文件读取
  final String? initialContent;   // 直接传入内容

  const MarkdownViewerScreen({
    super.key,
    required this.title,
    this.url,
    this.headers,
    this.localPath,
    this.initialContent,
  });

  @override
  State<MarkdownViewerScreen> createState() => _MarkdownViewerScreenState();
}

class _MarkdownViewerScreenState extends State<MarkdownViewerScreen> {
  String _content = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  Future<void> _loadContent() async {
    try {
      if (widget.initialContent != null) {
        _content = widget.initialContent!;
      } else if (widget.localPath != null) {
        final file = File(widget.localPath!);
        _content = await file.readAsString(encoding: utf8);
      } else if (widget.url != null) {
        final response = await http.get(
          Uri.parse(widget.url!),
          headers: widget.headers,
        ).timeout(const Duration(seconds: 30));
        if (response.statusCode == 200) {
          _content = utf8.decode(response.bodyBytes);
        } else {
          _error = '下载失败 (${response.statusCode})';
        }
      } else {
        _error = '没有可显示的内容';
      }
    } catch (e) {
      _error = '加载失败: $e';
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? theme.colorScheme.surface : const Color(0xFFFAF8F5),
      appBar: AppBar(
        backgroundColor: isDark ? theme.colorScheme.surface : const Color(0xFFFAF8F5),
        elevation: 0,
        scrolledUnderElevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.close, size: 24),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 22),
            onSelected: (value) {
              if (value == 'copy') {
                _copyAll();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'copy', child: Text('复制全部')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                        const SizedBox(height: 12),
                        Text(_error!, style: TextStyle(color: Colors.red[400], fontSize: 15)),
                        const SizedBox(height: 16),
                        FilledButton.tonal(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _error = null;
                            });
                            _loadContent();
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: MarkdownBody(
                      data: _content,
                      selectable: true,
                      softLineBreak: true,
                      styleSheet: _buildStyleSheet(context),
                    ),
                  ),
                ),
    );
  }

  MarkdownStyleSheet _buildStyleSheet(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    final codeBackground = theme.colorScheme.surfaceContainerHighest;

    return MarkdownStyleSheet(
      // 正文：16px，适合阅读
      p: TextStyle(fontSize: 16, height: 1.7, color: textColor),
      // 标题
      h1: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: textColor, height: 1.4),
      h2: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: textColor, height: 1.4),
      h3: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: textColor, height: 1.4),
      h4: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: textColor, height: 1.4),
      h5: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: textColor, height: 1.4),
      h6: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: textColor, height: 1.4),
      // 标题间距
      h1Padding: const EdgeInsets.only(top: 20, bottom: 8),
      h2Padding: const EdgeInsets.only(top: 18, bottom: 6),
      h3Padding: const EdgeInsets.only(top: 14, bottom: 4),
      // 行内代码
      code: TextStyle(
        fontSize: 14,
        fontFamily: 'monospace',
        backgroundColor: codeBackground,
        color: textColor,
      ),
      // 代码块
      codeblockDecoration: BoxDecoration(
        color: codeBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(14),
      // 引用
      blockquote: TextStyle(
        fontSize: 15,
        color: textColor.withValues(alpha: 0.7),
        fontStyle: FontStyle.italic,
        height: 1.6,
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.4),
            width: 3,
          ),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 14, top: 4, bottom: 4),
      // 列表
      listBullet: TextStyle(fontSize: 16, color: textColor),
      listBulletPadding: const EdgeInsets.only(right: 6),
      listIndent: 20,
      // 表格
      tableHead: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textColor),
      tableBody: TextStyle(fontSize: 14, color: textColor, height: 1.5),
      tableBorder: TableBorder.all(
        color: textColor.withValues(alpha: 0.2),
        width: 1,
      ),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      // 分割线
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: textColor.withValues(alpha: 0.15), width: 1),
        ),
      ),
      // 段落间距
      pPadding: const EdgeInsets.only(bottom: 8),
    );
  }

  void _copyAll() {
    if (_content.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _content));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
        );
      }
    }
  }
}
