import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/session.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../config/app_config.dart';
import 'chat_screen.dart';

class SessionListScreen extends StatefulWidget {
  final ApiService apiService;

  const SessionListScreen({super.key, required this.apiService});

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> with WidgetsBindingObserver {
  List<PushSession> _sessions = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSessions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService().appInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _loadSessions(silent: true);
    }
  }

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

  void _openChat(PushSession session) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          apiService: widget.apiService,
          sessionId: session.id,
          sessionName: session.title,
        ),
      ),
    );
    // 返回时静默刷新（不显示loading转圈）
    _loadSessions(silent: true);
  }

  void _openDefaultChat() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          apiService: widget.apiService,
          sessionId: AppConfig.defaultSessionId,
          sessionName: 'Default Session',
        ),
      ),
    );
    _loadSessions(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('IDEclaw'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSessions,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Colors.red[300])),
            const SizedBox(height: 16),
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
            Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            const Text('暂无会话', style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 8),
            const Text('点击右下角开始默认会话', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadSessions,
      child: ListView.builder(
        itemCount: _sessions.length,
        itemBuilder: (_, i) => _buildSessionTile(_sessions[i]),
      ),
    );
  }

  Widget _buildSessionTile(PushSession session) {
    String timeStr = '';
    try {
      final timeSource = session.lastMsgTime.isNotEmpty ? session.lastMsgTime : session.lastActive;
      final dt = DateTime.parse(timeSource);
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

    // IDE图标
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
        iconColor = Theme.of(context).colorScheme.primary;
        break;
    }

    // 副标题：机器名 · IDE 或 最新消息
    final metaLine = session.subtitle;
    final previewLine = session.lastMessage.isNotEmpty ? session.lastMessage : '暂无消息';

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: iconColor.withOpacity(0.15),
            child: Icon(iconData, color: iconColor),
          ),
          if (session.unreadCount > 0)
            Positioned(
              right: 0, top: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(8),
                ),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                child: Text(
                  session.unreadCount > 99 ? '99+' : '${session.unreadCount}',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
      title: Text(session.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (metaLine.isNotEmpty)
            Text(metaLine, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          Text(previewLine, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
      trailing: Text(timeStr, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
      isThreeLine: metaLine.isNotEmpty,
      onTap: () => _openChat(session),
    );
  }
}
