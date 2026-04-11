import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/message.dart';
import '../providers/message_provider.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/download_service.dart';
import '../config/app_config.dart';
import 'image_preview_screen.dart';
import 'image_editor_screen.dart';
import 'markdown_viewer_screen.dart';
import 'remote_workspace_screen.dart';

class ChatScreen extends StatefulWidget {
  final ApiService apiService;
  final String sessionId;
  final String sessionName;
  final bool embedded;
  final MessageProvider? existingProvider;

  const ChatScreen({
    super.key,
    required this.apiService,
    required this.sessionId,
    required this.sessionName,
    this.embedded = false,
    this.existingProvider,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  /// 全局缓存：按sessionId复用MessageProvider，避免退出聊天后消息丢失
  static final Map<String, MessageProvider> _providerCache = {};
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  late final FocusNode _focusNode;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  // Attachment preview state
  final List<_AttachmentItem> _attachments = [];

  // Auto-hang (自动挂机) state
  bool _autoHang = false;
  Timer? _autoHangTimer;

  late MessageProvider _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (!_isDesktop) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        // Desktop: Enter = send, Shift+Enter = newline
        if (event.logicalKey == LogicalKeyboardKey.enter &&
            !HardwareKeyboard.instance.isShiftPressed) {
          _send();
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
    );

    // 复用已有provider或创建新的
    if (widget.existingProvider != null) {
      _provider = widget.existingProvider!;
      _providerCache[widget.sessionId] = _provider;
      _provider.reconnectWs();
    } else if (_providerCache.containsKey(widget.sessionId)) {
      _provider = _providerCache[widget.sessionId]!;
      _provider.reconnectWs();
    } else {
      final wsService = WsService(
        serverUrl: AppConfig.defaultServerUrl,
        sessionId: widget.sessionId,
        token: AppConfig.defaultToken,
      );
      _provider = MessageProvider(
        apiService: widget.apiService,
        wsService: wsService,
        sessionId: widget.sessionId,
      );
      _providerCache[widget.sessionId] = _provider;
      _provider.loadHistory();
      _provider.connectWs();
    }

    // 进入聊天时标记已读
    widget.apiService.markSessionRead(widget.sessionId).catchError((_) {});

  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _textController.dispose();
    _focusNode.dispose();
    _autoHangTimer?.cancel();
    // 不dispose provider，保留缓存
    super.dispose();
  }

  void _startAutoHang() {
    setState(() => _autoHang = true);
    // 立即发一次心跳，然后每2小时发一次
    _sendKeepAlive();
    _autoHangTimer = Timer.periodic(const Duration(hours: 2), (_) {
      _sendKeepAlive();
    });
  }

  void _stopAutoHang() {
    _autoHangTimer?.cancel();
    _autoHangTimer = null;
    setState(() => _autoHang = false);
  }

  void _sendKeepAlive() {
    _provider.sendCommand('reply',
      params: '{"text": "keepalive"}',
      displayText: '🔄 自动挂机心跳',
    );
  }

  Future<void> _handleDesktopPaste() async {
    try {
      debugPrint('[paste] _handleDesktopPaste called');

      // Try reading image from clipboard (supports WeChat screenshot, PrintScreen, etc.)
      Uint8List? imageBytes;
      try {
        imageBytes = await Pasteboard.image;
        debugPrint('[paste] Pasteboard.image: ${imageBytes?.length ?? 0} bytes');
      } catch (e) {
        debugPrint('[paste] Pasteboard.image error: $e');
      }

      if (imageBytes != null && imageBytes.isNotEmpty) {
        final tempDir = Directory.systemTemp;
        final tempFile = File(
          '${tempDir.path}/pasted_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await tempFile.writeAsBytes(imageBytes);
        debugPrint('[paste] Saved image to: ${tempFile.path}');
        if (mounted) {
          setState(() {
            _attachments.add(_AttachmentItem(
              name: tempFile.uri.pathSegments.last,
              path: tempFile.path,
            ));
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _focusNode.requestFocus();
          });
        }
        return;
      }

      // Try reading files from clipboard (e.g. copied image file in explorer)
      List<String> files = [];
      try {
        files = await Pasteboard.files();
        debugPrint('[paste] Pasteboard.files: ${files.length} files');
      } catch (e) {
        debugPrint('[paste] Pasteboard.files error: $e');
      }

      final imgExts = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
      int added = 0;
      for (final filePath in files) {
        final ext = filePath.split('.').last.toLowerCase();
        if (imgExts.contains(ext)) {
          if (mounted) {
            setState(() {
              _attachments.add(_AttachmentItem(
                name: filePath.split(Platform.pathSeparator).last,
                path: filePath,
              ));
            });
            added++;
          }
        }
      }
      if (added > 0 && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _focusNode.requestFocus();
        });
      }
    } catch (e, stack) {
      debugPrint('Clipboard paste failed: $e\n$stack');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _provider.reconnectWs();
      _provider.loadHistory();
    }
  }


  Future<void> _pickAttachment() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择图片'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('从文件管理器选择'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.computer),
              title: const Text('操控电脑'),
              onTap: () => Navigator.pop(ctx, 'remote_workspace'),
            ),
            ListTile(
              leading: const Icon(Icons.rocket_launch),
              title: const Text('启动 Windsurf'),
              onTap: () => Navigator.pop(ctx, 'launch_windsurf'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice == 'gallery') {
      await _pickFromGallery();
    } else if (choice == 'file') {
      await _pickFromFileManager();
    } else if (choice == 'remote_workspace') {
      await _openRemoteWorkspace();
    } else if (choice == 'launch_windsurf') {
      await _launchWindsurf();
    }
  }

  Future<void> _openRemoteWorkspace() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RemoteWorkspaceScreen(
          apiService: widget.apiService,
          sessionId: widget.sessionId,
          sessionName: widget.sessionName,
          provider: _provider,
        ),
      ),
    );
  }

  Future<void> _launchWindsurf() async {
    await _provider.sendCommand(
      'launch_windsurf',
      displayText: '🚀 启动 Windsurf',
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已发送 Windsurf 启动指令')),
    );
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final images = await picker.pickMultiImage();
    if (images.isEmpty) return;

    for (final img in images) {
      if (!mounted) return;
      // 进入图片编辑器
      final editedBytes = await Navigator.push<List<int>>(
        context,
        MaterialPageRoute(
          builder: (_) => ImageEditorScreen(
            imageUrl: img.path,
            headers: null,
            targetSessionId: widget.sessionId,
            targetSessionName: '当前会话',
          ),
        ),
      );

      if (editedBytes != null && mounted) {
        // 保存编辑后的图片到临时文件，加入待发送区
        final tempDir = Directory.systemTemp;
        final tempFile = File('${tempDir.path}/edited_${DateTime.now().millisecondsSinceEpoch}.png');
        await tempFile.writeAsBytes(editedBytes);
        setState(() {
          _attachments.add(_AttachmentItem(
            name: 'img_${DateTime.now().millisecondsSinceEpoch}.png',
            path: tempFile.path,
          ));
        });
      }
    }
  }

  Future<void> _pickFromFileManager() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    setState(() {
      for (final f in result.files) {
        if (f.path != null) {
          _attachments.add(_AttachmentItem(name: f.name, path: f.path!));
        }
      }
    });
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachments.removeAt(index);
    });
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    final hasText = text.isNotEmpty;
    final hasFiles = _attachments.isNotEmpty;

    if (!hasText && !hasFiles) return;

    if (hasFiles) {
      // Send first file with text as caption (combined delivery)
      for (int i = 0; i < _attachments.length; i++) {
        final att = _attachments[i];
        final bytes = await File(att.path).readAsBytes();
        final caption = (i == 0 && hasText) ? text : '';
        await _provider.sendFile(att.name, bytes, caption: caption);
      }
    } else {
      // Text only
      await _provider.sendReply(text);
    }

    _textController.clear();
    setState(() => _attachments.clear());
    _focusNode.requestFocus();
  }

  Widget _buildChatBody() {
    return Column(
      children: [
        Expanded(
          child: Consumer<MessageProvider>(
            builder: (_, provider, child) {
              if (provider.loading && provider.messages.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              if (provider.error != null && provider.messages.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                      const SizedBox(height: 8),
                      Text(provider.error!, style: TextStyle(color: Colors.red[300])),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => provider.loadHistory(),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                );
              }
              if (provider.messages.isEmpty) {
                return const Center(
                  child: Text('暂无消息\n等待PC端推送...',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)),
                );
              }
              final msgs = provider.messages.where((m) => !m.isStatus).toList();
              final itemCount = msgs.length + (provider.pcTyping ? 1 : 0);
              return SelectionArea(
                child: ListView.builder(
                  reverse: true,
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: itemCount,
                  itemBuilder: (_, i) {
                    if (provider.pcTyping && i == 0) {
                      return _buildTypingIndicator();
                    }
                    final msgIndex = provider.pcTyping ? i - 1 : i;
                    final reverseIndex = msgs.length - 1 - msgIndex;
                    return _buildMessageBubble(msgs[reverseIndex]);
                  },
                ),
              );
            },
          ),
        ),
        if (_autoHang) _buildAutoHangBanner(),
        const Divider(height: 1),
        if (_attachments.isNotEmpty) _buildAttachmentPreview(),
        _buildInputBar(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _provider,
      child: widget.embedded
          ? _buildChatBody()
          : Scaffold(
              appBar: AppBar(
                title: Consumer<MessageProvider>(
                  builder: (context, p, child) => Column(
                    children: [
                      Text(widget.sessionName, style: const TextStyle(fontSize: 16)),
                      Text(p.connectionMode,
                          style: TextStyle(fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
                    ],
                  ),
                ),
                centerTitle: true,
                actions: [
                  if (!kIsWeb && !_isDesktop)
                    IconButton(
                      onPressed: _openRemoteWorkspace,
                      icon: const Icon(Icons.desktop_windows),
                      tooltip: '操控电脑',
                    ),
                  Consumer<MessageProvider>(
                    builder: (_, p, child) => _buildStatusIndicator(p.wsStatus),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.add),
                    onSelected: (value) {
                      if (value == 'auto_hang') {
                        if (_autoHang) {
                          _stopAutoHang();
                        } else {
                          _startAutoHang();
                        }
                      } else if (value == 'refresh') {
                        _provider.loadHistory();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'auto_hang',
                        child: Row(
                          children: [
                            Icon(_autoHang ? Icons.stop_circle_outlined : Icons.nights_stay_outlined, size: 20),
                            const SizedBox(width: 8),
                            Text(_autoHang ? '取消挂机' : '自动挂机'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'refresh',
                        child: Row(
                          children: [
                            Icon(Icons.refresh, size: 20),
                            SizedBox(width: 8),
                            Text('刷新消息'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              body: _buildChatBody(),
            ),
    );
  }

  Widget _buildStatusIndicator(WsStatus status) {
    Color color;
    String tooltip;
    switch (status) {
      case WsStatus.connected:
        color = Colors.green;
        tooltip = '已连接';
      case WsStatus.connecting:
        color = Colors.orange;
        tooltip = '连接中...';
      case WsStatus.disconnected:
        color = Colors.grey;
        tooltip = '已断开';
      case WsStatus.error:
        color = Colors.red;
        tooltip = '连接错误';
      case WsStatus.failed:
        color = Colors.red;
        tooltip = '连接失败';
    }
    return Tooltip(
      message: tooltip,
      child: Container(
        margin: const EdgeInsets.only(right: 12),
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }

  Widget _buildAutoHangBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.amber.withValues(alpha: 0.15),
      child: Row(
        children: [
          const Icon(Icons.nights_stay, size: 18, color: Colors.amber),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('挂机中 · 每2小时自动心跳',
                style: TextStyle(fontSize: 13, color: Colors.amber)),
          ),
          TextButton(
            onPressed: _stopAutoHang,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: Size.zero,
            ),
            child: const Text('取消挂机', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentPreview() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.attach_file, size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Text('${_attachments.length} 个附件',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _attachments.clear()),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                child: const Text('清除全部', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          SizedBox(
            height: 60,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _attachments.length,
              itemBuilder: (_, i) {
                final att = _attachments[i];
                final isImage = _isImageFile(att.name);
                return Container(
                  margin: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: isImage
                            ? Image.file(File(att.path), fit: BoxFit.cover)
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.insert_drive_file, size: 24),
                                  Text(
                                    att.name.length > 8 ? '${att.name.substring(0, 8)}...' : att.name,
                                    style: const TextStyle(fontSize: 8),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                      ),
                      Positioned(
                        right: -4,
                        top: -4,
                        child: GestureDetector(
                          onTap: () => _removeAttachment(i),
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 1.5),
                            ),
                            child: const Icon(Icons.close, size: 10, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  bool _isImageFile(String name) {
    final ext = name.toLowerCase().split('.').last;
    return ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic'].contains(ext);
  }

  bool _isMarkdownFile(String name) {
    final ext = name.toLowerCase().split('.').last;
    return ext == 'md' || ext == 'markdown';
  }

  void _autoDownloadMarkdown(PushMessage msg) {
    if (msg.fileId.isEmpty) return;
    final fName = msg.fileName.isNotEmpty ? msg.fileName : '附件';
    final url = widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId);
    DownloadService().startDownload(
      fileId: msg.fileId,
      fileName: fName,
      sessionId: msg.sessionId,
      sessionName: widget.sessionName,
      downloadUrl: url,
      autoRename: true,
    );
  }

  Widget _buildInlineMarkdownContent(PushMessage msg, Color textColor, Color codeBackground) {
    return ListenableBuilder(
      listenable: DownloadService(),
      builder: (context, _) {
        final task = DownloadService().getTask(msg.fileId);
        final state = task?.state ?? DownloadState.idle;

        if (state == DownloadState.idle) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _autoDownloadMarkdown(msg));
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: textColor.withValues(alpha: 0.5))),
              const SizedBox(width: 8),
              Text('加载 ${msg.fileName}...', style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.6))),
            ],
          );
        }

        if (state == DownloadState.downloading) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, value: task?.progress, color: textColor.withValues(alpha: 0.5)),
              ),
              const SizedBox(width: 8),
              Text('加载中...', style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.6))),
            ],
          );
        }

        if (state == DownloadState.done && task?.savedPath != null) {
          try {
            final content = File(task!.savedPath!).readAsStringSync();
            return MarkdownBody(
              data: content,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(fontSize: 14, color: textColor, height: 1.6),
                h1: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textColor, height: 1.4),
                h2: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor, height: 1.4),
                h3: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: textColor, height: 1.4),
                h4: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textColor, height: 1.4),
                h5: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textColor, height: 1.4),
                listBullet: TextStyle(fontSize: 14, color: textColor, height: 1.6),
                pPadding: const EdgeInsets.only(bottom: 8),
                h3Padding: const EdgeInsets.only(top: 10, bottom: 4),
                h4Padding: const EdgeInsets.only(top: 8, bottom: 4),
                listBulletPadding: const EdgeInsets.only(right: 8),
                listIndent: 18,
                blockSpacing: 8,
                code: TextStyle(
                  fontSize: 12, color: textColor,
                  fontFamily: 'Consolas',
                  fontFamilyFallback: const ['Monaco', 'Fira Code', 'monospace'],
                  backgroundColor: codeBackground,
                ),
                codeblockDecoration: BoxDecoration(
                  color: codeBackground,
                  borderRadius: BorderRadius.circular(8),
                ),
                codeblockPadding: const EdgeInsets.all(10),
                strong: TextStyle(fontWeight: FontWeight.w700, color: textColor),
                em: TextStyle(fontStyle: FontStyle.italic, color: textColor),
              ),
            );
          } catch (e) {
            return Text('读取文件失败: $e', style: TextStyle(fontSize: 12, color: Colors.red[300]));
          }
        }

        return _buildFileAttachment(msg);
      },
    );
  }

  void _openMarkdownViewer(PushMessage msg, {String? localPath}) {
    final url = localPath == null
        ? widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId)
        : null;
    final headers = localPath == null
        ? {'Authorization': 'Bearer ${widget.apiService.token}'}
        : null;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MarkdownViewerScreen(
          title: msg.fileName.isNotEmpty ? msg.fileName : '文档',
          url: url,
          headers: headers,
          localPath: localPath,
        ),
      ),
    );
  }

  Widget _buildImageThumbnail(PushMessage msg) {
    final url = widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId);
    final heroTag = 'img_${msg.id}';
    final authHeaders = {'Authorization': 'Bearer ${widget.apiService.token}'};
    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => ImagePreviewScreen(
            imageUrl: url,
            heroTag: heroTag,
            headers: authHeaders,
            onSave: () => _startDownload(msg, preferMediaDir: true),
            saveTooltip: '保存图片到本地',
          ),
        ));
      },
      onLongPress: () => _showImageActions(msg, url, authHeaders),
      child: Hero(
        tag: heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
            child: CachedNetworkImage(
              imageUrl: url,
              httpHeaders: authHeaders,
              fit: BoxFit.cover,
              placeholder: (context, _) => Container(
                width: 150, height: 100,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              errorWidget: (context, error, stackTrace) => Container(
                width: 150, height: 100,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: const Center(child: Icon(Icons.broken_image, size: 32)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showImageActions(PushMessage msg, String imageUrl, Map<String, String> headers) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('转发到其他会话'),
              onTap: () {
                Navigator.pop(ctx);
                _forwardImage(msg, imageUrl, headers);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('保存到本地'),
              onTap: () {
                Navigator.pop(ctx);
                _startDownload(msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.cancel),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  void _forwardImage(PushMessage msg, String imageUrl, Map<String, String> headers) async {
    // 获取会话列表让用户选择目标
    try {
      final sessions = await widget.apiService.getSessions();
      if (!mounted) return;

      final target = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择目标会话'),
          children: sessions.map((s) => SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, s),
            child: ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(s['display_name'] ?? s['session_id'] ?? '未知'),
              subtitle: Text(s['session_id'] ?? '', style: const TextStyle(fontSize: 11)),
              dense: true,
            ),
          )).toList(),
        ),
      );
      if (target == null || !mounted) return;

      final targetId = target['session_id'] as String;
      final targetName = (target['display_name'] ?? target['session_id'] ?? '未知') as String;

      // 进入图片编辑页面
      final editedBytes = await Navigator.push<List<int>>(
        context,
        MaterialPageRoute(
          builder: (_) => ImageEditorScreen(
            imageUrl: imageUrl,
            headers: headers,
            targetSessionId: targetId,
            targetSessionName: targetName,
          ),
        ),
      );

      if (editedBytes == null || !mounted) return;

      // 上传编辑后的图片到目标会话
      final fileName = 'forward_${DateTime.now().millisecondsSinceEpoch}.png';
      final result = await widget.apiService.uploadFile(
        targetId, '', fileName, editedBytes,
        caption: '转发的图片', sender: 'mobile',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(
            result['success'] == true ? '已转发到 $targetName' : '转发失败',
          )),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('转发失败: $e')),
        );
      }
    }
  }

  void _startDownload(PushMessage msg, {bool preferMediaDir = false}) async {
    if (msg.fileId.isEmpty) return;
    final fName = msg.fileName.isNotEmpty ? msg.fileName : '附件';
    final url = widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId);
    final savingImage = preferMediaDir || _isImageFile(fName);

    // 检查同名文件是否存在
    final exists = await DownloadService().fileExists(
      fileName: fName, sessionName: widget.sessionName,
      preferMediaDir: savingImage,
    );

    bool autoRename = false;
    if (exists && mounted) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('文件已存在'),
          content: Text('$fName 已存在，如何处理？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'overwrite'), child: const Text('覆盖')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'rename'), child: const Text('保存为新文件')),
          ],
        ),
      );
      if (choice == null || choice == 'cancel') return;
      autoRename = choice == 'rename';
    }

    final task = DownloadService().startDownload(
      fileId: msg.fileId,
      fileName: fName,
      sessionId: msg.sessionId,
      sessionName: widget.sessionName,
      downloadUrl: url,
      autoRename: autoRename,
      preferMediaDir: savingImage,
    );

    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(savingImage ? '正在保存图片到本地...' : '正在下载附件...'),
        duration: const Duration(seconds: 2),
      ),
    );

    void handleTaskChange() {
      if (!mounted) {
        task.removeListener(handleTaskChange);
        return;
      }

      if (task.state == DownloadState.done) {
        task.removeListener(handleTaskChange);
        messenger.showSnackBar(
          SnackBar(
            content: Text(savingImage ? '图片已保存到本地' : '附件已保存到本地'),
            action: task.savedPath == null
                ? null
                : SnackBarAction(
                    label: '打开',
                    onPressed: () => OpenFilex.open(task.savedPath!),
                  ),
          ),
        );
      } else if (task.state == DownloadState.error) {
        task.removeListener(handleTaskChange);
        messenger.showSnackBar(
          SnackBar(
            content: Text('保存失败: ${task.errorMsg ?? '未知错误'}'),
          ),
        );
      }
    }

    task.addListener(handleTaskChange);
    handleTaskChange();
  }

  void _openDownloadedFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件不存在: $path')),
          );
        }
        return;
      }
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${result.message} | 路径: $path')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败: $e')),
        );
      }
    }
  }

  Widget _buildFileAttachment(PushMessage msg) {
    return ListenableBuilder(
      listenable: DownloadService(),
      builder: (context, _) {
        final task = DownloadService().getTask(msg.fileId);
        final state = task?.state ?? DownloadState.idle;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                msg.hasImage ? Icons.image
                    : _isMarkdownFile(msg.fileName) ? Icons.article
                    : Icons.insert_drive_file,
                size: 28,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      msg.fileName.isNotEmpty ? msg.fileName : '附件',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                    _buildDownloadStatus(state, task),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildDownloadActionButton(state, task, msg),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDownloadStatus(DownloadState state, DownloadTask? task) {
    switch (state) {
      case DownloadState.idle:
        return Text('点击下载',
            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary));
      case DownloadState.downloading:
        return Text(task?.speedText ?? '下载中...',
            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary));
      case DownloadState.done:
        return Text('点击打开',
            style: TextStyle(fontSize: 10, color: Colors.green[700]));
      case DownloadState.error:
        return Text('下载失败，点击重试',
            style: TextStyle(fontSize: 10, color: Colors.red[400]));
    }
  }

  Widget _buildDownloadActionButton(DownloadState state, DownloadTask? task, PushMessage msg) {
    Widget icon;
    VoidCallback? onTap;

    switch (state) {
      case DownloadState.idle:
        icon = Icon(Icons.download, size: 22, color: Theme.of(context).colorScheme.primary);
        onTap = () => _startDownload(msg);
        break;
      case DownloadState.downloading:
        icon = SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            value: task?.progress,
            strokeWidth: 2.5,
            color: Theme.of(context).colorScheme.primary,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        );
        onTap = null;
        break;
      case DownloadState.done:
        icon = Icon(Icons.open_in_new, size: 20, color: Colors.green[700]);
        onTap = () {
          if (task?.savedPath != null) {
            if (_isMarkdownFile(msg.fileName)) {
              _openMarkdownViewer(msg, localPath: task!.savedPath!);
            } else {
              _openDownloadedFile(task!.savedPath!);
            }
          }
        };
        break;
      case DownloadState.error:
        icon = Icon(Icons.refresh, size: 20, color: Colors.red[400]);
        onTap = () => _startDownload(msg);
        break;
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: icon,
      ),
    );
  }

  Widget _buildMessageBubble(PushMessage msg) {
    final isFromPC = msg.sender == 'pc';
    final timeStr = DateFormat('HH:mm').format(msg.createdAt.toLocal());
    final theme = Theme.of(context);

    // 显示的文本内容（caption优先，否则content），将字面 \n 转为真换行
    final rawText = msg.caption.isNotEmpty ? msg.caption : msg.content;
    final displayText = rawText.replaceAll(r'\n', '\n');

    // 用户消息：蓝色气泡(#4A90E2) + 白字；AI消息：浅灰底 + 深灰字(#333)
    final bubbleColor = isFromPC
        ? theme.colorScheme.surfaceContainerHighest
        : const Color(0xFF4A90E2);
    final textColor = isFromPC
        ? const Color(0xFF333333)
        : Colors.white;
    final timeColor = isFromPC
        ? theme.colorScheme.onSurface.withValues(alpha: 0.45)
        : Colors.white.withValues(alpha: 0.7);
    final codeBackground = isFromPC
        ? theme.colorScheme.surfaceContainerLow
        : const Color(0xFF3A7BD5);
    final labelColor = isFromPC
        ? theme.colorScheme.primary
        : Colors.white.withValues(alpha: 0.85);

    return Align(
      alignment: isFromPC ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (msg.isStatus)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.info_outline, size: 14, color: labelColor),
                    const SizedBox(width: 4),
                    Text('状态更新',
                        style: TextStyle(fontSize: 11, color: labelColor)),
                  ],
                ),
              ),
            if (msg.isScreenshot)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.photo_camera, size: 14, color: labelColor),
                    const SizedBox(width: 4),
                    Text('截图',
                        style: TextStyle(fontSize: 11, color: labelColor)),
                  ],
                ),
              ),
            if (displayText.isNotEmpty && !msg.isFile)
              MarkdownBody(
                data: displayText,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: 14, color: textColor, height: 1.6,
                  ),
                  h3: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold,
                    color: textColor, height: 1.4,
                  ),
                  h4: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold,
                    color: textColor, height: 1.4,
                  ),
                  h5: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: textColor, height: 1.4,
                  ),
                  listBullet: TextStyle(fontSize: 14, color: textColor, height: 1.6),
                  pPadding: const EdgeInsets.only(bottom: 8),
                  h3Padding: const EdgeInsets.only(top: 10, bottom: 4),
                  h4Padding: const EdgeInsets.only(top: 8, bottom: 4),
                  listBulletPadding: const EdgeInsets.only(right: 8),
                  listIndent: 18,
                  blockSpacing: 8,
                  code: TextStyle(
                    fontSize: 12, color: textColor,
                    fontFamily: 'Consolas',
                    fontFamilyFallback: const ['Monaco', 'Fira Code', 'monospace'],
                    backgroundColor: codeBackground,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: codeBackground,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  codeblockPadding: const EdgeInsets.all(10),
                  strong: TextStyle(
                    fontWeight: FontWeight.w700, color: textColor,
                  ),
                  em: TextStyle(
                    fontStyle: FontStyle.italic, color: textColor,
                  ),
                  a: TextStyle(
                    color: isFromPC ? const Color(0xFF1A73E8) : const Color(0xFFBBDEFB),
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            if (msg.isFile && _isImageFile(msg.fileName)) ...[
              if (msg.caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    msg.caption.replaceAll(r'\n', '\n'),
                    style: TextStyle(fontSize: 14, color: textColor, height: 1.6),
                  ),
                ),
              _buildImageThumbnail(msg),
            ] else if (msg.isFile && _isMarkdownFile(msg.fileName) && isFromPC) ...[
              _buildInlineMarkdownContent(msg, textColor, codeBackground),
            ] else if (msg.isFile) ...[
              if (msg.caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    msg.caption.replaceAll(r'\n', '\n'),
                    style: TextStyle(fontSize: 14, color: textColor, height: 1.6),
                  ),
                ),
              _buildFileAttachment(msg),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isFromPC) _buildSendStatusIcon(msg),
                Text(
                  timeStr,
                  style: TextStyle(fontSize: 10, color: timeColor),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSendStatusIcon(PushMessage msg) {
    switch (msg.sendStatus) {
      case SendStatus.sending:
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: SizedBox(
            width: 10, height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
          ),
        );
      case SendStatus.sent:
        return const Padding(
          padding: EdgeInsets.only(right: 4),
          child: Icon(Icons.check_circle, size: 12, color: Colors.green),
        );
      case SendStatus.failed:
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: GestureDetector(
            onTap: () {
              final provider = Provider.of<MessageProvider>(context, listen: false);
              provider.retrySend(msg);
            },
            child: const Icon(Icons.error, size: 12, color: Colors.red),
          ),
        );
      case SendStatus.none:
        return const SizedBox.shrink();
    }
  }

  Widget _buildTypingIndicator() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDot(0),
            const SizedBox(width: 4),
            _buildDot(1),
            const SizedBox(width: 4),
            _buildDot(2),
          ],
        ),
      ),
    );
  }

  Widget _buildDot(int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: Duration(milliseconds: 600 + index * 200),
      curve: Curves.easeInOut,
      builder: (_, value, child) => Opacity(opacity: value, child: child),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Widget _buildTextField() {
    final textField = TextField(
      controller: _textController,
      focusNode: _focusNode,
      decoration: InputDecoration(
        hintText: '输入消息...',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        isDense: true,
      ),
      textInputAction: TextInputAction.newline,
      minLines: 1,
      maxLines: 5,
      contentInsertionConfiguration: ContentInsertionConfiguration(
        allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
        onContentInserted: (KeyboardInsertedContent content) async {
          if (content.data != null) {
            final tempDir = Directory.systemTemp;
            final ext = content.mimeType.split('/').last;
            final tempFile = File('${tempDir.path}/pasted_${DateTime.now().millisecondsSinceEpoch}.$ext');
            await tempFile.writeAsBytes(content.data!);
            setState(() {
              _attachments.add(_AttachmentItem(name: tempFile.uri.pathSegments.last, path: tempFile.path));
            });
          }
        },
      ),
    );

    if (!_isDesktop) return textField;

    // On desktop, intercept Ctrl+V to also check clipboard for images
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): const PasteTextIntent(SelectionChangedCause.keyboard),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (intent) {
              debugPrint('[paste] PasteTextIntent intercepted via Shortcuts+Actions!');
              _handleDesktopPaste();
              // Also do normal text paste
              Clipboard.getData(Clipboard.kTextPlain).then((clip) {
                if (clip?.text != null && clip!.text!.isNotEmpty) {
                  final sel = _textController.selection;
                  final text = _textController.text;
                  final newText = text.replaceRange(sel.start, sel.end, clip.text!);
                  _textController.value = TextEditingValue(
                    text: newText,
                    selection: TextSelection.collapsed(offset: sel.start + clip.text!.length),
                  );
                }
              });
              return null;
            },
          ),
        },
        child: textField,
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              onPressed: _pickAttachment,
              icon: const Icon(Icons.add_circle_outline),
              tooltip: '添加附件',
            ),
            Expanded(
              child: _buildTextField(),
            ),
            if (_isDesktop)
              IconButton(
                onPressed: _handleDesktopPaste,
                icon: const Icon(Icons.content_paste),
                tooltip: '粘贴剪贴板图片',
              ),
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentItem {
  final String name;
  final String path;
  _AttachmentItem({required this.name, required this.path});
}
