import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 单个下载任务的状态
enum DownloadState { idle, downloading, done, error }

class DownloadTask extends ChangeNotifier {
  final String fileId;
  final String fileName;
  final String sessionId;
  final String sessionName;
  final String downloadUrl;
  final bool preferMediaDir;

  DownloadState _state = DownloadState.idle;
  double _progress = 0.0; // 0.0 ~ 1.0
  int _totalBytes = 0;
  int _receivedBytes = 0;
  double _speedBps = 0.0; // bytes per second
  String? _savedPath;
  String? _errorMsg;

  DownloadState get state => _state;
  double get progress => _progress;
  int get totalBytes => _totalBytes;
  int get receivedBytes => _receivedBytes;
  double get speedBps => _speedBps;
  String? get savedPath => _savedPath;
  String? get errorMsg => _errorMsg;

  String get speedText {
    if (_speedBps < 1024) return '${_speedBps.toStringAsFixed(0)} B/s';
    if (_speedBps < 1024 * 1024) return '${(_speedBps / 1024).toStringAsFixed(1)} KB/s';
    return '${(_speedBps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  DownloadTask({
    required this.fileId,
    required this.fileName,
    required this.sessionId,
    required this.sessionName,
    required this.downloadUrl,
    this.preferMediaDir = false,
  });

  /// 从已保存路径恢复完成状态
  void restoreFromPath(String path) {
    _savedPath = path;
    _progress = 1.0;
    _state = DownloadState.done;
  }

  /// 获取目标保存路径（不执行下载）
  Future<String> getTargetPath() async {
    final downloadDir = await _getDownloadDir();
    return '${downloadDir.path}/$fileName';
  }

  bool get _isImageFile {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic');
  }

  bool get _isMarkdownFile {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.md') || lower.endsWith('.markdown');
  }

  /// 自动重命名：file.txt -> file(1).txt
  String _autoRename(String path) {
    final file = File(path);
    if (!file.existsSync()) return path;
    final dir = file.parent.path;
    final name = fileName;
    final dotIdx = name.lastIndexOf('.');
    final base = dotIdx > 0 ? name.substring(0, dotIdx) : name;
    final ext = dotIdx > 0 ? name.substring(dotIdx) : '';
    for (int i = 1; i < 100; i++) {
      final newPath = '$dir/$base($i)$ext';
      if (!File(newPath).existsSync()) return newPath;
    }
    return '$dir/${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
  }

  Future<void> start({bool autoRename = false}) async {
    _state = DownloadState.downloading;
    _progress = 0.0;
    _receivedBytes = 0;
    _speedBps = 0.0;
    notifyListeners();

    try {
      final downloadDir = await _getDownloadDir();
      var savePath = '${downloadDir.path}/$fileName';
      if (autoRename) {
        savePath = _autoRename(savePath);
      }

      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await http.Client().send(request);

      _totalBytes = response.contentLength ?? 0;

      final file = File(savePath);
      final sink = file.openWrite();

      int lastBytes = 0;
      DateTime lastTime = DateTime.now();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        _receivedBytes += chunk.length;

        // 计算进度
        if (_totalBytes > 0) {
          _progress = _receivedBytes / _totalBytes;
        }

        // 计算速度 (每500ms更新一次)
        final now = DateTime.now();
        final elapsed = now.difference(lastTime).inMilliseconds;
        if (elapsed >= 500) {
          final deltaBytes = _receivedBytes - lastBytes;
          _speedBps = deltaBytes / (elapsed / 1000.0);
          lastBytes = _receivedBytes;
          lastTime = now;
          notifyListeners();
        }
      }

      await sink.flush();
      await sink.close();

      _savedPath = savePath;
      _progress = 1.0;
      _state = DownloadState.done;
      notifyListeners();

      // 持久化下载记录
      await DownloadService()._saveDownloadRecord(fileId, savePath);
    } catch (e) {
      _errorMsg = e.toString();
      _state = DownloadState.error;
      notifyListeners();
    }
  }

  Future<bool> _ensureWritableDirectory(Directory dir) async {
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File('${dir.path}/.write_probe_${DateTime.now().millisecondsSinceEpoch}');
      await probe.writeAsString('ok', flush: true);
      if (await probe.exists()) {
        await probe.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Directory> _getDownloadDir() async {
    final safeName = sessionName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

    // MD文件保存到app文档目录（非下载目录），便于自动清理
    if (_isMarkdownFile) {
      final appDir = await getApplicationDocumentsDirectory();
      final mdDir = Directory('${appDir.path}/IDEclaw/md_cache/$safeName');
      if (!await mdDir.exists()) {
        await mdDir.create(recursive: true);
      }
      return mdDir;
    }

    if (Platform.isAndroid) {
      final candidates = <Directory>[];

      if (preferMediaDir || _isImageFile) {
        candidates.add(Directory('/storage/emulated/0/Pictures'));
      }

      candidates.add(Directory('/storage/emulated/0/Download'));

      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        candidates.add(extDir);
      }

      candidates.add(await getApplicationDocumentsDirectory());

      for (final baseDir in candidates) {
        final dir = Directory('${baseDir.path}/IDEclaw/$safeName');
        if (await _ensureWritableDirectory(dir)) {
          return dir;
        }
      }
    }

    final fallback = Directory('${(await getApplicationDocumentsDirectory()).path}/IDEclaw/$safeName');
    if (!await fallback.exists()) {
      await fallback.create(recursive: true);
    }
    return fallback;
  }
}

/// 全局下载管理器（带持久化）
class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;
  DownloadService._();

  static const _prefsKey = 'download_records';
  final Map<String, DownloadTask> _tasks = {};
  Map<String, String> _savedRecords = {}; // fileId -> savedPath
  bool _loaded = false;

  /// 初始化：加载已下载记录
  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      _savedRecords = Map<String, String>.from(json.decode(raw));
      // 清理不存在的文件
      final toRemove = <String>[];
      for (final entry in _savedRecords.entries) {
        if (!File(entry.value).existsSync()) {
          toRemove.add(entry.key);
        }
      }
      for (final key in toRemove) {
        _savedRecords.remove(key);
      }
      if (toRemove.isNotEmpty) {
        await prefs.setString(_prefsKey, json.encode(_savedRecords));
      }
    }
    _loaded = true;
    // 清理超过7天的MD缓存文件
    unawaited(_cleanupOldMdCache());
  }

  Future<void> _cleanupOldMdCache() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mdCacheDir = Directory('${appDir.path}/IDEclaw/md_cache');
      if (!await mdCacheDir.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await for (final entity in mdCacheDir.list(recursive: true)) {
        if (entity is File) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        }
      }
    } catch (_) {}
  }

  DownloadTask? getTask(String fileId) {
    // 如果内存中有任务直接返回
    if (_tasks.containsKey(fileId)) return _tasks[fileId];
    // 否则检查持久化记录，恢复已下载的任务
    if (_savedRecords.containsKey(fileId)) {
      final path = _savedRecords[fileId]!;
      if (File(path).existsSync()) {
        final task = DownloadTask(
          fileId: fileId,
          fileName: path.split('/').last,
          sessionId: '',
          sessionName: '',
          downloadUrl: '',
        );
        task.restoreFromPath(path);
        _tasks[fileId] = task;
        return task;
      }
    }
    return null;
  }

  Future<void> _saveDownloadRecord(String fileId, String path) async {
    _savedRecords[fileId] = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, json.encode(_savedRecords));
  }

  /// 检查目标文件是否已存在（用于弹窗前检测）
  Future<bool> fileExists({
    required String fileName,
    required String sessionName,
    bool preferMediaDir = false,
  }) async {
    final task = DownloadTask(
      fileId: '', fileName: fileName,
      sessionId: '', sessionName: sessionName, downloadUrl: '',
      preferMediaDir: preferMediaDir,
    );
    final path = await task.getTargetPath();
    return File(path).existsSync();
  }

  DownloadTask startDownload({
    required String fileId,
    required String fileName,
    required String sessionId,
    required String sessionName,
    required String downloadUrl,
    bool autoRename = false,
    bool preferMediaDir = false,
  }) {
    // 如果已存在且完成或正在下载，返回现有任务
    if (_tasks.containsKey(fileId)) {
      final existing = _tasks[fileId]!;
      if (existing.state == DownloadState.downloading ||
          existing.state == DownloadState.done) {
        return existing;
      }
    }

    final task = DownloadTask(
      fileId: fileId,
      fileName: fileName,
      sessionId: sessionId,
      sessionName: sessionName,
      downloadUrl: downloadUrl,
      preferMediaDir: preferMediaDir,
    );
    _tasks[fileId] = task;
    task.addListener(() => notifyListeners());
    task.start(autoRename: autoRename);
    return task;
  }
}
