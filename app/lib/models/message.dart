enum SendStatus { none, sending, sent, failed }

class PushMessage {
  String id;
  final String sessionId;
  final String conversationId;
  final String content;
  final String msgType; // text, screenshot, status
  final bool hasImage;
  final String sender; // pc, mobile, system
  final int chunkIndex;
  final bool isFinal;
  final String status; // pending, delivered, read
  final DateTime createdAt;
  String fileId;
  String fileName;
  String downloadUrl;
  String caption;
  SendStatus sendStatus;

  PushMessage({
    required this.id,
    required this.sessionId,
    this.conversationId = '',
    required this.content,
    this.msgType = 'text',
    this.hasImage = false,
    this.sender = 'pc',
    this.chunkIndex = -1,
    this.isFinal = true,
    this.status = 'pending',
    required this.createdAt,
    this.fileId = '',
    this.fileName = '',
    this.downloadUrl = '',
    this.caption = '',
    this.sendStatus = SendStatus.none,
  });

  factory PushMessage.fromJson(Map<String, dynamic> json) {
    final msgType = json['msg_type'] ?? 'text';
    final id = json['id'] ?? '';
    final content = json['content'] ?? '';
    var fileId = json['file_id'] ?? '';
    var fileName = json['file_name'] ?? '';

    // 文件消息：file_id就是消息id，file_name从content解析
    if (msgType == 'file') {
      if (fileId.isEmpty) fileId = id;
      if (fileName.isEmpty) {
        // content格式: "📎 文件: xxx.apk (78.9 MB)" 或 "📎 caption\n文件: xxx.apk (78.9 MB)"
        final match = RegExp(r'文件: (.+?) \(').firstMatch(content);
        if (match != null) fileName = match.group(1) ?? '';
      }
    }

    return PushMessage(
      id: id,
      sessionId: json['session_id'] ?? '',
      conversationId: json['conversation_id'] ?? '',
      content: content,
      msgType: msgType,
      hasImage: json['has_image'] == true,
      sender: json['sender'] ?? 'pc',
      chunkIndex: json['chunk_index'] ?? -1,
      isFinal: json['is_final'] ?? true,
      status: json['status'] ?? 'pending',
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      fileId: fileId,
      fileName: fileName,
      downloadUrl: json['download_url'] ?? '',
      caption: json['caption'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'session_id': sessionId,
    'conversation_id': conversationId,
    'content': content,
    'msg_type': msgType,
    'has_image': hasImage,
    'sender': sender,
    'chunk_index': chunkIndex,
    'is_final': isFinal,
    'status': status,
    'created_at': createdAt.toIso8601String(),
    'file_id': fileId,
    'file_name': fileName,
    'download_url': downloadUrl,
    'caption': caption,
  };

  bool get isScreenshot => msgType == 'screenshot';
  bool get isStatus => msgType == 'status';
  bool get isFile => msgType == 'file' && fileId.isNotEmpty;
}
