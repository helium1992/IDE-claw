class PushSession {
  final String id;
  final String name;
  final String machineName;
  final String projectName;
  final String ideType;
  final String displayName;
  final String description;
  final int unreadCount;
  final String lastMessage;
  final String lastMsgTime;
  final String createdAt;
  final String lastActive;

  PushSession({
    required this.id,
    required this.name,
    this.machineName = '',
    this.projectName = '',
    this.ideType = '',
    this.displayName = '',
    this.description = '',
    this.unreadCount = 0,
    this.lastMessage = '',
    this.lastMsgTime = '',
    required this.createdAt,
    required this.lastActive,
  });

  factory PushSession.fromJson(Map<String, dynamic> json) {
    return PushSession(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      machineName: json['machine_name'] ?? '',
      projectName: json['project_name'] ?? '',
      ideType: json['ide_type'] ?? '',
      displayName: json['display_name'] ?? '',
      description: json['description'] ?? '',
      unreadCount: json['unread_count'] ?? 0,
      lastMessage: json['last_message'] ?? '',
      lastMsgTime: json['last_msg_time'] ?? '',
      createdAt: json['created_at'] ?? '',
      lastActive: json['last_active'] ?? '',
    );
  }

  String get title {
    if (displayName.isNotEmpty) return displayName;
    if (projectName.isNotEmpty) return projectName;
    if (name.isNotEmpty) return name;
    return id;
  }

  String get subtitle {
    final parts = <String>[];
    if (machineName.isNotEmpty) parts.add(machineName);
    if (ideType.isNotEmpty) parts.add(ideType);
    return parts.join(' · ');
  }

  IconType get iconType {
    switch (ideType.toLowerCase()) {
      case 'windsurf':
        return IconType.windsurf;
      case 'cursor':
        return IconType.cursor;
      case 'vscode':
        return IconType.vscode;
      default:
        return IconType.generic;
    }
  }
}

enum IconType { windsurf, cursor, vscode, generic }
