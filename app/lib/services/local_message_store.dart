import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/message.dart';

/// 本地消息持久化存储 — 按 sessionId 存储消息到 SharedPreferences
class LocalMessageStore {
  static const _prefix = 'chat_messages_';
  static const _maxMessages = 500; // 每个session最多保存500条

  final String sessionId;

  LocalMessageStore(this.sessionId);

  String get _key => '$_prefix$sessionId';

  /// 保存消息列表到本地
  Future<void> saveMessages(List<PushMessage> messages) async {
    final prefs = await SharedPreferences.getInstance();
    // 只保留最新的 _maxMessages 条
    final toSave = messages.length > _maxMessages
        ? messages.sublist(messages.length - _maxMessages)
        : messages;
    final jsonList = toSave.map((m) => m.toJson()).toList();
    await prefs.setString(_key, jsonEncode(jsonList));
  }

  /// 从本地加载消息列表
  Future<List<PushMessage>> loadMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((j) => PushMessage.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 清除本地消息
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
