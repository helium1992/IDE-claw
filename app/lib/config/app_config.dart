class AppConfig {
  // TODO: Replace with your own server URL after deploying push-server
  static const String defaultServerUrl = 'https://your-server.example.com';
  static const String defaultSessionId = 'your-session-id';
  static const String defaultToken = 'your-session-id:your-jwt-secret';
  static const Duration heartbeatInterval = Duration(seconds: 20);
  static const Duration reconnectDelay = Duration(seconds: 2);
  static const int maxReconnectAttempts = 999;
  static const Duration pongTimeout = Duration(seconds: 10);
  static const Duration pollFallbackInterval = Duration(seconds: 30);
}
