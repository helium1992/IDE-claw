import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/webrtc_service.dart';
import '../services/local_message_store.dart';
import '../services/notification_service.dart';

/// 通信模式：本地 IPC 或云端中继
enum CommMode { local, cloud }

class MessageProvider extends ChangeNotifier {
  final ApiService apiService;
  final WsService wsService;
  final String sessionId;
  WebRTCService? _webrtcService;
  late final LocalMessageStore _localStore;

  List<PushMessage> _messages = [];
  WsStatus _wsStatus = WsStatus.disconnected;
  P2PStatus _p2pStatus = P2PStatus.waitingHost;
  bool _loading = false;
  String? _error;
  bool _pcTyping = false;
  CommMode _commMode = CommMode.cloud;

  List<PushMessage> get messages => _messages;
  WsStatus get wsStatus => _wsStatus;
  P2PStatus get p2pStatus => _p2pStatus;
  WebRTCService? get webrtcService => _webrtcService;
  bool get loading => _loading;
  String? get error => _error;
  bool get isP2PConnected =>
      _p2pStatus == P2PStatus.transportConnected ||
      _p2pStatus == P2PStatus.waitingFirstFrame ||
      _p2pStatus == P2PStatus.streamReady;
  bool get pcTyping => _pcTyping;
  CommMode get commMode => _commMode;
  bool get isLocalMode => _commMode == CommMode.local;
  bool get _supportsRemoteWorkspaceRelay =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS) && !_supportsRemoteWorkspaceWebRtc;
  bool get _supportsRemoteWorkspaceWebRtc =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  final Set<String> _seenIds = {};
  Timer? _pollTimer;
  StreamSubscription<String>? _diagnosticSubscription;
  StreamSubscription<Map<String, dynamic>>? _remoteRelaySubscription;
  Uint8List? _remoteRelayFrameBytes;
  int _remoteRelayFrameSeq = -1;

  Uint8List? get remoteRelayFrameBytes => _remoteRelayFrameBytes;
  bool get hasRemoteRelayFrame => _remoteRelayFrameBytes != null;

  /// 回复回调（本地 IPC 用）
  void Function(String text)? onReplyCallback;

  MessageProvider({
    required this.apiService,
    required this.wsService,
    required this.sessionId,
  }) {
    _localStore = LocalMessageStore(sessionId);
    Future<void> init() async {
      await _loadLocal();

      // Listen to incoming messages
      wsService.messages.listen((msg) {
        // typing信号忽略（默认一直显示省略号）
        if (msg.msgType == 'typing') return;
        // stop_typing：AI回复完毕，隐藏省略号
        if (msg.msgType == 'stop_typing') {
          _pcTyping = false;
          notifyListeners();
          return;
        }
        if (_shouldIgnoreSyntheticUnsupportedCommandWarning(msg)) {
          _seenIds.add(msg.id);
          return;
        }
        // 本地模式下忽略 WS 消息（消息由本地 IPC 投递）
        if (_commMode == CommMode.local) return;
        // 普通消息
        if (!_seenIds.contains(msg.id)) {
          _seenIds.add(msg.id);
          _messages.add(msg);
          _persistLocal();
          // PC发来消息说明AI已完成输入，隐藏省略号
          if (msg.sender == 'pc') {
            _pcTyping = false;
            NotificationService().showMessageNotification(
              title: '新消息',
              body: msg.content.length > 100
                  ? '${msg.content.substring(0, 100)}...'
                  : msg.content,
            );
          }
          notifyListeners();
        }
      });

      // Listen to WebSocket status
      wsService.status.listen((status) {
        _wsStatus = status;
        // WebSocket重连成功时立即拉取漏接的消息
        if (status == WsStatus.connected) {
          _pollNewMessages();
        }
        notifyListeners();
      });

      // Periodic polling as WebSocket fallback (every 15s)
      _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _pollNewMessages());

      if (_supportsRemoteWorkspaceRelay) {
        _remoteRelaySubscription?.cancel();
        _remoteRelaySubscription = wsService.remoteEvents.listen(_handleRemoteRelayEvent);
      }

      // 启动WebRTC P2P监听
      if (_supportsRemoteWorkspaceWebRtc) {
        _initWebRTC();
      }
    }

    init();
  }

  void _initWebRTC() {
    _webrtcService = WebRTCService(
      serverUrl: apiService.serverUrl,
      sessionId: sessionId,
      token: apiService.token,
    );
    _webrtcService!.status.listen((status) {
      _p2pStatus = status;
      notifyListeners();
    });
    _webrtcService!.messages.listen((data) {
      final content = data['content'] as String? ?? '';
      if (content.isNotEmpty) {
        final id = 'p2p_${DateTime.now().millisecondsSinceEpoch}';
        final sender = data['sender'] as String? ?? 'pc';
        if (!_seenIds.contains(id)) {
          _seenIds.add(id);
          _messages.add(PushMessage(
            id: id,
            sessionId: sessionId,
            content: content,
            msgType: 'text',
            sender: sender,
            createdAt: DateTime.now().toUtc(),
          ));
          if (sender == 'pc') {
            _pcTyping = false;
          }
          _persistLocal();
          notifyListeners();
        }
      }
    });
    _diagnosticSubscription?.cancel();
    _diagnosticSubscription = _webrtcService!.diagnostics.listen(_appendDiagnosticMessage);
    _webrtcService!.startListening();
  }

  void _appendDiagnosticMessage(String text) {
    final id = 'diag_${DateTime.now().microsecondsSinceEpoch}';
    final msg = PushMessage(
      id: id,
      sessionId: sessionId,
      content: text,
      msgType: 'status',
      sender: 'system',
      createdAt: DateTime.now().toUtc(),
    );
    _seenIds.add(id);
    _messages.add(msg);
    _persistLocal();
    notifyListeners();
  }

  void _handleRemoteRelayEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    final data = event['data'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    if (type == 'remote_status') {
      final status = (data['status'] as String? ?? '').trim();
      if (status == 'host_started' || status == 'waiting_input') {
        _p2pStatus = P2PStatus.connectingRelay;
        notifyListeners();
      } else if (status == 'stopped') {
        _remoteRelayFrameBytes = null;
        _remoteRelayFrameSeq = -1;
        _p2pStatus = P2PStatus.disconnected;
        notifyListeners();
      }
      return;
    }
    if (type != 'remote_frame') {
      return;
    }
    final seq = (data['seq'] as num?)?.toInt() ?? 0;
    if (seq <= _remoteRelayFrameSeq) {
      return;
    }
    final frameBase64 = (data['frame_base64'] as String? ?? '').trim();
    if (frameBase64.isEmpty) {
      return;
    }
    try {
      _remoteRelayFrameBytes = base64Decode(frameBase64);
      _remoteRelayFrameSeq = seq;
      _p2pStatus = P2PStatus.streamReady;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _loadLocal() async {
    final local = await _localStore.loadMessages();
    final filtered = local
        .where((msg) => !_shouldIgnoreSyntheticUnsupportedCommandWarning(msg))
        .toList();
    if (filtered.length != local.length) {
      _localStore.saveMessages(filtered);
    }
    if (filtered.isNotEmpty && _messages.isEmpty) {
      _messages = filtered;
      _seenIds.clear();
      for (final m in _messages) {
        _seenIds.add(m.id);
      }
      _sortMessages();
      notifyListeners();
    }
  }

  /// 按 createdAt 排序消息列表
  void _sortMessages() {
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  bool _shouldIgnoreSyntheticUnsupportedCommandWarning(PushMessage msg) {
    if (msg.sender != 'pc') {
      return false;
    }
    final text = (msg.caption.isNotEmpty ? msg.caption : msg.content).trim();
    const ignoredWarnings = <String>{
      '⚠️ 暂不支持的命令: reply',
      '暂不支持的命令: reply',
      '⚠️ 暂不支持的命令: file_uploaded',
      '暂不支持的命令: file_uploaded',
    };
    return ignoredWarnings.contains(text);
  }

  void _persistLocal() {
    _localStore.saveMessages(_messages);
  }

  Future<void> _pollNewMessages() async {
    try {
      final data = await apiService.getMessagesRaw(sessionId, null);
      final list = data['messages'] as List? ?? [];

      bool changed = false;
      for (final m in list) {
        final msg = PushMessage.fromJson(m);
        if (_shouldIgnoreSyntheticUnsupportedCommandWarning(msg)) {
          _seenIds.add(msg.id);
          continue;
        }
        if (!_seenIds.contains(msg.id)) {
          _seenIds.add(msg.id);
          _messages.add(msg);
          changed = true;
          // 后台时弹系统通知
          if (msg.sender == 'pc') {
            _pcTyping = false;
            NotificationService().showMessageNotification(
              title: '新消息',
              body: msg.content.length > 100
                  ? '${msg.content.substring(0, 100)}...'
                  : msg.content,
            );
          }
        }
      }
      // typing状态仅由WebSocket的typing/stop_typing消息控制，不从轮询同步
      if (changed) {
        _sortMessages();
        _persistLocal();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> loadHistory() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      // 从服务器拉取新消息，合并到本地（不覆盖）
      final serverMsgs = await apiService.getMessages(sessionId, null);
      bool changed = false;
      for (final m in serverMsgs) {
        if (_shouldIgnoreSyntheticUnsupportedCommandWarning(m)) {
          _seenIds.add(m.id);
          continue;
        }
        if (m.sender == 'pc') {
          _pcTyping = false;
        }
        if (!_seenIds.contains(m.id)) {
          _seenIds.add(m.id);
          _messages.add(m);
          changed = true;
        }
      }
      if (changed) {
        _sortMessages();
        _persistLocal();
      }
      _error = null;
    } catch (e) {
      // 服务器不可用时不报错，本地消息已加载
      if (_messages.isEmpty) {
        _error = '加载消息失败: $e';
      }
    }
    _loading = false;
    notifyListeners();
  }

  static const _commandLabels = {
    'screenshot': '📸 截图',
    'continue_opt': '▶️ 继续优化',
    'stop_opt': '⏹️ 停止优化',
    'get_status': '📊 获取状态',
    'launch_windsurf': '🚀 启动 Windsurf',
    'start_remote_host': '🖥️ 操控电脑',
    'stop_remote_host': '🛑 结束远控',
  };

  Future<void> sendCommand(String command, {String params = '{}', String? displayText}) async {
    // 用户发消息后重新显示省略号（AI开始工作）
    _pcTyping = true;
    final label = displayText ?? _commandLabels[command] ?? '📲 $command';
    final tempId = 'local_${DateTime.now().millisecondsSinceEpoch}';
    final msg = PushMessage(
      id: tempId,
      sessionId: sessionId,
      content: label,
      msgType: 'text',
      sender: 'mobile',
      createdAt: DateTime.now().toUtc(),
      sendStatus: SendStatus.sending,
    );
    _seenIds.add(tempId);
    _messages.add(msg);
    notifyListeners();

    try {
      final result = await apiService.sendCommand(sessionId, command, params);
      final cmdId = result['command_id'] as String? ?? '';
      if (cmdId.isNotEmpty) {
        final serverId = 'cmd_$cmdId';
        final alreadyExists = _messages.any((m) => m.id == serverId);
        if (alreadyExists) {
          // WS已收到服务器消息，删除本地临时消息
          _messages.removeWhere((m) => m.id == tempId);
          _seenIds.remove(tempId);
        } else {
          // 将本地消息ID替换为服务器ID，这样持久化后重启也能正确去重
          _seenIds.remove(tempId);
          msg.id = serverId;
          _seenIds.add(serverId);
        }
      }
      msg.sendStatus = SendStatus.sent;
      _persistLocal();
      notifyListeners();
    } catch (e) {
      // 自动重试（最多3次，间隔2秒）
      await _autoRetrySendCommand(msg, tempId, command, params, 1);
    }
  }

  Future<void> _autoRetrySendCommand(PushMessage msg, String tempId, String command, String params, int attempt) async {
    if (attempt > 3) {
      msg.sendStatus = SendStatus.failed;
      _error = '发送失败（已重试3次）';
      notifyListeners();
      return;
    }
    await Future<void>.delayed(Duration(seconds: 2 * attempt));
    try {
      final result = await apiService.sendCommand(sessionId, command, params);
      final cmdId = result['command_id'] as String? ?? '';
      if (cmdId.isNotEmpty) {
        final serverId = 'cmd_$cmdId';
        final alreadyExists = _messages.any((m) => m.id == serverId);
        if (alreadyExists) {
          _messages.removeWhere((m) => m.id == tempId);
          _seenIds.remove(tempId);
        } else {
          _seenIds.remove(tempId);
          msg.id = serverId;
          _seenIds.add(serverId);
        }
      }
      msg.sendStatus = SendStatus.sent;
      _persistLocal();
      notifyListeners();
    } catch (e) {
      await _autoRetrySendCommand(msg, tempId, command, params, attempt + 1);
    }
  }

  Future<void> retrySend(PushMessage msg) async {
    if (msg.sendStatus != SendStatus.failed) return;
    msg.sendStatus = SendStatus.sending;
    notifyListeners();
    final params = '{"text": ${_jsonEscape(msg.content)}}';
    await _autoRetrySendReply(msg, 'reply', params, 0);
  }

  Future<void> _autoRetrySendReply(PushMessage msg, String command, String params, int attempt) async {
    if (attempt > 3) {
      msg.sendStatus = SendStatus.failed;
      notifyListeners();
      return;
    }
    if (attempt > 0) {
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
    try {
      final result = await apiService.sendCommand(sessionId, command, params);
      final cmdId = result['command_id'] as String? ?? '';
      if (cmdId.isNotEmpty) {
        final serverId = 'cmd_$cmdId';
        if (_messages.any((m) => m.id == serverId)) {
          _messages.remove(msg);
          _seenIds.remove(msg.id);
        } else {
          _seenIds.remove(msg.id);
          msg.id = serverId;
          _seenIds.add(serverId);
        }
      }
      msg.sendStatus = SendStatus.sent;
      _persistLocal();
      notifyListeners();
    } catch (e) {
      await _autoRetrySendReply(msg, command, params, attempt + 1);
    }
  }

  Future<void> sendFile(String fileName, List<int> fileBytes, {String caption = ''}) async {
    // 用户发文件后重新显示省略号
    _pcTyping = true;
    final tempId = 'local_file_${DateTime.now().millisecondsSinceEpoch}';
    final displayText = caption.isNotEmpty
        ? '$caption\n📎 $fileName'
        : '📎 发送中: $fileName';
    final msg = PushMessage(
      id: tempId,
      sessionId: sessionId,
      content: displayText,
      msgType: 'file',
      sender: 'mobile',
      createdAt: DateTime.now().toUtc(),
      sendStatus: SendStatus.sending,
      fileId: tempId,
      fileName: fileName,
      caption: caption,
    );
    _seenIds.add(tempId);
    _messages.add(msg);
    notifyListeners();

    try {
      final result = await apiService.uploadFile(
        sessionId, '', fileName, fileBytes,
        caption: caption, sender: 'mobile',
      );
      if (result['success'] == true) {
        final serverId = result['file_id'] as String? ?? '';
        if (serverId.isNotEmpty) {
          final alreadyExists = _messages.any((m) => m.id == serverId);
          if (alreadyExists) {
            _messages.removeWhere((m) => m.id == tempId);
            _seenIds.remove(tempId);
          } else {
            _seenIds.remove(tempId);
            msg.id = serverId;
            msg.fileId = serverId;
            _seenIds.add(serverId);
          }
        }
        msg.sendStatus = SendStatus.sent;
        _persistLocal();
        notifyListeners();
      } else {
        msg.sendStatus = SendStatus.failed;
        _error = '文件上传失败: ${result['error'] ?? 'unknown'}';
        notifyListeners();
      }
    } catch (e) {
      msg.sendStatus = SendStatus.failed;
      _error = '文件上传失败: $e';
      notifyListeners();
    }
  }

  /// 切换通信模式
  void toggleCommMode() {
    _commMode = _commMode == CommMode.cloud ? CommMode.local : CommMode.cloud;
    notifyListeners();
  }

  Future<void> sendReply(String text) async {
    if (_commMode == CommMode.local) {
      // 本地模式：只走本地 IPC，不走云端
      onReplyCallback?.call(text);
      // 添加本地消息到聊天（因为不走服务器，不会有WS回传）
      final tempId = 'local_${DateTime.now().millisecondsSinceEpoch}';
      final msg = PushMessage(
        id: tempId,
        sessionId: sessionId,
        content: text,
        msgType: 'text',
        sender: 'mobile',
        createdAt: DateTime.now().toUtc(),
        sendStatus: SendStatus.sent,
      );
      _seenIds.add(tempId);
      _messages.add(msg);
      _pcTyping = true;
      _persistLocal();
      notifyListeners();
    } else {
      // 云端模式：走服务器 API（也通知本地 IPC 以兼容）
      onReplyCallback?.call(text);
      final params = '{"text": ${_jsonEscape(text)}}';
      await sendCommand('reply', params: params, displayText: text);
    }
  }

  void ensureRemoteListening() {
    if (_supportsRemoteWorkspaceRelay) {
      _remoteRelayFrameBytes = null;
      _remoteRelayFrameSeq = -1;
      _p2pStatus = P2PStatus.waitingHost;
      wsService.ensureCloudConnection();
      notifyListeners();
      return;
    }
    _webrtcService?.startListening();
  }

  void markRemoteHostRequested() {
    if (_supportsRemoteWorkspaceRelay) {
      _remoteRelayFrameBytes = null;
      _remoteRelayFrameSeq = -1;
      _p2pStatus = P2PStatus.connectingRelay;
      notifyListeners();
      return;
    }
    _webrtcService?.markRemoteHostRequested();
  }

  Future<bool> sendRemoteInput(Map<String, dynamic> data) async {
    if (_supportsRemoteWorkspaceRelay) {
      return wsService.sendRemoteRelayInput({
        ...data,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
    return _webrtcService?.sendRemoteInput(data) ?? false;
  }

  /// 添加本地 IPC 推送的消息（不走服务器）
  void addLocalMessage(PushMessage msg) {
    if (!_seenIds.contains(msg.id)) {
      _seenIds.add(msg.id);
      _messages.add(msg);
      _pcTyping = false;
      _persistLocal();
      notifyListeners();
    }
  }

  String _jsonEscape(String s) {
    return '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n')}"';
  }

  /// 当前连接模式标签
  String get connectionMode {
    if (_commMode == CommMode.local) return '本地服务';
    return wsService.modeLabel;
  }

  void connectWs() {
    wsService.connect();
  }

  void reconnectWs() {
    wsService.reconnectNow();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _diagnosticSubscription?.cancel();
    _remoteRelaySubscription?.cancel();
    _webrtcService?.dispose();
    wsService.dispose();
    super.dispose();
  }
}
