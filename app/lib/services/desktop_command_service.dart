import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:win32/win32.dart';

import 'api_service.dart';

DynamicLibrary? _user32;

typedef _MouseEventNative = Void Function(
  Uint32 dwFlags,
  Uint32 dx,
  Uint32 dy,
  Uint32 dwData,
  IntPtr dwExtraInfo,
);
typedef _MouseEventDart = void Function(int, int, int, int, int);
_MouseEventDart? _mouseEventBinding;

typedef _KeybdEventNative = Void Function(
  Uint8 bVk,
  Uint8 bScan,
  Uint32 dwFlags,
  IntPtr dwExtraInfo,
);
typedef _KeybdEventDart = void Function(int, int, int, int);
_KeybdEventDart? _keybdEventBinding;

DynamicLibrary _user32Library() {
  if (!Platform.isWindows) {
    throw UnsupportedError('user32.dll is only available on Windows');
  }
  return _user32 ??= DynamicLibrary.open('user32.dll');
}

_MouseEventDart get _mouseEvent {
  return _mouseEventBinding ??=
      _user32Library().lookupFunction<_MouseEventNative, _MouseEventDart>(
    'mouse_event',
  );
}

_KeybdEventDart get _keybdEvent {
  return _keybdEventBinding ??=
      _user32Library().lookupFunction<_KeybdEventNative, _KeybdEventDart>(
    'keybd_event',
  );
}

class DesktopCommandService {
  static const String _turnUrlsValue = String.fromEnvironment('IDE_CLAW_TURN_URLS');
  static const String _turnUsername = String.fromEnvironment('IDE_CLAW_TURN_USERNAME');
  static const String _turnCredential = String.fromEnvironment('IDE_CLAW_TURN_CREDENTIAL');

  final ApiService apiService;
  final String sessionId;

  bool _running = false;
  bool _disposed = false;
  final Set<String> _watchedSessionIds = <String>{};
  final Set<String> _sessionLoops = <String>{};
  Timer? _sessionRefreshTimer;
  String? _activeRemoteSessionId;
  String? _activeRemoteAttemptId;
  _RemoteTransportMode _activeRemoteTransportMode = _RemoteTransportMode.direct;
  bool _remoteControlConnected = false;
  bool _relayFallbackTriggered = false;

  RTCPeerConnection? _pc;
  RTCDataChannel? _controlChannel;
  MediaStream? _screenStream;
  Timer? _signalPollTimer;
  WebSocketChannel? _relayChannel;
  Timer? _relayFrameTimer;
  Timer? _remoteTransportTimeoutTimer;
  final List<Map<String, dynamic>> _pendingRemoteIceCandidates = <Map<String, dynamic>>[];
  bool _remoteDescriptionReady = false;
  List<String>? _runtimeTurnUrls;
  String? _runtimeTurnUsername;
  String? _runtimeTurnCredential;
  DateTime? _turnCredentialsExpiresAt;
  Future<void>? _turnConfigLoadFuture;
  int _localIceCandidateLogCount = 0;
  int _remoteIceCandidateLogCount = 0;

  static const int _maxCandidateLogsPerAttempt = 6;

  DesktopCommandService({
    required this.apiService,
    required this.sessionId,
  });

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${apiService.token}',
        'Content-Type': 'application/json; charset=utf-8',
      };

  Uri _serverWsUri(String targetSessionId, {String role = 'pc'}) {
    final baseUri = Uri.parse(apiService.serverUrl);
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    return baseUri.replace(
      scheme: scheme,
      path: '/ws',
      queryParameters: {
        'token': apiService.token,
        'session_id': targetSessionId,
        'role': role,
      },
    );
  }

  List<String> get _envTurnUrls => _turnUrlsValue
      .split(',')
      .map((url) => url.trim())
      .where((url) => url.isNotEmpty)
      .toList(growable: false);

  List<String> get _turnUrls {
    final runtimeTurnUrls = _runtimeTurnUrls;
    if (runtimeTurnUrls != null && runtimeTurnUrls.isNotEmpty) {
      return runtimeTurnUrls;
    }
    return _envTurnUrls;
  }

  String get _resolvedTurnUsername {
    final runtimeTurnUsername = (_runtimeTurnUsername ?? '').trim();
    if (runtimeTurnUsername.isNotEmpty) {
      return runtimeTurnUsername;
    }
    return _turnUsername;
  }

  String get _resolvedTurnCredential {
    final runtimeTurnCredential = (_runtimeTurnCredential ?? '').trim();
    if (runtimeTurnCredential.isNotEmpty) {
      return runtimeTurnCredential;
    }
    return _turnCredential;
  }

  bool get _hasRelayConfig => _turnUrls.isNotEmpty;

  Future<void> _ensureTurnCredentialsLoaded(String targetSessionId) async {
    final expiresAt = _turnCredentialsExpiresAt;
    if (expiresAt != null && DateTime.now().isBefore(expiresAt)) {
      return;
    }
    final pending = _turnConfigLoadFuture;
    if (pending != null) {
      await pending;
      return;
    }
    final future = _loadTurnCredentials(targetSessionId);
    _turnConfigLoadFuture = future;
    try {
      await future;
    } finally {
      _turnConfigLoadFuture = null;
    }
  }

  Future<void> _loadTurnCredentials(String targetSessionId) async {
    try {
      final uri = Uri.parse('${apiService.serverUrl}/api/webrtc/turn-credentials').replace(
        queryParameters: {
          'session_id': targetSessionId,
          'role': 'pc',
        },
      );
      _logRemoteTransport('请求 TURN 凭据 role=pc', sourceSessionId: targetSessionId);
      final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        _logRemoteTransport(
          'TURN 凭据请求失败 code=${response.statusCode}',
          sourceSessionId: targetSessionId,
        );
        return;
      }
      final data = jsonDecode(response.body);
      if (data is! Map) {
        _logRemoteTransport('TURN 凭据响应不是对象', sourceSessionId: targetSessionId);
        return;
      }
      final enabled = data['enabled'] == true;
      final urls = (data['urls'] as List? ?? const [])
          .map((url) => url.toString().trim())
          .where((url) => url.isNotEmpty)
          .toList(growable: false);
      if (!enabled || urls.isEmpty) {
        _turnCredentialsExpiresAt = DateTime.now().add(const Duration(seconds: 60));
        _runtimeTurnUrls = null;
        _runtimeTurnUsername = null;
        _runtimeTurnCredential = null;
        _logRemoteTransport('TURN 未启用或返回空 urls', sourceSessionId: targetSessionId);
        return;
      }
      final ttlSeconds = (data['ttl_seconds'] as num?)?.toInt() ?? 3600;
      final refreshLeadSeconds = ttlSeconds > 120 ? 60 : 0;
      _turnCredentialsExpiresAt = DateTime.now().add(
        Duration(seconds: ttlSeconds - refreshLeadSeconds),
      );
      _runtimeTurnUrls = urls;
      final username = (data['username'] as String? ?? '').trim();
      final credential = (data['credential'] as String? ?? '').trim();
      _runtimeTurnUsername = username.isEmpty ? null : username;
      _runtimeTurnCredential = credential.isEmpty ? null : credential;
      _logRemoteTransport(
        'TURN 就绪 urls=${urls.join(', ')} username=$username ttl=${ttlSeconds}s',
        sourceSessionId: targetSessionId,
      );
    } catch (e) {
      _logRemoteTransport('TURN 凭据请求异常: $e', sourceSessionId: targetSessionId);
    }
  }

  String _newAttemptId() => DateTime.now().microsecondsSinceEpoch.toString();

  _RemoteTransportMode _parseTransportMode(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return normalized == 'relay'
        ? _RemoteTransportMode.relay
        : _RemoteTransportMode.direct;
  }

  List<String> _preferredRelayTurnUrls() {
    final directTcpTurnUrls = _turnUrls
        .where((url) {
          final normalized = url.trim().toLowerCase();
          return normalized.startsWith('turn:') && normalized.contains('transport=tcp');
        })
        .toList(growable: false);
    if (directTcpTurnUrls.isNotEmpty) {
      return directTcpTurnUrls;
    }
    final anyTcpTurnUrls = _turnUrls
        .where((url) => url.trim().toLowerCase().contains('transport=tcp'))
        .toList(growable: false);
    if (anyTcpTurnUrls.isNotEmpty) {
      return anyTcpTurnUrls;
    }
    return _turnUrls;
  }

  List<Map<String, dynamic>> _buildIceServers(_RemoteTransportMode transportMode) {
    final servers = <Map<String, dynamic>>[];
    if (transportMode == _RemoteTransportMode.direct) {
      servers.addAll([
        {'urls': ['stun:stun.l.google.com:19302']},
        {'urls': ['stun:stun1.l.google.com:19302']},
        {'urls': ['stun:stun.cloudflare.com:3478']},
      ]);
    }
    final relayTurnUrls = transportMode == _RemoteTransportMode.relay
        ? _preferredRelayTurnUrls()
        : _turnUrls;
    if (relayTurnUrls.isNotEmpty) {
      servers.add({
        'urls': relayTurnUrls,
        if (_resolvedTurnUsername.isNotEmpty) 'username': _resolvedTurnUsername,
        if (_resolvedTurnCredential.isNotEmpty) 'credential': _resolvedTurnCredential,
      });
    }
    return servers;
  }

  Map<String, dynamic> _buildPeerConfiguration(_RemoteTransportMode transportMode) {
    return <String, dynamic>{
      'iceServers': _buildIceServers(transportMode),
      if (transportMode == _RemoteTransportMode.relay && _hasRelayConfig)
        'iceTransportPolicy': 'relay',
    };
  }

  String _enumLabel(Object? value) {
    return value?.toString().split('.').last ?? 'unknown';
  }

  String _candidateType(String candidate) {
    final match = RegExp(r'\btyp\s+([a-zA-Z0-9]+)').firstMatch(candidate);
    return match?.group(1) ?? 'unknown';
  }

  String _candidateProtocol(String candidate) {
    final parts = candidate.split(' ');
    if (parts.length >= 3) {
      return parts[2].trim().toLowerCase();
    }
    return 'unknown';
  }

  void _logRemoteTransport(
    String message, {
    String? sourceSessionId,
    bool pushToPhone = true,
  }) {
    final text = '🧪 [桌面端远控] $message';
    debugPrint('DesktopCommandService[$sessionId] $text');
    final targetSessionId = sourceSessionId ?? _activeRemoteSessionId;
    if (!pushToPhone || targetSessionId == null || targetSessionId.isEmpty) {
      return;
    }
    unawaited(_pushText(text, sessionId: targetSessionId));
  }

  void _cancelRemoteTransportTimeout() {
    _remoteTransportTimeoutTimer?.cancel();
    _remoteTransportTimeoutTimer = null;
  }

  void _scheduleRemoteTransportTimeout(String sourceSessionId, String attemptId) {
    if (!_hasRelayConfig) {
      return;
    }
    _cancelRemoteTransportTimeout();
    _remoteTransportTimeoutTimer = Timer(const Duration(seconds: 12), () {
      if (_disposed ||
          _pc == null ||
          _remoteControlConnected ||
          _activeRemoteSessionId != sourceSessionId ||
          _activeRemoteAttemptId != attemptId ||
          _activeRemoteTransportMode != _RemoteTransportMode.direct) {
        return;
      }
      _relayFallbackTriggered = true;
      unawaited(
        _restartRemoteTransport(
          sourceSessionId,
          attemptId,
          _RemoteTransportMode.relay,
          announceFallback: true,
        ),
      );
    });
  }

  Future<void> start() async {
    if (_running || _disposed || !Platform.isWindows) {
      return;
    }
    _running = true;
    await _refreshWatchedSessions();
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshWatchedSessions(),
    );
  }

  Future<void> stop() async {
    _running = false;
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    _watchedSessionIds.clear();
    await _stopRemoteHost(pushMessage: false);
  }

  void dispose() {
    _disposed = true;
    _running = false;
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    _watchedSessionIds.clear();
    _signalPollTimer?.cancel();
    _signalPollTimer = null;
    _stopRemoteHost(pushMessage: false);
  }

  Future<void> _refreshWatchedSessions() async {
    if (!_running || _disposed) {
      return;
    }
    try {
      final sessions = await apiService.getSessions();
      final nextSessionIds = _selectWatchedSessionIds(sessions);
      if (_activeRemoteSessionId != null && _activeRemoteSessionId!.isNotEmpty) {
        nextSessionIds.add(_activeRemoteSessionId!);
      }
      _watchedSessionIds
        ..clear()
        ..addAll(nextSessionIds);
      for (final watchedSessionId in nextSessionIds) {
        _ensureSessionLoop(watchedSessionId);
      }
    } catch (e, stackTrace) {
      debugPrint('DesktopCommandService refresh sessions failed: $e\n$stackTrace');
    }
  }

  Set<String> _selectWatchedSessionIds(List<Map<String, dynamic>> sessions) {
    final localMachineName = Platform.localHostname.trim().toLowerCase();
    final allSessionIds = <String>{if (sessionId.trim().isNotEmpty) sessionId.trim()};
    final localSessionIds = <String>{};
    final unknownMachineSessionIds = <String>{};

    for (final session in sessions) {
      final id = (session['id'] as String? ?? '').trim();
      if (id.isEmpty) {
        continue;
      }
      allSessionIds.add(id);
      final machineName = (session['machine_name'] as String? ?? '').trim().toLowerCase();
      if (machineName.isEmpty) {
        unknownMachineSessionIds.add(id);
      } else if (machineName == localMachineName) {
        localSessionIds.add(id);
      }
    }

    if (localSessionIds.isNotEmpty) {
      return <String>{
        ...localSessionIds,
        ...unknownMachineSessionIds,
        if (sessionId.trim().isNotEmpty) sessionId.trim(),
      };
    }

    return allSessionIds;
  }

  void _ensureSessionLoop(String watchedSessionId) {
    if (watchedSessionId.isEmpty || _sessionLoops.contains(watchedSessionId)) {
      return;
    }
    _sessionLoops.add(watchedSessionId);
    unawaited(_commandLoopForSession(watchedSessionId));
  }

  Future<void> _commandLoopForSession(String watchedSessionId) async {
    try {
      while (_running && !_disposed && _watchedSessionIds.contains(watchedSessionId)) {
        try {
          await _waitAndHandleCommand(watchedSessionId);
        } catch (e, stackTrace) {
          debugPrint('DesktopCommandService loop[$watchedSessionId] error: $e\n$stackTrace');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    } finally {
      _sessionLoops.remove(watchedSessionId);
    }
  }

  Future<void> _waitAndHandleCommand(String sourceSessionId) async {
    final uri = Uri.parse('${apiService.serverUrl}/api/commands/wait').replace(
      queryParameters: {'session_id': sourceSessionId},
    );
    final response = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 70));
    if (response.statusCode != 200) {
      return;
    }

    final data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    final rawCommand = data['command'];
    if (rawCommand == null) {
      return;
    }

    final command = Map<String, dynamic>.from(rawCommand as Map);
    final commandId = command['id'] as String? ?? '';
    final commandName = command['command'] as String? ?? '';
    final params = _parseParams(command['params']);

    if (commandId.isEmpty || commandName.isEmpty) {
      return;
    }

    try {
      final result = await _handleCommand(sourceSessionId, commandName, params);
      await _postCommandResult(commandId, 'executed', result);
    } catch (e, stackTrace) {
      debugPrint('DesktopCommandService command error: $e\n$stackTrace');
      final errorText = '执行 $commandName 失败: $e';
      await _postCommandResult(commandId, 'failed', errorText);
      await _pushText('❌ $errorText', sessionId: sourceSessionId);
    }
  }

  Map<String, dynamic> _parseParams(Object? rawParams) {
    if (rawParams == null) {
      return <String, dynamic>{};
    }
    if (rawParams is Map<String, dynamic>) {
      return rawParams;
    }
    if (rawParams is Map) {
      return Map<String, dynamic>.from(rawParams);
    }
    if (rawParams is String && rawParams.trim().isNotEmpty) {
      try {
        return Map<String, dynamic>.from(jsonDecode(rawParams) as Map);
      } catch (_) {
        return <String, dynamic>{'raw': rawParams};
      }
    }
    return <String, dynamic>{};
  }

  Future<String> _handleCommand(
    String sourceSessionId,
    String command,
    Map<String, dynamic> params,
  ) async {
    switch (command) {
      case 'reply':
        return params['text'] as String? ?? 'reply received';
      case 'file_uploaded':
        return params['file_name'] as String? ?? 'file uploaded';
      case 'launch_windsurf':
        return _launchWindsurf(sourceSessionId);
      case 'start_remote_host':
        return _startRemoteHost(sourceSessionId);
      case 'stop_remote_host':
        return _stopRemoteHost(notifySessionId: sourceSessionId);
      default:
        final text = '暂不支持的命令: $command';
        await _pushText('⚠️ $text', sessionId: sourceSessionId);
        return text;
    }
  }

  Future<void> _postCommandResult(
    String commandId,
    String status,
    String result,
  ) async {
    final uri = Uri.parse('${apiService.serverUrl}/api/commands/$commandId/result');
    await http.post(
      uri,
      headers: _headers,
      body: jsonEncode({'status': status, 'result': result}),
    ).timeout(const Duration(seconds: 10));
  }

  Future<void> _pushText(String text, {required String sessionId}) async {
    final uri = Uri.parse('${apiService.serverUrl}/api/push');
    await http.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'session_id': sessionId,
        'content': text,
        'msg_type': 'text',
        'is_final': true,
      }),
    ).timeout(const Duration(seconds: 10));
  }

  Future<String> _launchWindsurf(String sourceSessionId) async {
    final envPath = Platform.environment['WINDSURF_PATH'];
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final programFiles = Platform.environment['ProgramFiles'] ?? '';
    final candidates = <String>{
      if (envPath != null && envPath.trim().isNotEmpty) envPath.trim(),
      if (localAppData.isNotEmpty)
        '$localAppData\\Programs\\Windsurf\\Windsurf.exe',
      if (localAppData.isNotEmpty)
        '$localAppData\\Programs\\codeium-windsurf\\Windsurf.exe',
      if (programFiles.isNotEmpty)
        '$programFiles\\Windsurf\\Windsurf.exe',
    };

    for (final path in candidates) {
      if (File(path).existsSync()) {
        await Process.start(
          path,
          const [],
          mode: ProcessStartMode.detached,
        );
        await _pushText('🚀 Windsurf 启动命令已发送', sessionId: sourceSessionId);
        return 'Windsurf launched: $path';
      }
    }

    final fallbackCommands = <List<String>>[
      ['cmd', '/c', 'start', '', 'windsurf'],
      ['cmd', '/c', 'start', '', 'Windsurf'],
      ['cmd', '/c', 'start', '', 'windsurf.exe'],
      ['cmd', '/c', 'start', '', 'Windsurf.exe'],
    ];

    for (final command in fallbackCommands) {
      try {
        await Process.start(
          command.first,
          command.sublist(1),
          mode: ProcessStartMode.detached,
          runInShell: true,
        );
        await _pushText('🚀 Windsurf 启动命令已发送', sessionId: sourceSessionId);
        return 'Windsurf launch requested via PATH';
      } catch (_) {}
    }

    throw Exception('未找到 Windsurf 可执行文件，请配置 WINDSURF_PATH 或确认已安装到默认目录');
  }

  Future<MediaStream> _captureCurrentScreenStream() async {
    final screenSources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
    );
    if (screenSources.isEmpty) {
      throw Exception('未检测到可共享的屏幕，请确认桌面已登录且显示器可用');
    }

    final currentScreenSource = screenSources.first;
    final screenStream = await navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'deviceId': {
          'exact': currentScreenSource.id,
        },
        'mandatory': {
          'frameRate': 12.0,
        },
      },
    });
    if (screenStream.getVideoTracks().isEmpty) {
      throw Exception('桌面抓屏未返回视频轨道');
    }
    return screenStream;
  }

  Future<String> _startRemoteHost(String sourceSessionId) async {
    if (!Platform.isWindows) {
      throw Exception('远控宿主目前仅支持 Windows 桌面端');
    }

    if (_pc != null &&
        _activeRemoteSessionId == sourceSessionId &&
        _remoteControlConnected) {
      return 'remote host already running';
    }

    if (_activeRemoteSessionId != null && _activeRemoteSessionId != sourceSessionId) {
      await _stopRemoteHost();
    } else if (_activeRemoteSessionId == sourceSessionId) {
      await _stopRemoteHost(pushMessage: false, notifySessionId: sourceSessionId);
    }

    _activeRemoteSessionId = sourceSessionId;
    final attemptId = DateTime.now().microsecondsSinceEpoch.toString();
    _activeRemoteAttemptId = attemptId;
    _activeRemoteTransportMode = _RemoteTransportMode.relay;
    _remoteControlConnected = false;
    _relayFallbackTriggered = false;
    _remoteDescriptionReady = false;
    _pendingRemoteIceCandidates.clear();
    _localIceCandidateLogCount = 0;
    _remoteIceCandidateLogCount = 0;
    try {
      // 保留 relay channel 用于状态通知
      await _connectRemoteRelayChannel(sourceSessionId);
      _sendRemoteRelayMessage('remote_status', {
        'status': 'host_started',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      // 使用 WebRTC + TURN 中继传输视频流（非P2P直连）
      _logRemoteTransport(
        '启动 WebRTC+TURN 远控 session=$sourceSessionId attempt=$attemptId',
        sourceSessionId: sourceSessionId,
      );
      final screenStream = await _captureCurrentScreenStream();
      _screenStream = screenStream;
      await _startRemotePeerConnection(
        sourceSessionId,
        attemptId,
        screenStream,
        _RemoteTransportMode.relay,
      );
      await _pushText('🖥️ 远程画面已启动（WebRTC+TURN），等待手机接入', sessionId: sourceSessionId);
      return 'remote host started';
    } catch (e) {
      _logRemoteTransport('启动 WebRTC+TURN 远控失败: $e', sourceSessionId: sourceSessionId);
      await _stopRemoteHost(pushMessage: false, notifySessionId: sourceSessionId);
      rethrow;
    }
  }

  Future<void> _connectRemoteRelayChannel(String sourceSessionId) async {
    await _closeRemoteRelayChannel();
    final channel = WebSocketChannel.connect(_serverWsUri(sourceSessionId));
    _relayChannel = channel;
    channel.stream.listen(
      (raw) => _handleRemoteRelayMessage(raw, sourceSessionId),
      onError: (error) {
        _logRemoteTransport('中继 WS 异常: $error', sourceSessionId: sourceSessionId);
      },
      onDone: () {
        if (_activeRemoteSessionId == sourceSessionId) {
          _relayChannel = null;
        }
        _logRemoteTransport('中继 WS 已断开', sourceSessionId: sourceSessionId);
      },
    );
    _logRemoteTransport('中继 WS 已连接 role=pc', sourceSessionId: sourceSessionId);
  }

  void _sendRemoteRelayMessage(String type, Map<String, dynamic> data) {
    try {
      _relayChannel?.sink.add(jsonEncode({
        'type': type,
        'data': data,
      }));
    } catch (e) {
      final activeSessionId = _activeRemoteSessionId;
      _logRemoteTransport('发送中继消息 $type 失败: $e', sourceSessionId: activeSessionId);
    }
  }

  void _startRemoteRelayFramePump(String sourceSessionId) {
    _relayFrameTimer?.cancel();
    _relayFrameTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      unawaited(_pushRemoteRelayFrame(sourceSessionId));
    });
    unawaited(_pushRemoteRelayFrame(sourceSessionId));
  }

  Future<void> _pushRemoteRelayFrame(String sourceSessionId) async {
    if (_disposed ||
        _activeRemoteSessionId != sourceSessionId ||
        _relayChannel == null) {
      return;
    }
    final screenSources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
      thumbnailSize: ThumbnailSize(960, 540),
    );
    if (screenSources.isEmpty) {
      throw Exception('未检测到可共享的屏幕');
    }
    final currentScreenSource = screenSources.first;
    final thumbnail = currentScreenSource.thumbnail;
    if (thumbnail == null || thumbnail.isEmpty) {
      return;
    }
    final encoded = base64Encode(thumbnail);
    if (encoded.length > 900000) {
      _logRemoteTransport(
        '跳过过大中继帧 bytes=${thumbnail.length} encoded=${encoded.length}',
        sourceSessionId: sourceSessionId,
        pushToPhone: false,
      );
      return;
    }
    _localIceCandidateLogCount += 1;
    _sendRemoteRelayMessage('remote_frame', {
      'seq': _localIceCandidateLogCount,
      'frame_base64': encoded,
      'width': currentScreenSource.thumbnailSize.width,
      'height': currentScreenSource.thumbnailSize.height,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (_localIceCandidateLogCount == 1) {
      _logRemoteTransport(
        '已发送首帧 bytes=${thumbnail.length} size=${currentScreenSource.thumbnailSize.width}x${currentScreenSource.thumbnailSize.height}',
        sourceSessionId: sourceSessionId,
      );
    }
  }

  void _handleRemoteRelayMessage(dynamic raw, String sourceSessionId) {
    try {
      final payload = jsonDecode(raw as String);
      if (payload is! Map) {
        return;
      }
      final type = payload['type'] as String? ?? '';
      if (type != 'remote_input') {
        return;
      }
      final data = payload['data'];
      if (data is! Map) {
        return;
      }
      if (!_remoteControlConnected) {
        _remoteControlConnected = true;
        unawaited(_pushText('✅ 远程控制已连接', sessionId: sourceSessionId));
      }
      _handleRemoteInput(Map<String, dynamic>.from(data));
    } catch (e) {
      _logRemoteTransport('解析中继输入消息失败: $e', sourceSessionId: sourceSessionId);
    }
  }

  Future<void> _closeRemoteRelayChannel() async {
    _relayFrameTimer?.cancel();
    _relayFrameTimer = null;
    try {
      await _relayChannel?.sink.close();
    } catch (_) {}
    _relayChannel = null;
  }

  Future<void> _restartRemoteTransport(
    String sourceSessionId,
    String attemptId,
    _RemoteTransportMode transportMode, {
    required bool announceFallback,
  }) async {
    final screenStream = _screenStream;
    if (screenStream == null ||
        _activeRemoteSessionId != sourceSessionId ||
        _activeRemoteAttemptId != attemptId) {
      return;
    }
    if (announceFallback) {
      await _pushText('🔁 直连未就绪，正在切换中继链路', sessionId: sourceSessionId);
    }
    _logRemoteTransport(
      '准备重建 PeerConnection transport=${transportMode.name} attempt=$attemptId',
      sourceSessionId: sourceSessionId,
    );
    await _closeRemotePeerConnection(stopStream: false);
    _activeRemoteTransportMode = transportMode;
    _remoteControlConnected = false;
    _remoteDescriptionReady = false;
    _pendingRemoteIceCandidates.clear();
    await _startRemotePeerConnection(
      sourceSessionId,
      attemptId,
      screenStream,
      transportMode,
    );
  }

  Future<void> _startRemotePeerConnection(
    String sourceSessionId,
    String attemptId,
    MediaStream screenStream,
    _RemoteTransportMode transportMode,
  ) async {
    await _ensureTurnCredentialsLoaded(sourceSessionId);
    final config = _buildPeerConfiguration(transportMode);
    final activeTurnUrls = transportMode == _RemoteTransportMode.relay
        ? _preferredRelayTurnUrls()
        : _turnUrls;
    _logRemoteTransport(
      '创建 PeerConnection transport=${transportMode.name} relayConfig=$_hasRelayConfig turnUrls=${activeTurnUrls.join(', ')}',
      sourceSessionId: sourceSessionId,
    );
    final pc = await createPeerConnection(config);
    _pc = pc;
    _activeRemoteAttemptId = attemptId;
    _activeRemoteTransportMode = transportMode;

    pc.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      if (value == null || value.isEmpty) {
        return;
      }
      if (_localIceCandidateLogCount < _maxCandidateLogsPerAttempt) {
        _localIceCandidateLogCount += 1;
        _logRemoteTransport(
          '本地 candidate #$_localIceCandidateLogCount type=${_candidateType(value)} protocol=${_candidateProtocol(value)} transport=${transportMode.name}',
          sourceSessionId: sourceSessionId,
        );
      }
      _postSignal(
        'candidate',
        {
          'candidate': value,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'transport': transportMode.name,
        },
        sessionId: sourceSessionId,
        attemptId: attemptId,
      );
    };

    pc.onIceConnectionState = (state) {
      _logRemoteTransport(
        'ICE 状态 ${_enumLabel(state)} transport=${transportMode.name}',
        sourceSessionId: sourceSessionId,
      );
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _remoteControlConnected = true;
        _cancelRemoteTransportTimeout();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        final shouldRelayFallback = !_remoteControlConnected &&
            transportMode == _RemoteTransportMode.direct &&
            _hasRelayConfig &&
            !_relayFallbackTriggered &&
            _activeRemoteSessionId == sourceSessionId &&
            _activeRemoteAttemptId == attemptId;
        _remoteControlConnected = false;
        if (shouldRelayFallback) {
          _relayFallbackTriggered = true;
          unawaited(
            _restartRemoteTransport(
              sourceSessionId,
              attemptId,
              _RemoteTransportMode.relay,
              announceFallback: true,
            ),
          );
        }
      }
    };

    final dataChannel = await pc.createDataChannel(
      'remote-control',
      RTCDataChannelInit()..ordered = true,
    );
    _controlChannel = dataChannel;
    _logRemoteTransport('已创建 DataChannel remote-control', sourceSessionId: sourceSessionId);
    _setupControlChannel(dataChannel);

    for (final track in screenStream.getTracks()) {
      await pc.addTrack(track, screenStream);
    }
    _logRemoteTransport(
      '已添加本地媒体轨 tracks=${screenStream.getTracks().length} videoTracks=${screenStream.getVideoTracks().length}',
      sourceSessionId: sourceSessionId,
    );

    final offer = await pc.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await pc.setLocalDescription(offer);

    final localDescription = await pc.getLocalDescription();
    if (localDescription == null) {
      throw Exception('无法生成远控 offer');
    }
    _logRemoteTransport(
      '已生成本地 offer transport=${transportMode.name} sdp=${localDescription.sdp?.length ?? 0}',
      sourceSessionId: sourceSessionId,
    );

    await _postSignal(
      'offer',
      {
        'type': 'offer',
        'sdp': localDescription.sdp,
        'transport': transportMode.name,
      },
      sessionId: sourceSessionId,
      attemptId: attemptId,
    );
    _logRemoteTransport('已发送 offer transport=${transportMode.name}', sourceSessionId: sourceSessionId);
    _startSignalPolling();
    if (transportMode == _RemoteTransportMode.direct) {
      _scheduleRemoteTransportTimeout(sourceSessionId, attemptId);
    } else {
      _cancelRemoteTransportTimeout();
    }
  }

  Future<void> _closeRemotePeerConnection({required bool stopStream}) async {
    _cancelRemoteTransportTimeout();
    try {
      await _controlChannel?.close();
    } catch (_) {}
    _controlChannel = null;

    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;

    if (!stopStream) {
      return;
    }
    final stream = _screenStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          track.stop();
        } catch (_) {}
      }
    }
    _screenStream = null;
  }

  Future<String> _stopRemoteHost({bool pushMessage = true, String? notifySessionId}) async {
    final activeSessionId = _activeRemoteSessionId;
    _signalPollTimer?.cancel();
    _signalPollTimer = null;
    _cancelRemoteTransportTimeout();
    _remoteControlConnected = false;
    _remoteDescriptionReady = false;
    _pendingRemoteIceCandidates.clear();
    _relayFallbackTriggered = false;
    _activeRemoteAttemptId = null;
    _activeRemoteTransportMode = _RemoteTransportMode.relay;
    if (activeSessionId != null && activeSessionId.isNotEmpty) {
      _sendRemoteRelayMessage('remote_status', {
        'status': 'stopped',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
    await _closeRemoteRelayChannel();
    await _closeRemotePeerConnection(stopStream: true);
    _activeRemoteSessionId = null;

    final targetSessionId = notifySessionId ?? activeSessionId;
    if (pushMessage && targetSessionId != null && targetSessionId.isNotEmpty) {
      await _pushText('🛑 远程画面已停止', sessionId: targetSessionId);
    }
    return 'remote host stopped';
  }

  void _setupControlChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (state) {
      _logRemoteTransport('DataChannel 状态 ${_enumLabel(state)}');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _remoteControlConnected = true;
        _cancelRemoteTransportTimeout();
        final activeSessionId = _activeRemoteSessionId;
        if (activeSessionId != null && activeSessionId.isNotEmpty) {
          _pushText('✅ 远程控制已连接', sessionId: activeSessionId);
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _remoteControlConnected = false;
      }
    };

    channel.onMessage = (message) {
      try {
        final data = Map<String, dynamic>.from(jsonDecode(message.text) as Map);
        _handleRemoteInput(data);
      } catch (e, stackTrace) {
        debugPrint('Remote control message parse failed: $e\n$stackTrace');
      }
    };
  }

  void _handleRemoteInput(Map<String, dynamic> data) {
    final type = data['type'] as String? ?? '';
    if (type != 'remote_input') {
      return;
    }

    final action = data['action'] as String? ?? '';
    switch (action) {
      case 'tap':
        _tapPointer(data);
        return;
      case 'move':
        _movePointer(data);
        return;
      case 'scroll':
        _scrollPointer(data);
        return;
      case 'text_input':
        _pasteText(data['text'] as String? ?? '');
        return;
      case 'key':
        _sendVirtualKey(data['key'] as String? ?? '');
        return;
      default:
        return;
    }
  }

  void _movePointer(Map<String, dynamic> data) {
    final point = _normalizedPoint(data);
    SetCursorPos(point.$1, point.$2);
  }

  void _tapPointer(Map<String, dynamic> data) {
    final point = _normalizedPoint(data);
    final button = data['button'] as String? ?? 'left';
    SetCursorPos(point.$1, point.$2);
    if (button == 'right') {
      _mouseEvent(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0);
      _mouseEvent(MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0);
      return;
    }
    _mouseEvent(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
    _mouseEvent(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
  }

  void _scrollPointer(Map<String, dynamic> data) {
    final delta = (data['deltaY'] as num?)?.toInt() ?? 0;
    if (delta == 0) {
      return;
    }
    _mouseEvent(MOUSEEVENTF_WHEEL, 0, 0, _unsigned32(delta), 0);
  }

  int _unsigned32(int value) {
    return value >= 0 ? value : value & 0xFFFFFFFF;
  }

  (int, int) _normalizedPoint(Map<String, dynamic> data) {
    final x = (data['x'] as num?)?.toDouble() ?? 0.5;
    final y = (data['y'] as num?)?.toDouble() ?? 0.5;
    final screenWidth = GetSystemMetrics(SM_CXSCREEN);
    final screenHeight = GetSystemMetrics(SM_CYSCREEN);
    final dx = (x.clamp(0.0, 1.0) * screenWidth).round();
    final dy = (y.clamp(0.0, 1.0) * screenHeight).round();
    return (dx, dy);
  }

  Future<void> _pasteText(String text) async {
    if (text.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _pressKeyCombo(VK_CONTROL, 0x56);
  }

  void _sendVirtualKey(String key) {
    switch (key) {
      case 'enter':
        _pressVirtualKey(VK_RETURN);
        return;
      case 'tab':
        _pressVirtualKey(VK_TAB);
        return;
      case 'backspace':
        _pressVirtualKey(VK_BACK);
        return;
      case 'escape':
        _pressVirtualKey(VK_ESCAPE);
        return;
      case 'space':
        _pressVirtualKey(VK_SPACE);
        return;
      default:
        return;
    }
  }

  void _pressVirtualKey(int key) {
    _keybdEvent(key, 0, 0, 0);
    _keybdEvent(key, 0, KEYEVENTF_KEYUP, 0);
  }

  void _pressKeyCombo(int modifier, int key) {
    _keybdEvent(modifier, 0, 0, 0);
    _keybdEvent(key, 0, 0, 0);
    _keybdEvent(key, 0, KEYEVENTF_KEYUP, 0);
    _keybdEvent(modifier, 0, KEYEVENTF_KEYUP, 0);
  }

  void _startSignalPolling() {
    _signalPollTimer?.cancel();
    _signalPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollSignals(),
    );
  }

  Future<void> _pollSignals() async {
    final activeSessionId = _activeRemoteSessionId;
    final activeAttemptId = _activeRemoteAttemptId;
    if (_pc == null || activeSessionId == null || activeSessionId.isEmpty) {
      return;
    }
    try {
      final uri = Uri.parse('${apiService.serverUrl}/api/webrtc/signals').replace(
        queryParameters: {
          'session_id': activeSessionId,
          'role': 'pc',
          if (activeAttemptId != null && activeAttemptId.isNotEmpty)
            'attempt_id': activeAttemptId,
        },
      );
      final response = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        _logRemoteTransport(
          '轮询信令失败 code=${response.statusCode}',
          sourceSessionId: activeSessionId,
          pushToPhone: false,
        );
        return;
      }
      final data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      final signals = (data['signals'] as List?) ?? const [];
      if (signals.isNotEmpty) {
        _logRemoteTransport('收到信令 ${signals.length} 条', sourceSessionId: activeSessionId);
      }
      for (final rawSignal in signals) {
        if (rawSignal is! Map) {
          continue;
        }
        final signal = Map<String, dynamic>.from(rawSignal);
        final type = signal['type'] as String? ?? '';
        final signalAttemptId = (signal['attempt_id'] as String? ?? '').trim();
        if (signalAttemptId.isNotEmpty &&
            activeAttemptId != null &&
            signalAttemptId != activeAttemptId) {
          continue;
        }
        var payload = signal['payload'];
        if (payload is String && payload.isNotEmpty) {
          payload = jsonDecode(payload);
        }
        if (payload is! Map) {
          continue;
        }
        final payloadMap = Map<String, dynamic>.from(payload);
        if (payloadMap.containsKey('transport') &&
            _parseTransportMode(payloadMap['transport']) !=
                _activeRemoteTransportMode) {
          continue;
        }
        if (type == 'answer') {
          await _handleAnswer(payloadMap);
        } else if (type == 'candidate') {
          await _addIceCandidate(payloadMap);
        }
      }
    } catch (e, stackTrace) {
      debugPrint('DesktopCommandService signal polling failed: $e\n$stackTrace');
      _logRemoteTransport(
        '轮询信令异常: $e',
        sourceSessionId: activeSessionId,
        pushToPhone: false,
      );
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> payload) async {
    if (_pc == null) {
      return;
    }
    if (payload.containsKey('transport') &&
        _parseTransportMode(payload['transport']) !=
            _activeRemoteTransportMode) {
      return;
    }
    final sdp = payload['sdp'] as String?;
    if (sdp == null || sdp.isEmpty) {
      return;
    }
    final description = RTCSessionDescription(
      sdp,
      payload['type'] as String? ?? 'answer',
    );
    await _pc!.setRemoteDescription(description);
    _logRemoteTransport('已设置远端 answer sdp=${sdp.length}');
    _remoteDescriptionReady = true;
    await _flushPendingRemoteIceCandidates();
  }

  Future<void> _addIceCandidate(Map<String, dynamic> payload) async {
    final candidateValue = payload['candidate'] as String? ?? '';
    if (candidateValue.isEmpty) {
      return;
    }
    if (payload.containsKey('transport') &&
        _parseTransportMode(payload['transport']) !=
            _activeRemoteTransportMode) {
      return;
    }
    if (_pc == null || !_remoteDescriptionReady) {
      _pendingRemoteIceCandidates.add(Map<String, dynamic>.from(payload));
      if (_remoteIceCandidateLogCount < _maxCandidateLogsPerAttempt) {
        _remoteIceCandidateLogCount += 1;
        _logRemoteTransport(
          '暂存远端 candidate #$_remoteIceCandidateLogCount type=${_candidateType(candidateValue)} protocol=${_candidateProtocol(candidateValue)}',
        );
      }
      return;
    }
    try {
      final candidate = RTCIceCandidate(
        candidateValue,
        payload['sdpMid'] as String?,
        (payload['sdpMLineIndex'] as num?)?.toInt(),
      );
      await _pc!.addCandidate(candidate);
      if (_remoteIceCandidateLogCount < _maxCandidateLogsPerAttempt) {
        _remoteIceCandidateLogCount += 1;
        _logRemoteTransport(
          '已添加远端 candidate #$_remoteIceCandidateLogCount type=${_candidateType(candidateValue)} protocol=${_candidateProtocol(candidateValue)}',
        );
      }
    } catch (e) {
      _logRemoteTransport('添加远端 candidate 失败: $e');
    }
  }

  Future<void> _flushPendingRemoteIceCandidates() async {
    if (_pc == null || !_remoteDescriptionReady || _pendingRemoteIceCandidates.isEmpty) {
      return;
    }
    final pending = List<Map<String, dynamic>>.from(_pendingRemoteIceCandidates);
    _pendingRemoteIceCandidates.clear();
    for (final payload in pending) {
      await _addIceCandidate(payload);
    }
  }

  Future<void> _postSignal(
    String type,
    Map<String, dynamic> payload, {
    String? sessionId,
    String? attemptId,
  }) async {
    final targetSessionId = sessionId ?? _activeRemoteSessionId;
    final targetAttemptId = attemptId ?? _activeRemoteAttemptId;
    if (targetSessionId == null || targetSessionId.isEmpty) {
      return;
    }
    final uri = Uri.parse('${apiService.serverUrl}/api/webrtc/signal');
    final response = await http.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'type': type,
        'from': 'pc',
        'session_id': targetSessionId,
        if (targetAttemptId != null && targetAttemptId.isNotEmpty)
          'attempt_id': targetAttemptId,
        'payload': jsonEncode(payload),
      }),
    ).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      _logRemoteTransport(
        '发送信令 $type 失败 code=${response.statusCode}',
        sourceSessionId: targetSessionId,
      );
    }
  }
}

enum _RemoteTransportMode { direct, relay }
