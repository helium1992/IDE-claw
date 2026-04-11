import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

/// WebRTC P2P 直连服务
/// 参考ZeroTier原理：STUN发现公网地址 → ICE打洞穿透NAT → DataChannel直连
class WebRTCService {
  static const String _turnUrlsValue = String.fromEnvironment('IDE_CLAW_TURN_URLS');
  static const String _turnUsername = String.fromEnvironment('IDE_CLAW_TURN_USERNAME');
  static const String _turnCredential = String.fromEnvironment('IDE_CLAW_TURN_CREDENTIAL');

  final String serverUrl;
  final String sessionId;
  final String token;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  bool _disposed = false;
  Timer? _pollTimer;
  MediaStream? _remoteStream;
  List<String>? _runtimeTurnUrls;
  String? _runtimeTurnUsername;
  String? _runtimeTurnCredential;
  DateTime? _turnCredentialsExpiresAt;
  Future<void>? _turnConfigLoadFuture;
  final List<Map<String, dynamic>> _pendingIceCandidates = [];
  bool _remoteDescriptionReady = false;
  String? _currentAttemptId;
  _RemoteTransportMode _transportMode = _RemoteTransportMode.direct;
  bool _transportConnected = false;
  P2PStatus _currentStatus = P2PStatus.waitingHost;
  int _localIceCandidateLogCount = 0;
  int _remoteIceCandidateLogCount = 0;

  static const int _maxCandidateLogsPerAttempt = 6;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<P2PStatus>.broadcast();
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();
  final _diagnosticController = StreamController<String>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<P2PStatus> get status => _statusController.stream;
  Stream<MediaStream?> get remoteStreams => _remoteStreamController.stream;
  Stream<String> get diagnostics => _diagnosticController.stream;
  MediaStream? get remoteStream => _remoteStream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  WebRTCService({
    required this.serverUrl,
    required this.sessionId,
    required this.token,
  });

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

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

  Future<void> _ensureTurnCredentialsLoaded() async {
    final expiresAt = _turnCredentialsExpiresAt;
    if (expiresAt != null && DateTime.now().isBefore(expiresAt)) {
      return;
    }
    final pending = _turnConfigLoadFuture;
    if (pending != null) {
      await pending;
      return;
    }
    final future = _loadTurnCredentials();
    _turnConfigLoadFuture = future;
    try {
      await future;
    } finally {
      _turnConfigLoadFuture = null;
    }
  }

  Future<void> _loadTurnCredentials() async {
    try {
      final uri = Uri.parse('$serverUrl/api/webrtc/turn-credentials').replace(
        queryParameters: {
          'session_id': sessionId,
          'role': 'mobile',
        },
      );
      _log('请求 TURN 凭据 role=mobile');
      final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        _log('TURN 凭据请求失败 code=${response.statusCode}');
        return;
      }
      final data = jsonDecode(response.body);
      if (data is! Map) {
        _log('TURN 凭据响应不是对象');
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
        _log('TURN 未启用或返回空 urls');
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
      _log('TURN 就绪 urls=${urls.join(', ')} username=$username ttl=${ttlSeconds}s');
    } catch (e) {
      _log('TURN 凭据请求异常: $e');
    }
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

  void _log(String message) {
    debugPrint('WebRTCService[$sessionId] $message');
    if (_disposed) {
      return;
    }
    _diagnosticController.add('🧪 [手机端远控] $message');
  }

  void _setStatus(P2PStatus status) {
    if (_disposed || _currentStatus == status) {
      return;
    }
    final previousStatus = _currentStatus;
    _currentStatus = status;
    _log('状态 ${previousStatus.name} -> ${status.name}');
    _statusController.add(status);
  }

  _RemoteTransportMode _parseTransportMode(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return normalized == 'relay'
        ? _RemoteTransportMode.relay
        : _RemoteTransportMode.direct;
  }

  String _resolveAttemptId(String? attemptId) {
    final normalized = attemptId?.trim() ?? '';
    if (normalized.isNotEmpty) {
      return normalized;
    }
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  void _restartPolling() {
    if (_disposed) {
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollSignals());
  }

  /// 开始监听PC端的WebRTC offer
  void startListening() {
    if (_disposed) return;
    _pendingIceCandidates.clear();
    _remoteDescriptionReady = false;
    _currentAttemptId = null;
    _transportMode = _RemoteTransportMode.direct;
    _transportConnected = false;
    _isConnected = false;
    _localIceCandidateLogCount = 0;
    _remoteIceCandidateLogCount = 0;
    _remoteStream = null;
    _remoteStreamController.add(null);
    _setStatus(P2PStatus.waitingHost);
    _restartPolling();
    _log('开始监听远控信令');
  }

  void markRemoteHostRequested() {
    if (_disposed) {
      return;
    }
    _setStatus(P2PStatus.requestingHost);
  }

  void markVideoViewReady() {
    if (_disposed || _remoteStream == null) {
      return;
    }
    _setStatus(P2PStatus.streamReady);
  }

  Future<void> _pollSignals() async {
    if (_disposed || _isConnected) return;
    try {
      if (_currentStatus == P2PStatus.requestingHost) {
        _setStatus(P2PStatus.waitingOffer);
      }
      final queryParameters = <String, String>{
        'session_id': sessionId,
        'role': 'mobile',
        if (_currentAttemptId != null && _currentAttemptId!.isNotEmpty)
          'attempt_id': _currentAttemptId!,
      };
      final uri = Uri.parse('$serverUrl/api/webrtc/signals').replace(
        queryParameters: queryParameters,
      );
      final r = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) {
        return;
      }
      final data = jsonDecode(r.body);
      final signals = data['signals'] as List? ?? [];
      if (signals.isNotEmpty) {
        _log('收到信令 ${signals.length} 条');
      }

      for (final rawSignal in signals) {
        if (rawSignal is! Map) {
          continue;
        }
        final sig = Map<String, dynamic>.from(rawSignal);
        final type = sig['type'] as String? ?? '';
        final signalAttemptId = (sig['attempt_id'] as String? ?? '').trim();
        var payload = sig['payload'];
        if (payload is String && payload.isNotEmpty) {
          payload = jsonDecode(payload);
        }
        if (payload is! Map) {
          continue;
        }
        final payloadMap = Map<String, dynamic>.from(payload);
        final transportMode = _parseTransportMode(payloadMap['transport']);

        if (type == 'offer') {
          await _handleOffer(
            payloadMap,
            attemptId: signalAttemptId,
            transportMode: transportMode,
          );
          continue;
        }

        if (signalAttemptId.isNotEmpty &&
            _currentAttemptId != null &&
            signalAttemptId != _currentAttemptId) {
          continue;
        }
        if (payloadMap.containsKey('transport') && transportMode != _transportMode) {
          continue;
        }

        if (type == 'candidate') {
          await _addIceCandidate(payloadMap);
        }
      }
    } catch (e) {
      _log('轮询信令异常: $e');
    }
  }

  Future<void> _handleOffer(
    Map<String, dynamic> offerData, {
    String? attemptId,
    required _RemoteTransportMode transportMode,
  }) async {
    if (_disposed) return;
    final nextAttemptId = _resolveAttemptId(attemptId);
    final retryingWithRelay = _currentAttemptId == nextAttemptId &&
        _transportMode == _RemoteTransportMode.direct &&
        transportMode == _RemoteTransportMode.relay;
    _log('收到 offer attempt=$nextAttemptId transport=${transportMode.name} retryingWithRelay=$retryingWithRelay');
    if (retryingWithRelay) {
      _setStatus(P2PStatus.retryingWithRelay);
    }
    _currentAttemptId = nextAttemptId;
    _transportMode = transportMode;
    _pollTimer?.cancel();
    await _closePeerConnection(clearRemoteStream: true);
    _pendingIceCandidates.clear();
    _remoteDescriptionReady = false;
    _transportConnected = false;
    _isConnected = false;
    _localIceCandidateLogCount = 0;
    _remoteIceCandidateLogCount = 0;
    _setStatus(P2PStatus.creatingPeer);

    await _ensureTurnCredentialsLoaded();
    final config = _buildPeerConfiguration(transportMode);
    final activeTurnUrls = transportMode == _RemoteTransportMode.relay
        ? _preferredRelayTurnUrls()
        : _turnUrls;
    _log('创建 PeerConnection transport=${transportMode.name} relayConfig=$_hasRelayConfig turnUrls=${activeTurnUrls.join(', ')}');
    _pc = await createPeerConnection(config);
    _pc!.onTrack = (event) async {
      MediaStream? stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
      } else if (event.track.kind == 'video') {
        stream = await createLocalMediaStream('remote-$nextAttemptId');
        stream.addTrack(event.track);
        _log('onTrack 未携带 streams，已为 track=${event.track.id} 创建兜底 stream');
      }
      if (stream == null) {
        _log('收到 onTrack 但未得到可用视频流 kind=${event.track.kind}');
        return;
      }
      _remoteStream = stream;
      _remoteStreamController.add(_remoteStream);
      _log('收到远端视频流 stream=${_remoteStream?.id ?? ''} tracks=${stream.getTracks().length}');
      if (_transportConnected) {
        _setStatus(P2PStatus.waitingFirstFrame);
      }
    };

    _pc!.onIceConnectionState = (state) {
      _log('ICE 状态 ${_enumLabel(state)} transport=${transportMode.name}');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _isConnected = true;
        _transportConnected = true;
        _pollTimer?.cancel();
        if (_remoteStream != null) {
          _setStatus(P2PStatus.waitingFirstFrame);
        } else {
          _setStatus(P2PStatus.transportConnected);
        }
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _isConnected = false;
        _transportConnected = false;
        _setStatus(P2PStatus.failed);
        _restartPolling();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _isConnected = false;
        _transportConnected = false;
        _setStatus(P2PStatus.disconnected);
        _restartPolling();
      }
    };

    _pc!.onIceCandidate = (candidate) {
      final candidateValue = candidate.candidate;
      if (candidateValue == null || candidateValue.isEmpty) {
        return;
      }
      if (_localIceCandidateLogCount < _maxCandidateLogsPerAttempt) {
        _localIceCandidateLogCount += 1;
        _log('本地 candidate #$_localIceCandidateLogCount type=${_candidateType(candidateValue)} protocol=${_candidateProtocol(candidateValue)} transport=${_transportMode.name}');
      }
      _postSignal('candidate', {
        'candidate': candidateValue,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
        'transport': _transportMode.name,
      });
    };

    _pc!.onDataChannel = (channel) {
      _dc = channel;
      _log('收到 DataChannel ${channel.label}');
      _setupDataChannel(channel);
    };

    final offer = RTCSessionDescription(
      offerData['sdp'] as String,
      offerData['type'] as String,
    );
    await _pc!.setRemoteDescription(offer);
    _log('已设置远端 offer');
    _remoteDescriptionReady = true;
    await _flushPendingIceCandidates();
    _setStatus(
      transportMode == _RemoteTransportMode.relay
          ? P2PStatus.connectingRelay
          : P2PStatus.connectingDirect,
    );

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    final localDesc = await _pc!.getLocalDescription();
    if (localDesc != null) {
      await _postSignal('answer', {
        'type': 'answer',
        'sdp': localDesc.sdp,
        'transport': _transportMode.name,
      });
      _log('已发送 answer transport=${_transportMode.name} sdp=${localDesc.sdp?.length ?? 0}');
    }

    _restartPolling();
  }

  Future<void> _closePeerConnection({bool clearRemoteStream = false}) async {
    try {
      await _dc?.close();
    } catch (_) {}
    _dc = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    if (clearRemoteStream) {
      _remoteStream = null;
      _remoteStreamController.add(null);
    }
  }

  Future<void> _flushPendingIceCandidates() async {
    if (_pc == null || !_remoteDescriptionReady || _pendingIceCandidates.isEmpty) {
      return;
    }
    final pending = List<Map<String, dynamic>>.from(_pendingIceCandidates);
    _pendingIceCandidates.clear();
    for (final candidateData in pending) {
      await _addIceCandidate(candidateData);
    }
  }

  void _setupDataChannel(RTCDataChannel dc) {
    dc.onMessage = (msg) {
      try {
        final data = jsonDecode(msg.text);
        _messageController.add(data);
      } catch (_) {
        _messageController.add({'text': msg.text});
      }
    };

    dc.onDataChannelState = (state) {
      _log('DataChannel 状态 ${_enumLabel(state)}');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _isConnected = true;
        _transportConnected = true;
        _pollTimer?.cancel();
        if (_remoteStream != null) {
          _setStatus(P2PStatus.waitingFirstFrame);
        } else {
          _setStatus(P2PStatus.transportConnected);
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _isConnected = false;
        _transportConnected = false;
        _setStatus(P2PStatus.disconnected);
        _restartPolling();
      }
    };
  }

  Future<void> _addIceCandidate(Map<String, dynamic> data) async {
    final candidateValue = data['candidate'] as String? ?? '';
    if (candidateValue.isEmpty) {
      return;
    }
    if (data.containsKey('transport') && _parseTransportMode(data['transport']) != _transportMode) {
      return;
    }
    if (_pc == null || !_remoteDescriptionReady) {
      _pendingIceCandidates.add(Map<String, dynamic>.from(data));
      if (_remoteIceCandidateLogCount < _maxCandidateLogsPerAttempt) {
        _remoteIceCandidateLogCount += 1;
        _log('暂存远端 candidate #$_remoteIceCandidateLogCount type=${_candidateType(candidateValue)} protocol=${_candidateProtocol(candidateValue)}');
      }
      return;
    }
    try {
      final candidate = RTCIceCandidate(
        candidateValue,
        data['sdpMid'] as String? ?? '',
        (data['sdpMLineIndex'] as num?)?.toInt() ?? 0,
      );
      await _pc!.addCandidate(candidate);
      if (_remoteIceCandidateLogCount < _maxCandidateLogsPerAttempt) {
        _remoteIceCandidateLogCount += 1;
        _log('已添加远端 candidate #$_remoteIceCandidateLogCount type=${_candidateType(candidateValue)} protocol=${_candidateProtocol(candidateValue)}');
      }
    } catch (e) {
      _log('添加远端 candidate 失败: $e');
    }
  }

  /// 发送消息（通过P2P DataChannel）
  Future<bool> send(Map<String, dynamic> data) async {
    if (!_isConnected || _dc == null) return false;
    try {
      _dc!.send(RTCDataChannelMessage(jsonEncode(data)));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 发送文本消息
  Future<bool> sendText(String text) async {
    return send({
      'type': 'message',
      'content': text,
      'sender': 'mobile',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<bool> sendRemoteInput(Map<String, dynamic> data) async {
    return send({
      'type': 'remote_input',
      ...data,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _postSignal(String type, Map<String, dynamic> payload) async {
    try {
      final url = Uri.parse('$serverUrl/api/webrtc/signal');
      final response = await http.post(url,
        headers: _headers,
        body: jsonEncode({
          'type': type,
          'from': 'mobile',
          'session_id': sessionId,
          if (_currentAttemptId != null && _currentAttemptId!.isNotEmpty)
            'attempt_id': _currentAttemptId,
          'payload': jsonEncode(payload),
        }),
      ).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        _log('发送信令 $type 失败 code=${response.statusCode}');
      }
    } catch (e) {
      _log('发送信令 $type 异常: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _dc?.close();
    _pc?.close();
    _pendingIceCandidates.clear();
    _remoteDescriptionReady = false;
    _currentAttemptId = null;
    _transportConnected = false;
    _remoteStreamController.add(null);
    _messageController.close();
    _remoteStreamController.close();
    _statusController.close();
    _diagnosticController.close();
  }
}

enum P2PStatus {
  waitingHost,
  requestingHost,
  waitingOffer,
  creatingPeer,
  connectingDirect,
  retryingWithRelay,
  connectingRelay,
  transportConnected,
  waitingFirstFrame,
  streamReady,
  disconnected,
  failed,
}

enum _RemoteTransportMode { direct, relay }
