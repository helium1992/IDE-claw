import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/app_config.dart';
import '../models/message.dart';

/// 连接模式
enum WsMode { cloud }

class WsService {
  final String serverUrl;
  final String sessionId;
  final String token;

  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  Timer? _pongTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;
  bool _isConnected = false;
  bool _waitingPong = false;
  bool _intentionalDisconnect = false;
  WsMode _currentMode = WsMode.cloud;

  final _messageController = StreamController<PushMessage>.broadcast();
  final _statusController = StreamController<WsStatus>.broadcast();
  final _remoteEventController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<PushMessage> get messages => _messageController.stream;
  Stream<WsStatus> get status => _statusController.stream;
  Stream<Map<String, dynamic>> get remoteEvents => _remoteEventController.stream;

  WsService({
    required this.serverUrl,
    required this.sessionId,
    required this.token,
  });

  String get _cloudWsUrl {
    final base = serverUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    return '$base/ws?token=$token&session_id=$sessionId&role=mobile';
  }

  bool get isConnected => _isConnected;
  WsMode get currentMode => _currentMode;
  String get modeLabel => '云中继';

  void connect() {
    if (_disposed) return;
    _disconnect();
    _statusController.add(WsStatus.connecting);
    _connectTo(_cloudWsUrl);
  }

  void _connectTo(String url) {
    if (_disposed) return;
    _disconnect();
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel!.stream.listen(
        _onMessage,
        onError: (e) {
          _onError(e);
        },
        onDone: () {
          _onDone();
        },
      );
      _currentMode = WsMode.cloud;
      _reconnectAttempts = 0;
      _isConnected = true;
      _intentionalDisconnect = false;
      _statusController.add(WsStatus.connected);
      _startHeartbeat();
    } catch (e) {
      _isConnected = false;
      _statusController.add(WsStatus.error);
      _scheduleReconnect();
    }
  }

  /// Call when app resumes from background
  void reconnectNow() {
    if (_disposed) return;
    _reconnectAttempts = 0;
    connect();
  }

  void ensureCloudConnection() {
    if (_disposed) return;
    if (_isConnected && _currentMode == WsMode.cloud) {
      return;
    }
    _reconnectAttempts = 0;
    _statusController.add(WsStatus.connecting);
    _connectTo(_cloudWsUrl);
  }

  void _disconnect() {
    _stopHeartbeat();
    _isConnected = false;
    _intentionalDisconnect = true;
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
  }

  void _onMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String);
      final type = json['type'] as String?;
      if (type == 'message') {
        final msgData = json['data'] as Map<String, dynamic>?;
        if (msgData != null) {
          final msg = PushMessage.fromJson(msgData);
          _messageController.add(msg);
          // Auto ACK
          _sendAck(msg.id);
        }
      } else if (type == 'remote_frame' || type == 'remote_status' || type == 'remote_input') {
        final rawData = json['data'];
        if (rawData is Map) {
          _remoteEventController.add({
            'type': type,
            'data': Map<String, dynamic>.from(rawData),
          });
        }
      } else if (type == 'connected') {
        // welcome message
      } else if (type == 'pong') {
        _waitingPong = false;
        _pongTimer?.cancel();
      }
    } catch (e) {
      // ignore parse errors
    }
  }

  void _onError(dynamic error) {
    _isConnected = false;
    _statusController.add(WsStatus.error);
    _scheduleReconnect();
  }

  void _onDone() {
    if (_intentionalDisconnect) {
      _intentionalDisconnect = false;
      return;
    }
    _isConnected = false;
    _statusController.add(WsStatus.disconnected);
    _stopHeartbeat();
    _scheduleReconnect();
  }

  void _sendAck(String messageId) {
    _send({'type': 'ack', 'message_id': messageId});
  }

  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  bool sendRemoteRelayInput(Map<String, dynamic> data) {
    if (!_isConnected || _channel == null) {
      return false;
    }
    _send({
      'type': 'remote_input',
      'data': data,
    });
    return true;
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(
      AppConfig.heartbeatInterval,
      (_) {
        _send({'type': 'ping'});
        _waitingPong = true;
        _pongTimer?.cancel();
        _pongTimer = Timer(AppConfig.pongTimeout, () {
          if (_waitingPong && !_disposed) {
            // Pong timeout = silent disconnect
            _isConnected = false;
            _statusController.add(WsStatus.disconnected);
            _disconnect();
            _scheduleReconnect();
          }
        });
      },
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pongTimer?.cancel();
    _pongTimer = null;
    _waitingPong = false;
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectAttempts++;
    // Cap delay at 15s, never give up
    final delaySec = (_reconnectAttempts * AppConfig.reconnectDelay.inSeconds).clamp(1, 15);
    final delay = Duration(seconds: delaySec);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, connect);
  }

  void dispose() {
    _disposed = true;
    _stopHeartbeat();
    _reconnectTimer?.cancel();
    _pongTimer?.cancel();
    _channel?.sink.close();
    _messageController.close();
    _remoteEventController.close();
    _statusController.close();
  }
}

enum WsStatus { connecting, connected, disconnected, error, failed }
