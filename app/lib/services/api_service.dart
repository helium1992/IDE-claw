import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/message.dart';

class ApiService {
  final String serverUrl;
  final String token;

  ApiService({required this.serverUrl, required this.token});

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json; charset=utf-8',
      };

  Future<Map<String, dynamic>> healthCheck() async {
    final r = await http
        .get(Uri.parse('$serverUrl/api/health'))
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body);
  }

  Future<Map<String, dynamic>> getMessagesRaw(
      String sessionId, String? since) async {
    final params = {'session_id': sessionId};
    if (since != null) params['since'] = since;
    final uri = Uri.parse('$serverUrl/api/messages')
        .replace(queryParameters: params);
    final r = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    return jsonDecode(r.body);
  }

  Future<List<PushMessage>> getMessages(
      String sessionId, String? since) async {
    final data = await getMessagesRaw(sessionId, since);
    final list = data['messages'] as List? ?? [];
    return list.map((m) => PushMessage.fromJson(m)).toList();
  }

  Future<void> ackMessage(String messageId) async {
    await http
        .post(Uri.parse('$serverUrl/api/messages/$messageId/ack'),
            headers: _headers)
        .timeout(const Duration(seconds: 10));
  }

  Future<Map<String, dynamic>> sendCommand(
      String sessionId, String command, String params) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/commands'),
          headers: _headers,
          body: jsonEncode({
            'session_id': sessionId,
            'command': command,
            'params': params,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body);
  }

  Future<Map<String, dynamic>> uploadFile(
      String sessionId, String filePath, String fileName,
      List<int> fileBytes, {String caption = '', String sender = 'mobile'}) async {
    final uri = Uri.parse('$serverUrl/api/files/upload');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['session_id'] = sessionId
      ..fields['sender'] = sender
      ..fields['caption'] = caption.isEmpty ? fileName : caption
      ..files.add(http.MultipartFile.fromBytes('file', fileBytes, filename: fileName));
    final response = await request.send().timeout(const Duration(seconds: 60));
    final body = await response.stream.bytesToString();
    return jsonDecode(body);
  }

  String getFileDownloadUrl(String fileId, String sessionId) {
    return '$serverUrl/api/files/$fileId?session_id=$sessionId&token=$token';
  }

  Future<List<int>> downloadFile(String fileId, String sessionId) async {
    final r = await http.get(
      Uri.parse('$serverUrl/api/files/$fileId')
          .replace(queryParameters: {'session_id': sessionId}),
      headers: _headers,
    ).timeout(const Duration(seconds: 60));
    return r.bodyBytes;
  }

  Future<List<Map<String, dynamic>>> getSessions() async {
    final r = await http
        .get(Uri.parse('$serverUrl/api/sessions'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    final data = jsonDecode(r.body);
    final list = data['sessions'] as List? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> markSessionRead(String sessionId) async {
    await http
        .post(
          Uri.parse('$serverUrl/api/sessions/mark_read'),
          headers: _headers,
          body: jsonEncode({'session_id': sessionId}),
        )
        .timeout(const Duration(seconds: 5));
  }

  Future<Map<String, dynamic>> getAuthToken(
      String sessionId, String secret) async {
    final r = await http
        .post(
          Uri.parse('$serverUrl/api/auth/token'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'session_id': sessionId,
            'secret': secret,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body);
  }
}
