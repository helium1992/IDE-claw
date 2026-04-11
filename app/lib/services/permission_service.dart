import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// 统一权限管理 — 启动时申请所有必要权限
class PermissionService {
  /// 申请所有必要权限，返回被拒绝的权限列表
  static Future<List<Permission>> requestAll() async {
    if (!Platform.isAndroid) return [];

    final permissions = <Permission>[
      Permission.notification,           // 通知（Android 13+）
      Permission.ignoreBatteryOptimizations, // 电池优化豁免
      Permission.storage,               // 存储（Android 12及以下）
      Permission.manageExternalStorage,  // 存储（Android 11+）
    ];

    final statuses = await permissions.request();

    final denied = <Permission>[];
    statuses.forEach((perm, status) {
      if (status.isDenied || status.isPermanentlyDenied) {
        denied.add(perm);
      }
    });

    return denied;
  }

  /// 检查并引导用户开启通知权限
  static Future<bool> ensureNotification() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.notification.status;
    if (status.isGranted) return true;

    final result = await Permission.notification.request();
    return result.isGranted;
  }

  /// 请求电池优化豁免（弹出系统对话框）
  static Future<bool> requestBatteryOptimization() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) return true;

    final result = await Permission.ignoreBatteryOptimizations.request();
    return result.isGranted;
  }

  /// 显示权限引导对话框（当权限被永久拒绝时）
  static Future<void> showPermissionGuide(
      BuildContext context, List<Permission> deniedPermissions) async {
    if (deniedPermissions.isEmpty) return;

    final descriptions = <String>[];
    for (final p in deniedPermissions) {
      if (p == Permission.notification) {
        descriptions.add('• 通知权限 — 接收PC端推送消息');
      } else if (p == Permission.ignoreBatteryOptimizations) {
        descriptions.add('• 电池优化豁免 — 保持后台WebSocket连接');
      }
    }

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要以下权限'),
        content: Text(
          '为保证消息正常接收，请在系统设置中开启：\n\n${descriptions.join('\n')}\n\n点击"去设置"打开权限页面。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }
}
