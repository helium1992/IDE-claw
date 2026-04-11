import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/session.dart';
import '../models/message.dart';
import '../providers/message_provider.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/download_service.dart';
import '../services/notification_service.dart';
import '../config/app_config.dart';
import '../services/local_ipc_service.dart';
import '../services/windsurf_auto_service_launcher.dart';
import '../services/windsurf_account_script_service.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_filex/open_filex.dart';
import 'image_preview_screen.dart';
import 'markdown_viewer_screen.dart';

/// 桌面端主界面：左右分栏（会话列表 + 聊天窗口），类似微信电脑版
class DesktopHomeScreen extends StatefulWidget {
  final ApiService apiService;
  final LocalIpcService? localIpcService;
  final WindsurfAutoServiceLauncher? windsurfAutoServiceLauncher;
  final WindsurfAccountScriptService? windsurfAccountScriptService;

  const DesktopHomeScreen({
    super.key,
    required this.apiService,
    this.localIpcService,
    this.windsurfAutoServiceLauncher,
    this.windsurfAccountScriptService,
  });

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen>
    with WidgetsBindingObserver {
  List<PushSession> _sessions = [];
  bool _loading = true;
  String? _error;
  String? _selectedSessionId;
  String _selectedSessionName = '';

  // 缓存MessageProvider，避免切换会话时丢失消息
  final Map<String, MessageProvider> _providerCache = {};

  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  late final FocusNode _focusNode;
  final List<_AttachmentItem> _attachments = [];

  // Auto-hang (自动挂机) state
  bool _autoHang = false;
  Timer? _autoHangTimer;

  // Local IPC
  StreamSubscription? _localIpcSub;
  Timer? _windsurfStatusTimer;
  Timer? _windsurfAccountTimer;
  _WindsurfDetectionStatus _windsurfStatus = const _WindsurfDetectionStatus.empty();
  bool _windsurfStatusActionBusy = false;
  _WindsurfAccountPoolStatus _windsurfAccountStatus = const _WindsurfAccountPoolStatus.empty();
  bool _windsurfAccountBusy = false;
  bool _windsurfStatusCollapsed = true;
  bool _windsurfAccountCollapsed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initLocalIpc();
    _startWindsurfStatusPolling();
    _startWindsurfAccountPolling();

    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        // Enter = send, Shift+Enter = newline
        if (event.logicalKey == LogicalKeyboardKey.enter &&
            !HardwareKeyboard.instance.isShiftPressed) {
          _send();
          return KeyEventResult.handled;
        }

        // Ctrl+V = check clipboard for image
        if (event.logicalKey == LogicalKeyboardKey.keyV &&
            HardwareKeyboard.instance.isControlPressed) {
          debugPrint('[paste] Ctrl+V detected in desktop_home_screen');
          _handleDesktopPaste();
          return KeyEventResult.ignored; // also allow normal text paste
        }

        return KeyEventResult.ignored;
      },
    );

    _loadSessions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _localIpcSub?.cancel();
    _windsurfStatusTimer?.cancel();
    _windsurfAccountTimer?.cancel();
    _scrollController.dispose();
    _textController.dispose();
    _focusNode.dispose();
    _autoHangTimer?.cancel();
    super.dispose();
  }

  void _initLocalIpc() {
    final ipc = widget.localIpcService;
    if (ipc == null) return;
    _localIpcSub = ipc.messages.listen((data) {
      final message = data['message'] as String? ?? '';
      if (message.isEmpty) return;
      // 本地模式：由本地 IPC 负责显示消息（WS 不投递）
      // 云端模式：由 WS 投递消息，本地 IPC 不重复添加
      final targetSession = data['session_id'] as String? ?? '';
      MessageProvider? provider;
      if (targetSession.isNotEmpty) {
        provider = _providerCache[targetSession];
      }
      provider ??= _currentProvider;
      if (provider != null && provider.isLocalMode) {
        final msg = PushMessage(
          id: 'local_ipc_${DateTime.now().millisecondsSinceEpoch}',
          sessionId: provider.sessionId,
          content: message,
          msgType: 'text',
          sender: 'pc',
          createdAt: DateTime.now().toUtc(),
        );
        provider.addLocalMessage(msg);
      }
      // 弹出窗口并聚焦
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        windowManager.show();
        windowManager.focus();
      }
    });
  }

  void _startWindsurfStatusPolling() {
    _loadWindsurfStatus();
    _windsurfStatusTimer?.cancel();
    _windsurfStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _loadWindsurfStatus();
    });
  }

  void _startWindsurfAccountPolling() {
    _loadWindsurfAccountStatus();
    _windsurfAccountTimer?.cancel();
    _windsurfAccountTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _loadWindsurfAccountStatus();
    });
  }

  Future<void> _loadWindsurfAccountStatus() async {
    final service = widget.windsurfAccountScriptService;
    if (service == null || _windsurfAccountBusy) {
      return;
    }
    _windsurfAccountBusy = true;
    try {
      final result = await service.getStatus();
      final next = _WindsurfAccountPoolStatus.fromJson(<String, dynamic>{
        ...result,
        'loaded_at': DateTime.now().millisecondsSinceEpoch,
      });
      if (!mounted || _windsurfAccountStatus.sameSnapshot(next)) {
        return;
      }
      setState(() {
        _windsurfAccountStatus = next;
      });
    } catch (_) {
    } finally {
      _windsurfAccountBusy = false;
    }
  }

  Future<void> _loadWindsurfStatus() async {
    final statusFilePath = widget.windsurfAutoServiceLauncher?.statusFilePath;
    if (statusFilePath == null || statusFilePath.isEmpty) {
      return;
    }
    try {
      final file = File(statusFilePath);
      if (!file.existsSync()) {
        if (mounted && !_windsurfStatus.isUnavailable) {
          setState(() {
            _windsurfStatus = const _WindsurfDetectionStatus.unavailable();
          });
        }
        return;
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final next = _WindsurfDetectionStatus.fromJson(decoded);
      if (!mounted || _windsurfStatus.sameSnapshot(next)) {
        return;
      }
      setState(() {
        _windsurfStatus = next;
      });
    } catch (_) {}
  }

  Future<void> _toggleWindsurfService() async {
    final launcher = widget.windsurfAutoServiceLauncher;
    if (launcher == null || _windsurfStatusActionBusy) {
      return;
    }
    final shouldPause = _windsurfStatus.overallStatusLabel == '运行中';
    final shouldRestart = _windsurfStatus.hasError;
    final actionLabel = shouldPause ? '暂停' : (shouldRestart ? '重启' : '继续');
    if (mounted) {
      setState(() {
        _windsurfStatusActionBusy = true;
      });
    }
    try {
      if (shouldPause) {
        await launcher.stop();
      } else if (shouldRestart) {
        await launcher.stop(force: true);
        await launcher.start();
      } else {
        await launcher.start();
      }
      await _loadWindsurfStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$actionLabel失败：$e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _windsurfStatusActionBusy = false;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService().appInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _loadSessions(silent: true);
      _currentProvider?.reconnectWs();
      _loadWindsurfStatus();
      _loadWindsurfAccountStatus();
    }
  }

  MessageProvider? get _currentProvider =>
      _selectedSessionId != null ? _providerCache[_selectedSessionId] : null;

  Future<void> _loadSessions({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.apiService.getSessions();
      if (mounted) {
        setState(() {
          _sessions = data.map((j) => PushSession.fromJson(j)).toList();
          _loading = false;
          // 自动选择第一个会话
          if (_selectedSessionId == null && _sessions.isNotEmpty) {
            _selectSession(_sessions.first);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (!silent) _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _selectSession(PushSession session) {
    setState(() {
      _selectedSessionId = session.id;
      _selectedSessionName = session.title;
      _textController.clear();
      _attachments.clear();
    });

    // 获取或创建 MessageProvider
    if (!_providerCache.containsKey(session.id)) {
      final wsService = WsService(
        serverUrl: AppConfig.defaultServerUrl,
        sessionId: session.id,
        token: AppConfig.defaultToken,
      );
      final provider = MessageProvider(
        apiService: widget.apiService,
        wsService: wsService,
        sessionId: session.id,
      );
      // 挂载本地 IPC 回复回调（仅对匹配的 session 生效）
      if (widget.localIpcService != null &&
          session.id == widget.localIpcService!.sessionId) {
        provider.onReplyCallback = (text) {
          widget.localIpcService!.submitReply(text);
        };
      }
      _providerCache[session.id] = provider;
      provider.loadHistory();
      provider.connectWs();
    } else {
      _providerCache[session.id]!.reconnectWs();
    }

    // 标记已读
    widget.apiService.markSessionRead(session.id).catchError((_) {});
    _focusNode.requestFocus();
  }

  Future<void> _send() async {
    final provider = _currentProvider;
    if (provider == null) return;

    final text = _textController.text.trim();
    final hasText = text.isNotEmpty;
    final hasFiles = _attachments.isNotEmpty;

    if (!hasText && !hasFiles) return;

    if (hasFiles) {
      for (int i = 0; i < _attachments.length; i++) {
        final att = _attachments[i];
        final bytes = await File(att.path).readAsBytes();
        final caption = (i == 0 && hasText) ? text : '';
        await provider.sendFile(att.name, bytes, caption: caption);
      }
    } else {
      await provider.sendReply(text);
    }

    _textController.clear();
    setState(() => _attachments.clear());
    _focusNode.requestFocus();
  }

  Future<void> _handleDesktopPaste() async {
    try {
      debugPrint('[paste] _handleDesktopPaste called');

      // Try reading image from clipboard
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

      // Try reading files from clipboard
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

  Future<void> _pickAttachment() async {
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
    setState(() => _attachments.removeAt(index));
  }

  void _startAutoHang() {
    setState(() => _autoHang = true);
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
    _currentProvider?.sendCommand('reply',
      params: '{"text": "keepalive"}',
      displayText: '🔄 自动挂机心跳',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          // ===== 左侧：会话列表 =====
          SizedBox(
            width: 280,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.3),
                  ),
                ),
              ),
              child: Column(
                children: [
                  _buildSidebarHeader(theme),
                  Expanded(child: _buildSessionList(theme)),
                  _buildWindsurfStatusPanel(theme),
                  _buildWindsurfAccountPanel(theme),
                ],
              ),
            ),
          ),
          // ===== 右侧：聊天窗口 =====
          Expanded(
            child: _selectedSessionId != null
                ? _buildChatPanel(theme)
                : _buildEmptyChat(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 8),
          Text(
            'IDE Claw',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const Spacer(),
          SizedBox(
            width: 32,
            height: 32,
            child: PopupMenuButton<String>(
              tooltip: '账号菜单',
              padding: EdgeInsets.zero,
              iconSize: 20,
              icon: const Icon(Icons.settings_outlined, size: 20),
              onSelected: _handleWindsurfAccountMenuSelection,
              itemBuilder: (context) => const [
                PopupMenuItem<String>(
                  value: 'account_manager',
                  child: Row(
                    children: [
                      Icon(Icons.manage_accounts_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('账号设置'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'reply_rules',
                  child: Row(
                    children: [
                      Icon(Icons.rule_folder_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Reply Rules'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loadSessions,
            tooltip: '刷新会话列表',
          ),
        ],
      ),
    );
  }

  Widget _buildSessionList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: Colors.red[300]),
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Colors.red[300], fontSize: 12)),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _loadSessions, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            const Text('暂无会话', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _sessions.length,
      itemBuilder: (_, i) => _buildSessionTile(_sessions[i], theme),
    );
  }

  Widget _buildWindsurfStatusPanel(ThemeData theme) {
    final status = _windsurfStatus;
    final overallStatus = status.overallStatusLabel;
    final collapsed = _windsurfStatusCollapsed;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      padding: collapsed
          ? const EdgeInsets.fromLTRB(12, 6, 4, 6)
          : const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _windsurfStatusCollapsed = !_windsurfStatusCollapsed),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '状态',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (collapsed) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      overallStatus,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (!collapsed) ...[
                  Text(
                    status.updatedTimeLabel,
                    style: TextStyle(
                      fontSize: 10,
                      color: status.hasFreshUpdate
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                _buildWindsurfStatusActionPill(
                  theme,
                  status,
                  overallStatus,
                ),
              ],
            ),
          ),
          if (!collapsed) ...[
            if (status.detailSummaryLabel.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                status.detailSummaryLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: overallStatus == '错误'
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (status.scoreSummaryLabel.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                status.scoreSummaryLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            _buildDetectionLogTable(theme, status),
          ],
        ],
      ),
    );
  }

  Widget _buildWindsurfStatusActionPill(
    ThemeData theme,
    _WindsurfDetectionStatus status,
    String overallStatus,
  ) {
    final launcher = widget.windsurfAutoServiceLauncher;
    final enabled = launcher != null && !_windsurfStatusActionBusy;
    final color = _statusColor(theme, overallStatus);
    final message = status.hasError
        ? '点击重启脚本'
        : (overallStatus == '运行中' ? '点击暂停脚本' : '点击继续脚本');
    return Tooltip(
      message: enabled ? message : overallStatus,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? _toggleWindsurfService : null,
          borderRadius: BorderRadius.circular(999),
          child: Opacity(
            opacity: enabled ? 1 : 0.7,
            child: Container(
              constraints: const BoxConstraints(minHeight: 28),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _windsurfStatusActionBusy
                    ? SizedBox(
                        key: const ValueKey<String>('windsurf-status-loading'),
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                        ),
                      )
                    : Text(
                        overallStatus,
                        key: ValueKey<String>('windsurf-status-$overallStatus'),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWindsurfAccountPanel(ThemeData theme) {
    final service = widget.windsurfAccountScriptService;
    if (service == null) {
      return const SizedBox.shrink();
    }
    final status = _windsurfAccountStatus;
    final collapsed = _windsurfAccountCollapsed;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: collapsed
          ? const EdgeInsets.fromLTRB(12, 6, 4, 6)
          : const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _windsurfAccountCollapsed = !_windsurfAccountCollapsed),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '账号池',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (collapsed) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${status.currentEmail.isEmpty ? "--" : status.currentEmail.split("@").first} · 可切${status.availableAccounts}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (!collapsed) ...[
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      tooltip: '刷新账号状态',
                      iconSize: 16,
                      onPressed: _windsurfAccountBusy ? null : _loadWindsurfAccountStatus,
                      icon: _windsurfAccountBusy
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  theme.colorScheme.primary,
                                ),
                              ),
                            )
                          : const Icon(Icons.sync),
                    ),
                  ),
                ],
                SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: '快速切号',
                    iconSize: 14,
                    onPressed: _windsurfAccountBusy ? null : _handleQuickSwitchAccount,
                    icon: const Icon(Icons.swap_horiz),
                  ),
                ),
              ],
            ),
          ),
          if (!collapsed) ...[
            const SizedBox(height: 8),
            Text(
              status.currentEmailLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              status.detailLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _buildWindsurfAccountSummaryChip(
                  theme,
                  '可切 ${status.availableAccounts}',
                  Colors.green,
                ),
                _buildWindsurfAccountSummaryChip(
                  theme,
                  '没额度 ${status.depletedAccounts}',
                  Colors.orange,
                ),
                _buildWindsurfAccountSummaryChip(
                  theme,
                  '冷却 ${status.blockedAccounts}',
                  Colors.blueGrey,
                ),
                _buildWindsurfAccountSummaryChip(
                  theme,
                  '过期 ${status.expiredAccounts}',
                  theme.colorScheme.error,
                ),
                _buildWindsurfAccountSummaryChip(
                  theme,
                  status.currentHasToken ? '当前 token 已就绪' : '当前 token 缺失',
                  status.currentHasToken ? Colors.green : Colors.orange,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '刷新 ${status.loadedTimeLabel}',
              style: TextStyle(
                fontSize: 9,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWindsurfAccountSummaryChip(
    ThemeData theme,
    String label,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Future<void> _handleQuickSwitchAccount() async {
    final service = widget.windsurfAccountScriptService;
    if (service == null || _windsurfAccountBusy) {
      return;
    }
    setState(() => _windsurfAccountBusy = true);
    try {
      final result = await service.switchNext();
      final status = result['status'] as String? ?? 'unknown';
      final email = result['email'] as String? ?? '';
      final message = result['message'] as String? ?? '';
      if (mounted) {
        final label = status == 'success'
            ? '已切换到 $email'
            : (message.isNotEmpty ? message : '切号失败: $status');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(label),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('切号异常: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _windsurfAccountBusy = false);
      }
      _loadWindsurfAccountStatus();
    }
  }

  Future<void> _handleWindsurfAccountMenuSelection(String value) async {
    if (value == 'account_manager') {
      await _showWindsurfAccountDialog();
      return;
    }
    if (value == 'reply_rules') {
      await _showReplyRulesPlaceholder();
    }
  }

  Future<void> _showReplyRulesPlaceholder() async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reply Rules'),
        content: const Text('这里先预留。下一步再把 reply_text / 回复规则配置接到 Python 侧配置文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showWindsurfAccountDialog() async {
    final service = widget.windsurfAccountScriptService;
    if (service == null || !mounted) {
      return;
    }
    final importController = TextEditingController();
    var accounts = (await service.loadLocalAccounts())
        .map(_WindsurfLocalAccountEntry.fromJson)
        .toList();
    if (!mounted) {
      importController.dispose();
      return;
    }
    var footerMessage = '';
    var footerIsError = false;
    var actionBusy = false;

    int orderFor(_WindsurfLocalAccountEntry account, String currentEmail) {
      if (account.email == currentEmail) {
        return 0;
      }
      if (account.quotaState == 'active') {
        return 1;
      }
      if (account.isInCooldown) {
        return 2;
      }
      if (account.quotaState == 'unknown') {
        return 3;
      }
      if (account.quotaState == 'depleted') {
        return 4;
      }
      if (account.quotaState == 'expired') {
        return 5;
      }
      return 6;
    }

    void sortAccounts() {
      final currentEmail = _windsurfAccountStatus.currentEmail;
      accounts.sort((a, b) {
        final orderCompare = orderFor(a, currentEmail).compareTo(orderFor(b, currentEmail));
        if (orderCompare != 0) {
          return orderCompare;
        }
        return a.email.compareTo(b.email);
      });
    }

    sortAccounts();

    Future<void> reloadAccounts(StateSetter setDialogState) async {
      final loaded = (await service.loadLocalAccounts())
          .map(_WindsurfLocalAccountEntry.fromJson)
          .toList();
      accounts = loaded;
      sortAccounts();
      if (!mounted) {
        return;
      }
      setDialogState(() {});
    }

    Future<void> runAction(
      StateSetter setDialogState,
      Future<Map<String, dynamic>> Function() action,
    ) async {
      setDialogState(() {
        actionBusy = true;
        footerMessage = '';
        footerIsError = false;
      });
      final result = await action();
      await _loadWindsurfAccountStatus();
      await reloadAccounts(setDialogState);
      final summary = _summarizeWindsurfCommandResult(result);
      final isError = (result['status'] as String? ?? '').trim() == 'error';
      if (!mounted) {
        return;
      }
      setDialogState(() {
        actionBusy = false;
        footerMessage = summary;
        footerIsError = isError;
      });
      _showWindsurfAccountSnackBar(summary, isError: isError);
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);
            final status = _windsurfAccountStatus;
            return AlertDialog(
              title: Row(
                children: [
                  const Expanded(child: Text('Windsurf 账号设置')),
                  Text(
                    status.loadedTimeLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 760,
                height: 620,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildWindsurfAccountSummaryChip(theme, '当前 ${status.currentEmail.isEmpty ? '未识别' : status.currentEmail}', theme.colorScheme.primary),
                        _buildWindsurfAccountSummaryChip(theme, '可用 ${accounts.where((a) => a.category == 'available').length}', Colors.green),
                        _buildWindsurfAccountSummaryChip(theme, '次日刷新 ${accounts.where((a) => a.category == 'daily_reset').length}', Colors.orange),
                        _buildWindsurfAccountSummaryChip(theme, '周刷新 ${accounts.where((a) => a.category == 'weekly_reset').length}', Colors.deepOrange),
                        _buildWindsurfAccountSummaryChip(theme, '过期 ${accounts.where((a) => a.category == 'expired').length}', theme.colorScheme.error),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: importController,
                      enabled: !actionBusy,
                      minLines: 4,
                      maxLines: 6,
                      decoration: InputDecoration(
                        labelText: '批量导入账号',
                        hintText: '每行一个账号，格式：email----password',
                        border: const OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: actionBusy
                              ? null
                              : () async {
                                  final parsed = _parseAccountImportText(importController.text);
                                  if (parsed.isEmpty) {
                                    setDialogState(() {
                                      footerMessage = '没有可导入的账号，请按 email----password 格式粘贴';
                                      footerIsError = true;
                                    });
                                    return;
                                  }
                                  await runAction(
                                    setDialogState,
                                    () => service.importAndBootstrap(parsed),
                                  );
                                  if (!mounted) {
                                    return;
                                  }
                                  importController.clear();
                                },
                          icon: const Icon(Icons.playlist_add_check_circle_outlined),
                          label: const Text('导入并初始化'),
                        ),
                        OutlinedButton.icon(
                          onPressed: actionBusy
                              ? null
                              : () => runAction(
                                    setDialogState,
                                    () => service.refreshCredits(),
                                  ),
                          icon: const Icon(Icons.sync_problem_outlined),
                          label: const Text('刷新全部额度'),
                        ),
                        TextButton.icon(
                          onPressed: actionBusy
                              ? null
                              : () async {
                                  await _loadWindsurfAccountStatus();
                                  await reloadAccounts(setDialogState);
                                  setDialogState(() {
                                    footerMessage = '已刷新本地账号列表';
                                    footerIsError = false;
                                  });
                                },
                          icon: const Icon(Icons.refresh_outlined),
                          label: const Text('刷新列表'),
                        ),
                      ],
                    ),
                    if (footerMessage.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        footerMessage,
                        style: TextStyle(
                          fontSize: 12,
                          color: footerIsError
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Expanded(
                      child: accounts.isEmpty
                          ? Center(
                              child: Text(
                                '暂无本地账号',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : _buildCategorizedAccountList(
                              theme: theme,
                              accounts: accounts,
                              currentEmail: status.currentEmail,
                              actionBusy: actionBusy,
                              onSwitch: (email) => runAction(
                                setDialogState,
                                () => service.switchTo(email),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: actionBusy ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
    importController.dispose();
  }

  Widget _buildCategorizedAccountList({
    required ThemeData theme,
    required List<_WindsurfLocalAccountEntry> accounts,
    required String currentEmail,
    required bool actionBusy,
    required void Function(String email) onSwitch,
  }) {
    final available = accounts.where((a) => a.category == 'available').toList();
    final dailyReset = accounts.where((a) => a.category == 'daily_reset').toList();
    final weeklyReset = accounts.where((a) => a.category == 'weekly_reset').toList();
    final expired = accounts.where((a) => a.category == 'expired').toList();

    final sections = <_AccountSection>[
      _AccountSection(
        title: '可用账号',
        count: available.length,
        color: Colors.green,
        icon: Icons.check_circle_outline,
        accounts: available,
        initiallyExpanded: true,
      ),
      _AccountSection(
        title: '次日4点刷新',
        count: dailyReset.length,
        color: Colors.orange,
        icon: Icons.schedule_outlined,
        accounts: dailyReset,
        initiallyExpanded: dailyReset.isNotEmpty,
      ),
      _AccountSection(
        title: '周日4点刷新',
        count: weeklyReset.length,
        color: Colors.deepOrange,
        icon: Icons.date_range_outlined,
        accounts: weeklyReset,
        initiallyExpanded: weeklyReset.isNotEmpty,
      ),
      _AccountSection(
        title: '过期账号',
        count: expired.length,
        color: theme.colorScheme.error,
        icon: Icons.cancel_outlined,
        accounts: expired,
        initiallyExpanded: false,
      ),
    ];

    return ListView(
      children: [
        for (final section in sections)
          if (section.accounts.isNotEmpty)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: section.initiallyExpanded,
                tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                childrenPadding: EdgeInsets.zero,
                leading: Icon(section.icon, size: 18, color: section.color),
                title: Row(
                  children: [
                    Text(
                      section.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: section.color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${section.count}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: section.color,
                        ),
                      ),
                    ),
                  ],
                ),
                children: [
                  for (final account in section.accounts)
                    _buildAccountTile(
                      theme: theme,
                      account: account,
                      isCurrent: account.email == currentEmail,
                      actionBusy: actionBusy,
                      onSwitch: onSwitch,
                    ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _buildAccountTile({
    required ThemeData theme,
    required _WindsurfLocalAccountEntry account,
    required bool isCurrent,
    required bool actionBusy,
    required void Function(String email) onSwitch,
  }) {
    final detailParts = <String>[
      account.quotaStateLabel,
      account.creditsLabel,
      account.hasToken ? 'token就绪' : '无token',
    ];
    if (account.cooldownLabel.isNotEmpty) {
      detailParts.add(account.cooldownLabel);
    }
    if (account.purgeLabel.isNotEmpty) {
      detailParts.add(account.purgeLabel);
    }
    if (account.refreshLabel.isNotEmpty) {
      detailParts.add(account.refreshLabel);
    } else if (account.lastQuotaRefreshAt.isNotEmpty) {
      detailParts.add('刷新 ${account.lastQuotaRefreshAt}');
    }
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      title: Row(
        children: [
          Expanded(
            child: Text(
              account.email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          if (isCurrent)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '当前',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          detailParts.join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      trailing: isCurrent || !account.canSwitch
          ? null
          : TextButton(
              onPressed: actionBusy ? null : () => onSwitch(account.email),
              child: const Text('切换'),
            ),
    );
  }

  List<Map<String, String>> _parseAccountImportText(String raw) {
    final result = <Map<String, String>>[];
    final seen = <String>{};
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final parts = trimmed.split('----');
      final email = parts.first.trim().toLowerCase();
      final password = parts.length > 1 ? parts.sublist(1).join('----').trim() : '';
      if (email.isEmpty || !email.contains('@') || seen.contains(email)) {
        continue;
      }
      seen.add(email);
      result.add(<String, String>{
        'email': email,
        'password': password,
      });
    }
    return result;
  }

  void _showWindsurfAccountSnackBar(String message, {required bool isError}) {
    if (!mounted || message.trim().isEmpty) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  String _summarizeWindsurfCommandResult(Map<String, dynamic> result) {
    final status = (result['status'] as String? ?? '').trim();
    final message = (result['message'] as String? ?? '').trim();
    if (message.isNotEmpty) {
      return message;
    }
    if (status == 'success' || status == 'partial_success') {
      if (result.containsKey('success_count') || result.containsKey('failed_count')) {
        final success = (result['success_count'] as num?)?.toInt() ?? 0;
        final failed = (result['failed_count'] as num?)?.toInt() ?? 0;
        final skipped = (result['skipped_count'] as num?)?.toInt() ?? 0;
        return '完成：成功 $success，失败 $failed，跳过 $skipped';
      }
      final imported = (result['imported'] as num?)?.toInt();
      final currentEmail = (result['current_email'] as String? ?? '').trim();
      if (imported != null) {
        return '导入完成：导入 $imported 个账号${currentEmail.isNotEmpty ? '，当前 $currentEmail' : ''}';
      }
      if (currentEmail.isNotEmpty) {
        return '操作完成：当前账号 $currentEmail';
      }
      return '操作完成';
    }
    if (status == 'no_action') {
      return '没有需要执行的操作';
    }
    if (status == 'error') {
      final stdout = (result['stdout'] as String? ?? '').trim();
      if (stdout.isNotEmpty) {
        return stdout;
      }
      final stderr = (result['stderr'] as String? ?? '').trim();
      if (stderr.isNotEmpty) {
        return stderr;
      }
      return '操作失败';
    }
    return status.isEmpty ? '操作已返回' : status;
  }

  Widget _buildDetectionLogTable(ThemeData theme, _WindsurfDetectionStatus status) {
    const visibleRowCount = 5;
    const rowHeight = 30.0;
    const dividerHeight = 1.0;
    final recentCycles = status.recentCycles.reversed.toList(growable: false);
    final maxListHeight =
        (visibleRowCount * rowHeight) + ((visibleRowCount - 1) * dividerHeight);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                _buildLogHeaderCell(theme, '时间', flex: 26, align: Alignment.centerLeft),
                _buildLogHeaderCell(theme, 'L', flex: 14),
                _buildLogHeaderCell(theme, 'R', flex: 14),
                _buildLogHeaderCell(theme, '执', flex: 12),
                _buildLogHeaderCell(theme, '结果', flex: 34, align: Alignment.centerLeft),
              ],
            ),
          ),
          if (recentCycles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Text(
                '暂无检测记录',
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxListHeight),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: recentCycles.length,
                separatorBuilder: (context, index) => Divider(
                  height: 1,
                  thickness: 1,
                  color: theme.dividerColor.withValues(alpha: 0.12),
                ),
                itemBuilder: (_, index) {
                  final cycle = recentCycles[index];
                  return _buildDetectionLogRow(
                    theme,
                    cycle,
                    zebra: index.isEven,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetectionLogRow(
    ThemeData theme,
    _WindsurfCycleEntry cycle, {
    required bool zebra,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      color: zebra
          ? theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.25)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          _buildLogTableCell(
            theme,
            cycle.timeLabel,
            flex: 26,
            align: Alignment.centerLeft,
          ),
          _buildLogTableCell(
            theme,
            cycle.displayStateFor('left'),
            flex: 14,
            color: _statusColor(theme, cycle.displayStateFor('left')),
          ),
          _buildLogTableCell(
            theme,
            cycle.displayStateFor('right'),
            flex: 14,
            color: _statusColor(theme, cycle.displayStateFor('right')),
          ),
          _buildLogTableCell(
            theme,
            cycle.actionExecuted ? '是' : '否',
            flex: 12,
            color: _statusColor(theme, cycle.actionExecuted ? '是' : '否'),
          ),
          _buildLogTableCell(
            theme,
            cycle.resultLabel,
            flex: 34,
            align: Alignment.centerLeft,
            color: _statusColor(theme, cycle.resultLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildLogHeaderCell(
    ThemeData theme,
    String text, {
    required int flex,
    Alignment align = Alignment.center,
  }) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: align,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildLogTableCell(
    ThemeData theme,
    String text, {
    required int flex,
    Alignment align = Alignment.center,
    Color? color,
  }) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: align,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: color ?? theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Color _statusColor(ThemeData theme, String value) {
    if (value.startsWith('执行')) {
      return Colors.green;
    }
    switch (value) {
      case '运行中':
      case '工作中':
      case '是':
      case '已执行':
        return Colors.green;
      case '已停止':
      case '已暂停':
      case '确认中':
      case '轮候':
      case '冷却':
      case '等刷新':
        return Colors.orange;
      case '错误':
        return theme.colorScheme.error;
      case '未运行':
      case '否':
      case '无目标':
      case '未识别':
      case '窗口不符':
      case '用户操作':
      case '未刷新':
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  Widget _buildSessionTile(PushSession session, ThemeData theme) {
    final isSelected = session.id == _selectedSessionId;
    String timeStr = '';
    try {
      final timeSource = session.lastMsgTime.isNotEmpty
          ? session.lastMsgTime
          : session.lastActive;
      final dt = DateTime.parse(timeSource).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) {
        timeStr = '刚刚';
      } else if (diff.inHours < 1) {
        timeStr = '${diff.inMinutes}分钟前';
      } else if (diff.inDays < 1) {
        timeStr = '${diff.inHours}小时前';
      } else {
        timeStr = DateFormat('MM/dd HH:mm').format(dt);
      }
    } catch (_) {
      timeStr = session.lastActive;
    }

    IconData iconData;
    Color iconColor;
    switch (session.iconType) {
      case IconType.windsurf:
        iconData = Icons.sailing;
        iconColor = Colors.teal;
        break;
      case IconType.cursor:
        iconData = Icons.mouse;
        iconColor = Colors.purple;
        break;
      case IconType.vscode:
        iconData = Icons.code;
        iconColor = Colors.blue;
        break;
      case IconType.generic:
        iconData = Icons.computer;
        iconColor = theme.colorScheme.primary;
        break;
    }

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: () => _selectSession(session),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: iconColor.withValues(alpha: 0.15),
                    child: Icon(iconData, color: iconColor, size: 20),
                  ),
                  if (session.unreadCount > 0)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        constraints:
                            const BoxConstraints(minWidth: 16, minHeight: 16),
                        child: Text(
                          session.unreadCount > 99
                              ? '99+'
                              : '${session.unreadCount}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            session.title,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: theme.colorScheme.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          timeStr,
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      session.lastMessage.isNotEmpty
                          ? session.lastMessage
                          : '暂无消息',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey[500]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyChat(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            '选择一个会话开始聊天',
            style: TextStyle(fontSize: 16, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildChatPanel(ThemeData theme) {
    final provider = _currentProvider;
    if (provider == null) return _buildEmptyChat(theme);

    return ChangeNotifierProvider.value(
      value: provider,
      child: Column(
        children: [
          _buildChatHeader(theme),
          Expanded(child: _buildMessageList(theme)),
          if (_autoHang) _buildAutoHangBanner(theme),
          const Divider(height: 1),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _attachments.isNotEmpty
                ? _buildAttachmentPreview(theme)
                : const SizedBox.shrink(),
          ),
          _buildInputBar(theme),
        ],
      ),
    );
  }

  Widget _buildChatHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selectedSessionName,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                Consumer<MessageProvider>(
                  builder: (_, p, __) => GestureDetector(
                    onTap: () {
                      p.toggleCommMode();
                      // 同步通信模式到本地 IPC 服务（供 dialog.py 检测）
                      if (widget.localIpcService != null) {
                        widget.localIpcService!.commMode =
                            p.isLocalMode ? 'local' : 'cloud';
                      }
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          p.isLocalMode ? Icons.computer : Icons.cloud_outlined,
                          size: 13,
                          color: p.isLocalMode
                              ? Colors.green
                              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          p.connectionMode,
                          style: TextStyle(
                            fontSize: 11,
                            color: p.isLocalMode
                                ? Colors.green
                                : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.swap_horiz,
                          size: 12,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Consumer<MessageProvider>(
            builder: (_, p, __) => _buildStatusIndicator(p.wsStatus, theme),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.add, size: 20),
            onSelected: (value) {
              if (value == 'auto_hang') {
                if (_autoHang) {
                  _stopAutoHang();
                } else {
                  _startAutoHang();
                }
              } else if (value == 'refresh') {
                _currentProvider?.loadHistory();
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
    );
  }

  Widget _buildStatusIndicator(WsStatus status, ThemeData theme) {
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
        margin: const EdgeInsets.only(right: 8),
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }

  Widget _buildAutoHangBanner(ThemeData theme) {
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

  Widget _buildMessageList(ThemeData theme) {
    return Consumer<MessageProvider>(
      builder: (_, provider, __) {
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
                Text(provider.error!,
                    style: TextStyle(color: Colors.red[300])),
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
            child: Text('暂无消息\n等待推送...',
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: itemCount,
            itemBuilder: (_, i) {
              if (provider.pcTyping && i == 0) {
                return _buildTypingIndicator(theme);
              }
              final msgIndex = provider.pcTyping ? i - 1 : i;
              final reverseIndex = msgs.length - 1 - msgIndex;
              return _buildMessageBubble(msgs[reverseIndex], theme);
            },
          ),
        );
      },
    );
  }

  Widget _buildMessageBubble(PushMessage msg, ThemeData theme) {
    final isFromPC = msg.sender == 'pc';
    final timeStr = DateFormat('HH:mm').format(msg.createdAt.toLocal());
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
        constraints: const BoxConstraints(maxWidth: 600),
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
                    fontSize: 15, color: textColor, height: 1.6,
                  ),
                  h3: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold,
                    color: textColor, height: 1.4,
                  ),
                  h4: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold,
                    color: textColor, height: 1.4,
                  ),
                  h5: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600,
                    color: textColor, height: 1.4,
                  ),
                  listBullet: TextStyle(fontSize: 15, color: textColor, height: 1.6),
                  pPadding: const EdgeInsets.only(bottom: 8),
                  h3Padding: const EdgeInsets.only(top: 12, bottom: 6),
                  h4Padding: const EdgeInsets.only(top: 10, bottom: 4),
                  listBulletPadding: const EdgeInsets.only(right: 8),
                  listIndent: 20,
                  blockSpacing: 10,
                  code: TextStyle(
                    fontSize: 13, color: textColor,
                    fontFamily: 'Consolas',
                    fontFamilyFallback: const ['Monaco', 'Fira Code', 'monospace'],
                    backgroundColor: codeBackground,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: codeBackground,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  codeblockPadding: const EdgeInsets.all(12),
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
                    style: TextStyle(fontSize: 15, color: textColor, height: 1.6),
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
                    style: TextStyle(fontSize: 15, color: textColor, height: 1.6),
                  ),
                ),
              _buildFileAttachment(msg, theme),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isFromPC) _buildSendStatusIcon(msg, theme),
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

  Widget _buildSendStatusIcon(PushMessage msg, ThemeData theme) {
    switch (msg.sendStatus) {
      case SendStatus.sending:
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
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
            onTap: () => _currentProvider?.retrySend(msg),
            child: const Icon(Icons.error, size: 12, color: Colors.red),
          ),
        );
      case SendStatus.none:
        return const SizedBox.shrink();
    }
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
      sessionName: _selectedSessionName,
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
                p: TextStyle(fontSize: 15, color: textColor, height: 1.6),
                h1: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textColor, height: 1.4),
                h2: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textColor, height: 1.4),
                h3: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor, height: 1.4),
                h4: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textColor, height: 1.4),
                h5: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: textColor, height: 1.4),
                listBullet: TextStyle(fontSize: 15, color: textColor, height: 1.6),
                pPadding: const EdgeInsets.only(bottom: 8),
                h3Padding: const EdgeInsets.only(top: 12, bottom: 6),
                h4Padding: const EdgeInsets.only(top: 10, bottom: 4),
                listBulletPadding: const EdgeInsets.only(right: 8),
                listIndent: 20,
                blockSpacing: 10,
                code: TextStyle(
                  fontSize: 13, color: textColor,
                  fontFamily: 'Consolas',
                  fontFamilyFallback: const ['Monaco', 'Fira Code', 'monospace'],
                  backgroundColor: codeBackground,
                ),
                codeblockDecoration: BoxDecoration(
                  color: codeBackground,
                  borderRadius: BorderRadius.circular(8),
                ),
                codeblockPadding: const EdgeInsets.all(12),
                strong: TextStyle(fontWeight: FontWeight.w700, color: textColor),
                em: TextStyle(fontStyle: FontStyle.italic, color: textColor),
              ),
            );
          } catch (e) {
            return Text('读取文件失败: $e', style: TextStyle(fontSize: 12, color: Colors.red[300]));
          }
        }

        return _buildFileAttachment(msg, Theme.of(context));
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
    final url =
        widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId);
    final heroTag = 'img_${msg.id}';
    final authHeaders = {'Authorization': 'Bearer ${widget.apiService.token}'};
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImagePreviewScreen(
              imageUrl: url,
              heroTag: heroTag,
              headers: authHeaders,
            ),
          ),
        );
      },
      child: Hero(
        tag: heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300, maxHeight: 300),
            child: CachedNetworkImage(
              imageUrl: url,
              httpHeaders: authHeaders,
              fit: BoxFit.cover,
              placeholder: (context, _) => Container(
                width: 200,
                height: 120,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              errorWidget: (context, _, __) => Container(
                width: 200,
                height: 120,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: const Center(
                    child: Icon(Icons.broken_image, size: 32)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileAttachment(PushMessage msg, ThemeData theme) {
    return ListenableBuilder(
      listenable: DownloadService(),
      builder: (context, _) {
        final task = DownloadService().getTask(msg.fileId);
        final state = task?.state ?? DownloadState.idle;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
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
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      msg.fileName.isNotEmpty ? msg.fileName : '附件',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                    _buildDesktopDownloadStatus(state, task, theme),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildDesktopActionButton(state, task, msg, theme),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopDownloadStatus(DownloadState state, DownloadTask? task, ThemeData theme) {
    switch (state) {
      case DownloadState.idle:
        return Text('点击下载', style: TextStyle(fontSize: 10, color: theme.colorScheme.primary));
      case DownloadState.downloading:
        return Text(task?.speedText ?? '下载中...', style: TextStyle(fontSize: 10, color: theme.colorScheme.primary));
      case DownloadState.done:
        return Text('点击打开', style: TextStyle(fontSize: 10, color: Colors.green[700]));
      case DownloadState.error:
        return Text('下载失败，点击重试', style: TextStyle(fontSize: 10, color: Colors.red[400]));
    }
  }

  Widget _buildDesktopActionButton(DownloadState state, DownloadTask? task, PushMessage msg, ThemeData theme) {
    Widget icon;
    VoidCallback? onTap;

    switch (state) {
      case DownloadState.idle:
        icon = Icon(Icons.download, size: 22, color: theme.colorScheme.primary);
        onTap = () => _startDownload(msg);
        break;
      case DownloadState.downloading:
        icon = SizedBox(
          width: 22, height: 22,
          child: CircularProgressIndicator(
            value: task?.progress, strokeWidth: 2.5,
            color: theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
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
              OpenFilex.open(task!.savedPath!);
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

  void _startDownload(PushMessage msg) {
    if (msg.fileId.isEmpty) return;
    final fName = msg.fileName.isNotEmpty ? msg.fileName : '附件';
    final url =
        widget.apiService.getFileDownloadUrl(msg.fileId, msg.sessionId);

    DownloadService().startDownload(
      fileId: msg.fileId,
      fileName: fName,
      sessionId: msg.sessionId,
      sessionName: _selectedSessionName,
      downloadUrl: url,
      autoRename: false,
    );
  }

  Widget _buildTypingIndicator(ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            3,
            (i) => Padding(
              padding: EdgeInsets.only(left: i > 0 ? 4 : 0),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.3, end: 1.0),
                duration: Duration(milliseconds: 600 + i * 200),
                curve: Curves.easeInOut,
                builder: (_, value, child) =>
                    Opacity(opacity: value, child: child),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showImageFullScreen(String filePath) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Colors.white),
            elevation: 0,
          ),
          extendBodyBehindAppBar: true,
          body: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(File(filePath), fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentPreview(ThemeData theme) {
    final imgExts = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.attach_file, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
              Text('${_attachments.length} 个附件',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.primary)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _attachments.clear()),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                child: const Text('清除', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _attachments.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final att = _attachments[index];
                final ext = att.name.split('.').last.toLowerCase();
                final isImage = imgExts.contains(ext);
                return Stack(
                  children: [
                    GestureDetector(
                      onTap: isImage ? () => _showImageFullScreen(att.path) : null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: isImage
                            ? Image.file(
                                File(att.path),
                                width: 72,
                                height: 72,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _buildFileIcon(att.name, theme),
                              )
                            : _buildFileIcon(att.name, theme),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: () => _removeAttachment(index),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(2),
                          child: const Icon(Icons.close, size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileIcon(String name, ThemeData theme) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.insert_drive_file, size: 28, color: theme.colorScheme.primary),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              name,
              style: TextStyle(fontSize: 9, color: theme.colorScheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _pickAttachment,
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '添加附件',
          ),
          Expanded(
            child: TextField(
              controller: _textController,
              focusNode: _focusNode,
              decoration: InputDecoration(
                hintText: '输入消息... (Enter发送, Shift+Enter换行)',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                isDense: true,
              ),
              textInputAction: TextInputAction.newline,
              onSubmitted: (_) => _send(),
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
            ),
          ),
          IconButton(
            onPressed: _handleDesktopPaste,
            icon: const Icon(Icons.content_paste),
            tooltip: '粘贴剪贴板图片',
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            onPressed: _send,
            icon: const Icon(Icons.send),
            tooltip: '发送',
          ),
        ],
      ),
    );
  }
}

class _AttachmentItem {
  final String name;
  final String path;
  _AttachmentItem({required this.name, required this.path});
}

class _WindsurfDetectionStatus {
  final int updatedAt;
  final bool serviceRunning;
  final bool serviceEnabled;
  final String phase;
  final String status;
  final String summary;
  final String selectedTarget;
  final String candidateTarget;
  final int candidateStreak;
  final int candidateWindowCount;
  final int confirmRounds;
  final int confirmRequiredHits;
  final bool actionExecuted;
  final String lastActionTarget;
  final String lastActionStatus;
  final int lastActionAt;
  final bool awaitingProgressReset;
  final String awaitingProgressTarget;
  final int cooldownRemainingMs;
  final int quietRemainingMs;
  final int holdoffRemainingMs;
  final bool hasTargetButton;
  final List<String> detectedTargetNames;
  final List<_WindsurfButtonState> buttonStates;
  final List<_WindsurfCycleEntry> recentCycles;

  const _WindsurfDetectionStatus({
    required this.updatedAt,
    required this.serviceRunning,
    required this.serviceEnabled,
    required this.phase,
    required this.status,
    required this.summary,
    required this.selectedTarget,
    required this.candidateTarget,
    required this.candidateStreak,
    required this.candidateWindowCount,
    required this.confirmRounds,
    required this.confirmRequiredHits,
    required this.actionExecuted,
    required this.lastActionTarget,
    required this.lastActionStatus,
    required this.lastActionAt,
    required this.awaitingProgressReset,
    required this.awaitingProgressTarget,
    required this.cooldownRemainingMs,
    required this.quietRemainingMs,
    required this.holdoffRemainingMs,
    required this.hasTargetButton,
    required this.detectedTargetNames,
    required this.buttonStates,
    required this.recentCycles,
  });

  const _WindsurfDetectionStatus.empty()
      : updatedAt = 0,
        serviceRunning = false,
        serviceEnabled = true,
        phase = 'idle',
        status = 'idle',
        summary = '正在等待检测服务状态...',
        selectedTarget = '',
        candidateTarget = '',
        candidateStreak = 0,
        candidateWindowCount = 0,
        confirmRounds = 0,
        confirmRequiredHits = 0,
        actionExecuted = false,
        lastActionTarget = '',
        lastActionStatus = '',
        lastActionAt = 0,
        awaitingProgressReset = false,
        awaitingProgressTarget = '',
        cooldownRemainingMs = 0,
        quietRemainingMs = 0,
        holdoffRemainingMs = 0,
        hasTargetButton = false,
        detectedTargetNames = const <String>[],
        buttonStates = const <_WindsurfButtonState>[],
        recentCycles = const <_WindsurfCycleEntry>[];

  const _WindsurfDetectionStatus.unavailable()
      : updatedAt = 0,
        serviceRunning = false,
        serviceEnabled = true,
        phase = 'unavailable',
        status = 'unavailable',
        summary = '状态文件尚未生成，等待检测服务启动',
        selectedTarget = '',
        candidateTarget = '',
        candidateStreak = 0,
        candidateWindowCount = 0,
        confirmRounds = 0,
        confirmRequiredHits = 0,
        actionExecuted = false,
        lastActionTarget = '',
        lastActionStatus = '',
        lastActionAt = 0,
        awaitingProgressReset = false,
        awaitingProgressTarget = '',
        cooldownRemainingMs = 0,
        quietRemainingMs = 0,
        holdoffRemainingMs = 0,
        hasTargetButton = false,
        detectedTargetNames = const <String>[],
        buttonStates = const <_WindsurfButtonState>[],
        recentCycles = const <_WindsurfCycleEntry>[];

  bool get isUnavailable => status == 'unavailable';

  bool get hasError {
    final isErrorState = phase == 'error' || status == 'error' || status == 'start_failed' || status == 'missing_script';
    if (!isErrorState) {
      return false;
    }
    // Only report error if the status file is recent (within 30s).
    // Stale errors from a crashed service should show as '未运行'.
    if (updatedAt <= 0) {
      return true;
    }
    final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(updatedAt));
    return age <= const Duration(seconds: 30);
  }

  bool get isPaused => phase == 'stopped' || status == 'stopped';

  bool get hasFreshUpdate {
    if (updatedAt <= 0) {
      return false;
    }
    final updated = DateTime.fromMillisecondsSinceEpoch(updatedAt);
    return DateTime.now().difference(updated) <= const Duration(seconds: 10);
  }

  String get updatedTimeLabel {
    if (updatedAt <= 0) {
      return '未刷新';
    }
    return DateFormat('HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(updatedAt));
  }

  String get scoreSummaryLabel {
    final parts = <String>[];
    final left = buttonStateFor('left');
    final right = buttonStateFor('right');
    if (left != null) {
      parts.add('L ${left.shortScoreLabel}');
    }
    if (right != null) {
      parts.add('R ${right.shortScoreLabel}');
    }
    return parts.join('   ');
  }

  String get detailSummaryLabel {
    final text = summary.trim();
    if (text.isEmpty || text == '检测服务状态已更新' || text == '正在等待检测服务状态...') {
      return '';
    }
    return text;
  }

  String get overallStatusLabel {
    if (hasError) {
      return '错误';
    }
    if (isPaused) {
      return '已暂停';
    }
    if (!serviceEnabled) {
      return '已关闭';
    }
    if (!serviceRunning || isUnavailable || !hasFreshUpdate) {
      return '未运行';
    }
    return '运行中';
  }

  String displayStateFor(String side) {
    final buttonState = buttonStateFor(side);
    if (buttonState == null) {
      return '无目标';
    }
    final normalizedState = buttonState.normalizedState;
    if (normalizedState == 'ready') {
      return '已停止';
    }
    if (normalizedState == 'target') {
      return '工作中';
    }
    return '无目标';
  }

  String operationLabelFor(String side) {
    if (_isOperationActiveFor(side)) {
      return '是';
    }
    return '否';
  }

  _WindsurfButtonState? buttonStateFor(String side) {
    for (final item in buttonStates) {
      if (item.name == side) {
        return item;
      }
    }
    return null;
  }

  bool _isOperationActiveFor(String side) {
    if (!actionExecuted) {
      return false;
    }
    final activeTarget = selectedTarget.isNotEmpty ? selectedTarget : lastActionTarget;
    return activeTarget == side;
  }

  bool sameSnapshot(_WindsurfDetectionStatus other) {
    return updatedAt == other.updatedAt &&
        status == other.status &&
        summary == other.summary &&
        actionExecuted == other.actionExecuted &&
        lastActionAt == other.lastActionAt;
  }

  factory _WindsurfDetectionStatus.fromJson(Map<String, dynamic> json) {
    final detectedTargetNames = ((json['detected_target_names'] as List?) ?? const <dynamic>[])
        .map((item) => item.toString())
        .where((item) => item.trim().isNotEmpty)
        .toList();
    final buttonStates = ((json['button_states'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => _WindsurfButtonState.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final recentCycles = ((json['recent_cycles'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => _WindsurfCycleEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    return _WindsurfDetectionStatus(
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      serviceRunning: json['service_running'] == true,
      serviceEnabled: json['service_enabled'] != false,
      phase: (json['phase'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? '').trim(),
      summary: (json['summary'] as String? ?? '').trim().isEmpty
          ? '检测服务状态已更新'
          : (json['summary'] as String? ?? '').trim(),
      selectedTarget: (json['selected_target'] as String? ?? '').trim(),
      candidateTarget: (json['candidate_target'] as String? ?? '').trim(),
      candidateStreak: (json['candidate_streak'] as num?)?.toInt() ?? 0,
      candidateWindowCount: (json['candidate_window_count'] as num?)?.toInt() ?? 0,
      confirmRounds: (json['confirm_rounds'] as num?)?.toInt() ?? 0,
      confirmRequiredHits: (json['confirm_required_hits'] as num?)?.toInt() ?? 0,
      actionExecuted: json['action_executed'] == true,
      lastActionTarget: (json['last_action_target'] as String? ?? '').trim(),
      lastActionStatus: (json['last_action_status'] as String? ?? '').trim(),
      lastActionAt: (json['last_action_at'] as num?)?.toInt() ?? 0,
      awaitingProgressReset: json['awaiting_progress_reset'] == true,
      awaitingProgressTarget: (json['awaiting_progress_target'] as String? ?? '').trim(),
      cooldownRemainingMs: (json['cooldown_remaining_ms'] as num?)?.toInt() ?? 0,
      quietRemainingMs: (json['quiet_remaining_ms'] as num?)?.toInt() ?? 0,
      holdoffRemainingMs: (json['holdoff_remaining_ms'] as num?)?.toInt() ?? 0,
      hasTargetButton: json['has_target_button'] == true,
      detectedTargetNames: detectedTargetNames,
      buttonStates: buttonStates,
      recentCycles: recentCycles,
    );
  }
}

class _WindsurfButtonState {
  final String name;
  final String state;
  final String observedState;
  final bool stable;
  final int samples;
  final double readyScore;
  final double targetScore;

  const _WindsurfButtonState({
    required this.name,
    required this.state,
    required this.observedState,
    required this.stable,
    required this.samples,
    required this.readyScore,
    required this.targetScore,
  });

  String get normalizedState {
    final label = observedState.isNotEmpty ? observedState : state;
    return label.trim().toLowerCase();
  }

  String get shortScoreLabel {
    return '${readyScore.toStringAsFixed(2)}/${targetScore.toStringAsFixed(2)}';
  }

  factory _WindsurfButtonState.fromJson(Map<String, dynamic> json) {
    return _WindsurfButtonState(
      name: (json['name'] as String? ?? '').trim(),
      state: (json['state'] as String? ?? '').trim(),
      observedState: (json['observed_state'] as String? ?? '').trim(),
      stable: json['stable'] == true,
      samples: (json['samples'] as num?)?.toInt() ?? 0,
      readyScore: (json['ready_score'] as num?)?.toDouble() ?? 0,
      targetScore: (json['target_score'] as num?)?.toDouble() ?? 0,
    );
  }
}

class _WindsurfCycleEntry {
  final int timestamp;
  final String phase;
  final String status;
  final String summary;
  final bool actionExecuted;
  final String selectedTarget;
  final List<_WindsurfButtonState> buttonStates;

  const _WindsurfCycleEntry({
    required this.timestamp,
    required this.phase,
    required this.status,
    required this.summary,
    required this.actionExecuted,
    required this.selectedTarget,
    required this.buttonStates,
  });

  String get timeLabel {
    if (timestamp <= 0) {
      return '--:--:--';
    }
    return DateFormat('HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(timestamp));
  }

  _WindsurfButtonState? buttonStateFor(String side) {
    for (final item in buttonStates) {
      if (item.name == side) {
        return item;
      }
    }
    return null;
  }

  String displayStateFor(String side) {
    final buttonState = buttonStateFor(side);
    if (buttonState == null) {
      return '无目标';
    }
    final normalizedState = buttonState.normalizedState;
    if (normalizedState == 'ready') {
      return '已停止';
    }
    if (normalizedState == 'target') {
      return '工作中';
    }
    return '无目标';
  }

  String get resultLabel {
    if (actionExecuted && selectedTarget.isNotEmpty) {
      return '执行$selectedTarget';
    }
    switch (status) {
      case 'candidate_confirming':
        return '确认中';
      case 'target_holdoff':
        return '轮候';
      case 'cooldown_active':
        return '冷却';
      case 'completed':
        return '已执行';
      case 'awaiting_progress_reset':
        return '等刷新';
      case 'interrupted':
      case 'pre_action_interrupted':
      case 'user_quiet':
        return '用户操作';
      case 'skipped_window_gate':
      case 'pre_action_blocked':
        return '窗口不符';
      case 'no_template_match':
        return '未识别';
      case 'disabled':
        return '已关闭';
      case 'error':
        return '错误';
      default:
        break;
    }
    if (summary.isNotEmpty) {
      return summary;
    }
    if (phase.isNotEmpty) {
      return phase;
    }
    return '--';
  }

  factory _WindsurfCycleEntry.fromJson(Map<String, dynamic> json) {
    final buttonStates = ((json['button_states'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => _WindsurfButtonState.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    return _WindsurfCycleEntry(
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      phase: (json['phase'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? '').trim(),
      summary: (json['summary'] as String? ?? '').trim(),
      actionExecuted: json['action_executed'] == true,
      selectedTarget: (json['selected_target'] as String? ?? '').trim(),
      buttonStates: buttonStates,
    );
  }
}

class _WindsurfAccountPoolStatus {
  final int loadedAt;
  final String currentEmail;
  final int totalAccounts;
  final int availableAccounts;
  final int activeAccounts;
  final int depletedAccounts;
  final int expiredAccounts;
  final int unknownAccounts;
  final int blockedAccounts;
  final int tokenReadyAccounts;
  final bool cooldownReady;
  final int cooldownRemaining;
  final bool currentHasToken;
  final String status;
  final String message;

  const _WindsurfAccountPoolStatus({
    required this.loadedAt,
    required this.currentEmail,
    required this.totalAccounts,
    required this.availableAccounts,
    required this.activeAccounts,
    required this.depletedAccounts,
    required this.expiredAccounts,
    required this.unknownAccounts,
    required this.blockedAccounts,
    required this.tokenReadyAccounts,
    required this.cooldownReady,
    required this.cooldownRemaining,
    required this.currentHasToken,
    required this.status,
    required this.message,
  });

  const _WindsurfAccountPoolStatus.empty()
      : loadedAt = 0,
        currentEmail = '',
        totalAccounts = 0,
        availableAccounts = 0,
        activeAccounts = 0,
        depletedAccounts = 0,
        expiredAccounts = 0,
        unknownAccounts = 0,
        blockedAccounts = 0,
        tokenReadyAccounts = 0,
        cooldownReady = true,
        cooldownRemaining = 0,
        currentHasToken = false,
        status = 'idle',
        message = '';

  String get currentEmailLabel => currentEmail.isEmpty ? '当前账号：未识别' : '当前账号：$currentEmail';

  String get detailLabel {
    final parts = <String>[
      '总数 $totalAccounts',
      '活跃 $activeAccounts',
      '未知 $unknownAccounts',
      'token $tokenReadyAccounts',
    ];
    if (!cooldownReady && cooldownRemaining > 0) {
      parts.add('切号冷却 ${_formatDuration(cooldownRemaining)}');
    }
    if (message.trim().isNotEmpty) {
      parts.add(message.trim());
    }
    return parts.join(' · ');
  }

  String get loadedTimeLabel {
    if (loadedAt <= 0) {
      return '未刷新';
    }
    return DateFormat('HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(loadedAt));
  }

  bool sameSnapshot(_WindsurfAccountPoolStatus other) {
    return currentEmail == other.currentEmail &&
        totalAccounts == other.totalAccounts &&
        availableAccounts == other.availableAccounts &&
        activeAccounts == other.activeAccounts &&
        depletedAccounts == other.depletedAccounts &&
        expiredAccounts == other.expiredAccounts &&
        unknownAccounts == other.unknownAccounts &&
        blockedAccounts == other.blockedAccounts &&
        tokenReadyAccounts == other.tokenReadyAccounts &&
        cooldownReady == other.cooldownReady &&
        cooldownRemaining == other.cooldownRemaining &&
        currentHasToken == other.currentHasToken &&
        status == other.status &&
        message == other.message;
  }

  factory _WindsurfAccountPoolStatus.fromJson(Map<String, dynamic> json) {
    return _WindsurfAccountPoolStatus(
      loadedAt: (json['loaded_at'] as num?)?.toInt() ?? 0,
      currentEmail: (json['current_email'] as String? ?? '').trim(),
      totalAccounts: (json['total_accounts'] as num?)?.toInt() ?? 0,
      availableAccounts: (json['available_accounts'] as num?)?.toInt() ?? 0,
      activeAccounts: (json['active_accounts'] as num?)?.toInt() ?? 0,
      depletedAccounts: (json['depleted_accounts'] as num?)?.toInt() ?? 0,
      expiredAccounts: (json['expired_accounts'] as num?)?.toInt() ?? 0,
      unknownAccounts: (json['unknown_accounts'] as num?)?.toInt() ?? 0,
      blockedAccounts: (json['blocked_accounts'] as num?)?.toInt() ?? 0,
      tokenReadyAccounts: (json['token_ready_accounts'] as num?)?.toInt() ?? 0,
      cooldownReady: json['cooldown_ready'] != false,
      cooldownRemaining: (json['cooldown_remaining'] as num?)?.toInt() ?? 0,
      currentHasToken: json['current_has_token'] == true,
      status: (json['status'] as String? ?? '').trim(),
      message: (json['message'] as String? ?? '').trim(),
    );
  }
}

class _AccountSection {
  final String title;
  final int count;
  final Color color;
  final IconData icon;
  final List<_WindsurfLocalAccountEntry> accounts;
  final bool initiallyExpanded;

  const _AccountSection({
    required this.title,
    required this.count,
    required this.color,
    required this.icon,
    required this.accounts,
    required this.initiallyExpanded,
  });
}

class _WindsurfLocalAccountEntry {
  final String email;
  final String quotaState;
  final int daily;
  final int weekly;
  final bool expired;
  final bool hasToken;
  final int autoSwitchBlockedUntil;
  final int purgeAfterAt;
  final String lastQuotaRefreshAt;
  final int nextRefreshAt;
  final String nextRefreshReason;
  final String nextRefreshTime;

  const _WindsurfLocalAccountEntry({
    required this.email,
    required this.quotaState,
    required this.daily,
    required this.weekly,
    required this.expired,
    required this.hasToken,
    required this.autoSwitchBlockedUntil,
    required this.purgeAfterAt,
    required this.lastQuotaRefreshAt,
    required this.nextRefreshAt,
    required this.nextRefreshReason,
    required this.nextRefreshTime,
  });

  bool get isInCooldown => autoSwitchBlockedUntil > DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool get canSwitch => !expired && quotaState != 'depleted' && quotaState != 'daily_depleted' && quotaState != 'weekly_depleted' && !isInCooldown;

  /// 分类：available / daily_reset / weekly_reset / expired
  String get category {
    if (expired || quotaState == 'expired') return 'expired';
    if (quotaState == 'daily_depleted') return 'daily_reset';
    if (quotaState == 'weekly_depleted') return 'weekly_reset';
    return 'available';
  }

  String get quotaStateLabel {
    if (expired || quotaState == 'expired') {
      return '已过期';
    }
    if (isInCooldown) {
      return '冷却中';
    }
    switch (quotaState) {
      case 'active':
        return '可用';
      case 'daily_depleted':
        return '日额度耗尽';
      case 'weekly_depleted':
        return '周额度耗尽';
      case 'depleted':
        return '没额度';
      case 'unknown':
        return '待刷新';
      default:
        return quotaState.isEmpty ? '未知' : quotaState;
    }
  }

  String get refreshLabel {
    if (nextRefreshTime.isNotEmpty) return '刷新 $nextRefreshTime';
    return '';
  }

  String get creditsLabel {
    final dailyText = daily >= 0 ? 'D $daily%' : 'D --';
    final weeklyText = weekly >= 0 ? 'W $weekly%' : 'W --';
    return '$dailyText / $weeklyText';
  }

  String get cooldownLabel {
    if (!isInCooldown) {
      return '';
    }
    final remaining = autoSwitchBlockedUntil - (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    return '冷却 ${_formatDuration(remaining)}';
  }

  String get purgeLabel {
    if (purgeAfterAt <= 0) {
      return '';
    }
    final remaining = purgeAfterAt - (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (remaining <= 0) {
      return '待清理';
    }
    return '保留 ${_formatDuration(remaining)}';
  }

  factory _WindsurfLocalAccountEntry.fromJson(Map<String, dynamic> json) {
    final credits = Map<String, dynamic>.from((json['credits'] as Map?) ?? const <String, dynamic>{});
    final authToken = (json['auth_token'] as String? ?? '').trim();
    final token = (json['token'] as String? ?? '').trim();
    return _WindsurfLocalAccountEntry(
      email: (json['email'] as String? ?? '').trim(),
      quotaState: (json['quota_state'] as String? ?? '').trim(),
      daily: (credits['daily'] as num?)?.toInt() ?? -1,
      weekly: (credits['weekly'] as num?)?.toInt() ?? -1,
      expired: credits['expired'] == true,
      hasToken: authToken.isNotEmpty || token.isNotEmpty,
      autoSwitchBlockedUntil: (json['auto_switch_blocked_until'] as num?)?.toInt() ?? 0,
      purgeAfterAt: (json['purge_after_at'] as num?)?.toInt() ?? 0,
      lastQuotaRefreshAt: (json['last_quota_refresh_at'] as String? ?? '').trim(),
      nextRefreshAt: (json['next_refresh_at'] as num?)?.toInt() ?? 0,
      nextRefreshReason: (json['next_refresh_reason'] as String? ?? '').trim(),
      nextRefreshTime: (json['next_refresh_time'] as String? ?? '').trim(),
    );
  }
}

String _formatDuration(int totalSeconds) {
  final seconds = totalSeconds < 0 ? 0 : totalSeconds;
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (days > 0) {
    return '$days天$hours时';
  }
  if (hours > 0) {
    return '$hours时$minutes分';
  }
  return '$minutes分';
}
