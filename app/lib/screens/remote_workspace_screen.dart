import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../providers/message_provider.dart';
import '../services/api_service.dart';
import '../services/webrtc_service.dart';
import 'chat_screen.dart';

class RemoteWorkspaceScreen extends StatefulWidget {
  final ApiService apiService;
  final String sessionId;
  final String sessionName;
  final MessageProvider provider;

  const RemoteWorkspaceScreen({
    super.key,
    required this.apiService,
    required this.sessionId,
    required this.sessionName,
    required this.provider,
  });

  @override
  State<RemoteWorkspaceScreen> createState() => _RemoteWorkspaceScreenState();
}

class _RemoteWorkspaceScreenState extends State<RemoteWorkspaceScreen> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  StreamSubscription<MediaStream?>? _remoteStreamSubscription;
  bool _rendererReady = false;
  bool _remoteStartRequested = false;
  bool _remoteStopping = false;
  bool _skipStopOnPop = false;

  @override
  void initState() {
    super.initState();
    _initRenderer();
    widget.provider.ensureRemoteListening();
    _remoteStreamSubscription =
        widget.provider.webrtcService?.remoteStreams.listen(_applyRemoteStream);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _applyRemoteStream(widget.provider.webrtcService?.remoteStream);
      _startRemoteHostIfNeeded();
    });
  }

  Future<void> _initRenderer() async {
    await _renderer.initialize();
    if (!mounted) {
      return;
    }
    setState(() {
      _rendererReady = true;
    });
    _applyRemoteStream(widget.provider.webrtcService?.remoteStream);
  }

  Future<void> _applyRemoteStream(MediaStream? stream) async {
    if (!_rendererReady) {
      return;
    }
    if (_renderer.srcObject?.id == stream?.id) {
      if (stream != null) {
        widget.provider.webrtcService?.markVideoViewReady();
      }
      return;
    }
    _renderer.srcObject = stream;
    if (stream != null) {
      widget.provider.webrtcService?.markVideoViewReady();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _startRemoteHostIfNeeded({bool force = false}) async {
    if (_remoteStartRequested && !force) {
      return;
    }
    widget.provider.ensureRemoteListening();
    widget.provider.markRemoteHostRequested();
    _remoteStartRequested = true;
    await widget.provider.sendCommand(
      'start_remote_host',
      displayText: '🖥️ 操控电脑',
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已请求电脑端启动远程画面')),
    );
  }

  Future<void> _stopRemoteHost({bool popAfter = false}) async {
    if (_remoteStopping) {
      return;
    }
    _remoteStopping = true;
    _remoteStartRequested = false;
    try {
      await widget.provider.sendCommand(
        'stop_remote_host',
        displayText: '🛑 结束远控',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已请求电脑端停止远程画面')),
        );
      }
      if (popAfter && mounted) {
        _skipStopOnPop = true;
        Navigator.of(context).pop();
      }
    } finally {
      _remoteStopping = false;
    }
  }

  Future<void> _launchWindsurf() async {
    await widget.provider.sendCommand(
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

  Future<void> _openTextInputDialog() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发送远程输入'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '输入后会通过电脑端剪贴板粘贴',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) {
      return;
    }
    final sent = await widget.provider.sendRemoteInput({
      'action': 'text_input',
      'text': text,
    });
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sent ? '已发送远程文本输入' : '远程通道未连接，发送失败')),
    );
  }

  Future<void> _sendRemoteKey(String key, {bool showFeedback = true}) async {
    final sent = await widget.provider.sendRemoteInput({
      'action': 'key',
      'key': key,
    });
    if (!mounted || !showFeedback) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sent ? '已发送按键: $key' : '远程通道未连接，发送失败')),
    );
  }

  Future<void> _sendRemoteScroll(int deltaY, {bool showFeedback = false}) async {
    final sent = await widget.provider.sendRemoteInput({
      'action': 'scroll',
      'deltaY': deltaY,
    });
    if (!mounted || !showFeedback) {
      return;
    }
    final label = deltaY > 0 ? '滚轮上' : '滚轮下';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sent ? '已发送操作: $label' : '远程通道未连接，发送失败')),
    );
  }

  Future<void> _sendPointerEvent(
    String action,
    Offset position,
    Size size, {
    String button = 'left',
  }) async {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    await widget.provider.sendRemoteInput({
      'action': action,
      'button': button,
      'x': (position.dx / size.width).clamp(0.0, 1.0),
      'y': (position.dy / size.height).clamp(0.0, 1.0),
    });
  }

  Widget _buildQuickActionBar() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.tonalIcon(
                onPressed: _openTextInputDialog,
                icon: const Icon(Icons.keyboard),
                label: const Text('粘贴文本'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => _sendRemoteKey('enter', showFeedback: false),
                icon: const Icon(Icons.keyboard_return),
                label: const Text('回车'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => _sendRemoteKey('backspace', showFeedback: false),
                icon: const Icon(Icons.backspace_outlined),
                label: const Text('退格'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => _sendRemoteKey('escape', showFeedback: false),
                icon: const Icon(Icons.close),
                label: const Text('Esc'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => _sendRemoteKey('tab', showFeedback: false),
                icon: const Icon(Icons.keyboard_tab),
                label: const Text('Tab'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => _sendRemoteScroll(120),
                icon: const Icon(Icons.mouse),
                label: const Text('滚轮上'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => _sendRemoteScroll(-120),
                icon: const Icon(Icons.swipe_down),
                label: const Text('滚轮下'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusText(P2PStatus status) {
    switch (status) {
      case P2PStatus.waitingHost:
        return '等待电脑端远控宿主';
      case P2PStatus.requestingHost:
        return '正在请求电脑端启动远控';
      case P2PStatus.waitingOffer:
        return '等待电脑端建立中继远控';
      case P2PStatus.creatingPeer:
        return '正在准备远控中继';
      case P2PStatus.connectingDirect:
        return '正在建立云端中继';
      case P2PStatus.retryingWithRelay:
        return '正在恢复云端中继';
      case P2PStatus.connectingRelay:
        return '正在建立中继连接';
      case P2PStatus.transportConnected:
        return '中继已连通，等待画面';
      case P2PStatus.waitingFirstFrame:
        return '连接已建立，等待首帧画面';
      case P2PStatus.streamReady:
        return '远程画面已就绪';
      case P2PStatus.disconnected:
        return '远程已断开';
      case P2PStatus.failed:
        return '远程连接失败';
    }
  }

  String _statusDetail(P2PStatus status) {
    switch (status) {
      case P2PStatus.waitingHost:
        return '页面已准备好，等待你请求电脑端启动远控。';
      case P2PStatus.requestingHost:
        return '正在把 start_remote_host 指令发给电脑端。';
      case P2PStatus.waitingOffer:
        return '电脑端尚未完成云端中继远控初始化。';
      case P2PStatus.creatingPeer:
        return '手机端正在准备通过云服务器接收远控画面。';
      case P2PStatus.connectingDirect:
        return '正在连接云服务器中继通道。';
      case P2PStatus.retryingWithRelay:
        return '当前正在重新建立云服务器中继链路。';
      case P2PStatus.connectingRelay:
        return '正在通过云服务器中转建立远控连接。';
      case P2PStatus.transportConnected:
        return '中继通道已连通，正在等待桌面画面刷新。';
      case P2PStatus.waitingFirstFrame:
        return '已连上云端中继，等待首帧电脑画面进入渲染区。';
      case P2PStatus.streamReady:
        return '上半区会显示电脑共享画面\n支持点击定位、长按右键、滑动移动光标';
      case P2PStatus.disconnected:
        return '远控链路已断开，可以重新请求连接。';
      case P2PStatus.failed:
        return '本次远控未能建立，请尝试重新请求远控。';
    }
  }

  Color _statusColor(P2PStatus status, ThemeData theme) {
    switch (status) {
      case P2PStatus.streamReady:
        return Colors.green;
      case P2PStatus.transportConnected:
        return Colors.lightGreenAccent;
      case P2PStatus.waitingFirstFrame:
        return Colors.tealAccent;
      case P2PStatus.connectingDirect:
      case P2PStatus.connectingRelay:
        return Colors.orange;
      case P2PStatus.retryingWithRelay:
        return Colors.amber;
      case P2PStatus.failed:
        return theme.colorScheme.error;
      case P2PStatus.disconnected:
        return Colors.grey;
      case P2PStatus.waitingHost:
      case P2PStatus.requestingHost:
      case P2PStatus.waitingOffer:
      case P2PStatus.creatingPeer:
        return theme.colorScheme.primary;
    }
  }

  Widget _buildRemotePlaceholder(ThemeData theme) {
    final status = widget.provider.p2pStatus;
    return Container(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.desktop_windows,
                  color: Colors.white.withValues(alpha: 0.9), size: 56),
              const SizedBox(height: 16),
              Text(
                _statusText(status),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                _statusDetail(status),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => _startRemoteHostIfNeeded(force: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新请求远控'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _launchWindsurf,
                    icon: const Icon(Icons.rocket_launch),
                    label: const Text('启动 Windsurf'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRemoteStage(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final relayFrameBytes = widget.provider.remoteRelayFrameBytes;
        final hasVideo = _renderer.srcObject != null;
        final hasVisual = relayFrameBytes != null || hasVideo;
        final status = widget.provider.p2pStatus;
        final statusColor = _statusColor(status, theme);
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.black),
            if (relayFrameBytes != null)
              Image.memory(
                relayFrameBytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
              )
            else if (hasVideo)
              RTCVideoView(
                _renderer,
                mirror: false,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              )
            else
              _buildRemotePlaceholder(theme),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: hasVisual
                    ? (details) => _sendPointerEvent(
                          'tap',
                          details.localPosition,
                          size,
                        )
                    : null,
                onLongPressStart: hasVisual
                    ? (details) => _sendPointerEvent(
                          'tap',
                          details.localPosition,
                          size,
                          button: 'right',
                        )
                    : null,
                onPanUpdate: hasVisual
                    ? (details) => _sendPointerEvent(
                          'move',
                          details.localPosition,
                          size,
                        )
                    : null,
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _statusText(status),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Align(
                alignment: Alignment.bottomRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: size.width),
                  child: _buildQuickActionBar(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _remoteStreamSubscription?.cancel();
    if (_rendererReady) {
      _renderer.srcObject = null;
      _renderer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_skipStopOnPop) {
          unawaited(_stopRemoteHost());
        }
        _skipStopOnPop = false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            children: [
              const Text('远程工作台', style: TextStyle(fontSize: 16)),
              Text(
                widget.sessionName,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          centerTitle: true,
          actions: [
            IconButton(
              onPressed: _launchWindsurf,
              icon: const Icon(Icons.rocket_launch),
              tooltip: '启动 Windsurf',
            ),
            IconButton(
              onPressed: () => _stopRemoteHost(popAfter: true),
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: '结束远控',
            ),
          ],
        ),
        body: AnimatedBuilder(
          animation: widget.provider,
          builder: (context, _) => SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: _buildRemoteStage(theme),
                    ),
                  ),
                ),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: theme.dividerColor.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                    child: ChatScreen(
                      apiService: widget.apiService,
                      sessionId: widget.sessionId,
                      sessionName: widget.sessionName,
                      embedded: true,
                      existingProvider: widget.provider,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
