# IDE Claw 手机/桌面客户端

Flutter 跨平台应用，支持 Android 手机 + Windows 桌面。

## 源码位置

完整源码在本目录中。

## 功能

- 实时接收 AI IDE 推送的消息、文件、图片
- 从手机回复文字、语音、图片、文件
- 多会话管理（每个 AI IDE 项目一个会话）
- 自动挂机（每2小时心跳保活）
- Markdown 渲染
- 文件下载管理
- WebSocket 实时通信 + HTTP 轮询备用

## 编译

```bash
# Android APK
flutter build apk --release

# Windows 桌面
flutter build windows --release
```

## 配置

编辑 `lib/config/app_config.dart`：
```dart
static const String defaultServerUrl = 'https://your-domain.com';
static const String defaultToken = 'session-id:your-jwt-secret';
```

## 关键文件

| 文件 | 说明 |
|------|------|
| `lib/screens/chat_screen.dart` | 手机端聊天界面 |
| `lib/screens/desktop_home_screen.dart` | 桌面端主界面 |
| `lib/providers/message_provider.dart` | 消息管理 + WebSocket |
| `lib/services/ws_service.dart` | WebSocket 服务 |
| `lib/services/api_service.dart` | HTTP API 服务 |
| `lib/services/download_service.dart` | 文件下载管理 |
| `lib/config/app_config.dart` | 服务器配置 |
