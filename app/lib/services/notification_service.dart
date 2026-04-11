import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _appInForeground = true;

  bool get appInForeground => _appInForeground;
  set appInForeground(bool v) => _appInForeground = v;

  Future<void> init() async {
    if (_initialized) return;

    // 桌面端跳过本地通知初始化
    if (!Platform.isAndroid && !Platform.isIOS) {
      _initialized = true;
      return;
    }

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(settings);
    _initialized = true;

    // 请求Android 13+通知权限
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// 当APP在后台时显示新消息通知
  Future<void> showMessageNotification({
    required String title,
    required String body,
    int id = 0,
  }) async {
    if (_appInForeground) return; // 前台不弹通知

    const androidDetails = AndroidNotificationDetails(
      'messages_channel',
      '消息通知',
      channelDescription: 'IDE推送的新消息',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(id, title, body, details);
  }
}

/// 在APP根widget中混入此mixin跟踪前后台状态
mixin AppLifecycleTracker on WidgetsBindingObserver {
  void initLifecycleTracker() {
    WidgetsBinding.instance.addObserver(this);
  }

  void disposeLifecycleTracker() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService().appInForeground =
        state == AppLifecycleState.resumed;
  }
}
