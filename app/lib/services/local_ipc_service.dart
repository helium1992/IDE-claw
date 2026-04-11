import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 本地 IPC 服务：在 localhost 上运行 HTTP 服务器，
/// 让同一台电脑上的 dialog.py 直接推送消息并接收回复，无需绕远程服务器。
class LocalIpcService {
  static const int defaultPort = 13800;

  /// 根据 sessionId 计算唯一端口，避免多实例冲突
  static int portForSession(String sessionId) {
    if (sessionId.isEmpty || sessionId == 'your-session-id') {
      return defaultPort;
    }
    int sum = 0;
    for (int i = 0; i < sessionId.length; i++) {
      sum += sessionId.codeUnitAt(i);
    }
    return defaultPort + 1 + (sum % 99);
  }

  HttpServer? _server;
  final int port;
  final String sessionId;
  bool _running = false;

  /// 当前等待回复的 HTTP 请求
  Completer<Map<String, dynamic>>? _pendingReply;

  /// 新消息流（UI 监听此流来显示本地推送的消息）
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  /// 是否有消息正在等待回复
  bool get hasPendingReply =>
      _pendingReply != null && !_pendingReply!.isCompleted;

  /// 当前通信模式（由 UI 层同步更新）
  String commMode = 'cloud';

  LocalIpcService({this.port = defaultPort, this.sessionId = ''});

  /// 启动本地 HTTP 服务器
  Future<bool> start() async {
    if (_running) return true;
    try {
      _server = await HttpServer.bind('127.0.0.1', port, shared: true);
      _running = true;
      _server!.listen(_handleRequest);
      return true;
    } catch (e) {
      // 端口占用等错误，静默失败
      return false;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // CORS headers for local requests
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST');
    request.response.headers
        .add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = 200;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    if (path == '/ping' && request.method == 'GET') {
      await _handlePing(request);
    } else if (path == '/message' && request.method == 'POST') {
      await _handleMessage(request);
    } else {
      request.response.statusCode = 404;
      request.response.write('Not Found');
      await request.response.close();
    }
  }

  /// GET /ping — 健康检查，dialog.py 用来检测桌面端是否在运行
  Future<void> _handlePing(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'status': 'ok',
      'has_pending': hasPendingReply,
      'session_id': sessionId,
      'comm_mode': commMode,
    }));
    await request.response.close();
  }

  /// POST /message — 接收消息并等待用户回复（长轮询）
  Future<void> _handleMessage(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final message = data['message'] as String? ?? '';

      if (message.isEmpty) {
        request.response.statusCode = 400;
        request.response.write('{"error": "empty message"}');
        await request.response.close();
        return;
      }

      // 通知 UI 显示新消息
      _messageController.add(data);

      // 创建 Completer 等待用户回复
      _pendingReply = Completer<Map<String, dynamic>>();

      try {
        // 最长等待 30 分钟
        final reply = await _pendingReply!.future.timeout(
          const Duration(minutes: 30),
          onTimeout: () => {'text': '', 'action': 'timeout'},
        );

        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(reply));
      } catch (e) {
        request.response.statusCode = 500;
        request.response.write('{"error": "internal error"}');
      }
    } catch (e) {
      request.response.statusCode = 400;
      request.response.write('{"error": "invalid request"}');
    }
    await request.response.close();
  }

  /// 提交用户回复（由 UI 调用）
  void submitReply(String text, {String action = 'reply'}) {
    if (_pendingReply != null && !_pendingReply!.isCompleted) {
      _pendingReply!.complete({
        'text': text,
        'action': action,
        'source': 'desktop',
      });
    }
  }

  /// 停止服务器
  Future<void> stop() async {
    _running = false;
    // 取消任何等待中的回复
    if (_pendingReply != null && !_pendingReply!.isCompleted) {
      _pendingReply!.complete({'text': '', 'action': 'shutdown'});
    }
    await _server?.close();
    _server = null;
  }

  void dispose() {
    stop();
    _messageController.close();
  }
}
