import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'config/app_config.dart';
import 'services/api_service.dart';
import 'services/permission_service.dart';
import 'services/download_service.dart';
import 'services/notification_service.dart';
import 'services/local_ipc_service.dart';
import 'services/desktop_command_service.dart';
import 'services/windsurf_auto_service_launcher.dart';
import 'services/windsurf_account_script_service.dart';
import 'screens/session_list_screen.dart';
import 'screens/desktop_home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端窗口配置
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1000, 700),
      minimumSize: Size(800, 500),
      center: true,
      title: 'IDE Claw',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    // 拦截关闭事件，改为最小化到托盘
    await windowManager.setPreventClose(true);
  }

  // 启动时申请所有必要权限
  await PermissionService.requestAll();
  // 初始化下载服务（加载已下载记录）
  await DownloadService().init();
  // 初始化通知服务
  await NotificationService().init();
  // 桌面端启动本地 IPC 服务（让 dialog.py 直连，不走远程服务器）
  final ipcPort = LocalIpcService.portForSession(AppConfig.defaultSessionId);
  final localIpc = LocalIpcService(port: ipcPort, sessionId: AppConfig.defaultSessionId);
  final apiService = ApiService(
    serverUrl: AppConfig.defaultServerUrl,
    token: AppConfig.defaultToken,
  );
  DesktopCommandService? desktopCommandService;
  WindsurfAutoServiceLauncher? windsurfAutoServiceLauncher;
  WindsurfAccountScriptService? windsurfAccountScriptService;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    windsurfAutoServiceLauncher = WindsurfAutoServiceLauncher();
    windsurfAccountScriptService = WindsurfAccountScriptService();
    await windsurfAutoServiceLauncher.start();
    await localIpc.start();
    desktopCommandService = DesktopCommandService(
      apiService: apiService,
      sessionId: AppConfig.defaultSessionId,
    );
    await desktopCommandService.start();
  }
  runApp(IDEClawApp(
    apiService: apiService,
    localIpcService: localIpc,
    desktopCommandService: desktopCommandService,
    windsurfAutoServiceLauncher: windsurfAutoServiceLauncher,
    windsurfAccountScriptService: windsurfAccountScriptService,
  ));
}

class IDEClawApp extends StatefulWidget {
  final ApiService apiService;
  final LocalIpcService? localIpcService;
  final DesktopCommandService? desktopCommandService;
  final WindsurfAutoServiceLauncher? windsurfAutoServiceLauncher;
  final WindsurfAccountScriptService? windsurfAccountScriptService;
  const IDEClawApp({
    super.key,
    required this.apiService,
    this.localIpcService,
    this.desktopCommandService,
    this.windsurfAutoServiceLauncher,
    this.windsurfAccountScriptService,
  });

  @override
  State<IDEClawApp> createState() => _IDEClawAppState();
}

class _IDEClawAppState extends State<IDEClawApp>
    with WindowListener, TrayListener {
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initSystemTray();
    }
  }

  @override
  void dispose() {
    if (isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      trayManager.destroy();
    }
    if (widget.windsurfAutoServiceLauncher != null) {
      unawaited(widget.windsurfAutoServiceLauncher!.stop());
    }
    widget.desktopCommandService?.dispose();
    super.dispose();
  }

  Future<void> _initSystemTray() async {
    try {
      String iconPath;
      if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        iconPath = '$exeDir\\app_icon.ico';
        if (!File(iconPath).existsSync()) {
          debugPrint('[tray] app_icon.ico not found at $iconPath, skipping tray icon');
          return;
        }
      } else {
        iconPath = 'assets/app_icon.png';
      }
      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('IDE Claw');
      final menu = Menu(
        items: [
          MenuItem(key: 'show', label: '显示窗口'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: '退出'),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (e) {
      debugPrint('[tray] Failed to init system tray: $e');
    }
  }

  // 点击关闭按钮 → 隐藏窗口到托盘
  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  // 双击托盘图标 → 显示窗口
  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // 右键托盘图标 → 弹出菜单
  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  // 托盘菜单点击
  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'quit':
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
        await windowManager.close();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IDE Claw',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Microsoft YaHei',
        fontFamilyFallback: const [
          'PingFang SC',
          'Helvetica Neue',
          'sans-serif',
        ],
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Microsoft YaHei',
        fontFamilyFallback: const [
          'PingFang SC',
          'Helvetica Neue',
          'sans-serif',
        ],
      ),
      themeMode: ThemeMode.system,
      home: isDesktop
          ? DesktopHomeScreen(
              apiService: widget.apiService,
              localIpcService: widget.localIpcService,
              windsurfAutoServiceLauncher: widget.windsurfAutoServiceLauncher,
              windsurfAccountScriptService: widget.windsurfAccountScriptService,
            )
          : SessionListScreen(apiService: widget.apiService),
    );
  }
}
