import 'dart:convert';
import 'dart:io';

class WindsurfAutoServiceLauncher {
  Process? _process;
  int? _pid;
  String? _baseDir;
  bool _launchedHere = false;

  String? get baseDir => _baseDir ?? _resolveBaseDir();
  String? get statusFilePath {
    final resolvedBaseDir = baseDir;
    if (resolvedBaseDir == null || resolvedBaseDir.isEmpty) {
      return null;
    }
    return _join(resolvedBaseDir, 'data', 'windsurf_auto_service_status.json');
  }

  int? get pid => _pid;
  bool get isRunning => _pid != null;

  Future<void> start() async {
    if (!Platform.isWindows) {
      return;
    }
    _appendLog(
      'start requested resolvedExecutable=${Platform.resolvedExecutable} currentDir=${Directory.current.path}',
    );
    final baseDir = _resolveBaseDir();
    if (baseDir == null || baseDir.isEmpty) {
      _appendLog('start skipped: base dir unresolved');
      return;
    }
    _baseDir = baseDir;
    _appendLog('resolved base dir=$baseDir', baseDir: baseDir);
    final config = await _loadConfig(baseDir);
    final cascadeDir = _resolveCascadeDir(baseDir);
    final bundledServiceExecutable = _resolveBundledServiceExecutable(baseDir);
    final bundledServiceAvailable = File(bundledServiceExecutable).existsSync() && Directory(cascadeDir).existsSync();
    if (config['auto_detection_service_enabled'] == false) {
      _writeStatusFile(
        baseDir,
        <String, dynamic>{
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          'service_running': false,
          'service_enabled': false,
          'phase': 'disabled',
          'status': 'disabled',
          'summary': '检测服务已关闭（配置）',
          'selected_target': '',
          'candidate_target': '',
          'candidate_streak': 0,
          'confirm_rounds': 0,
          'action_executed': false,
          'last_action_target': '',
          'last_action_status': '',
          'last_action_at': 0,
          'awaiting_progress_reset': false,
          'awaiting_progress_target': '',
          'cooldown_remaining_ms': 0,
          'quiet_remaining_ms': 0,
          'holdoff_remaining_ms': 0,
          'has_target_button': false,
          'detected_target_names': <String>[],
          'button_states': <Map<String, dynamic>>[],
          'confidence_trace': <String>[],
          'gate_reason': '',
        },
      );
      _appendLog('start skipped: auto detection disabled by config', baseDir: baseDir);
      return;
    }
    final serviceScript = _join(baseDir, 'cascade', 'windsurf_auto_service.py');
    if (!bundledServiceAvailable && !File(serviceScript).existsSync()) {
      _writeStatusFile(
        baseDir,
        <String, dynamic>{
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          'service_running': false,
          'service_enabled': true,
          'phase': 'error',
          'status': 'missing_script',
          'summary': '检测脚本或内置运行时不存在，无法启动服务',
          'selected_target': '',
          'candidate_target': '',
          'candidate_streak': 0,
          'confirm_rounds': 0,
          'action_executed': false,
          'last_action_target': '',
          'last_action_status': '',
          'last_action_at': 0,
          'awaiting_progress_reset': false,
          'awaiting_progress_target': '',
          'cooldown_remaining_ms': 0,
          'quiet_remaining_ms': 0,
          'holdoff_remaining_ms': 0,
          'has_target_button': false,
          'detected_target_names': <String>[],
          'button_states': <Map<String, dynamic>>[],
          'confidence_trace': <String>[],
          'gate_reason': '',
        },
      );
      _appendLog(
        'start skipped: service script missing at $serviceScript and bundled runtime missing at $bundledServiceExecutable',
        baseDir: baseDir,
      );
      return;
    }
    // Guard: if we already know a running pid, check it first (avoids race with PID file)
    if (_pid != null && await _isPidRunning(_pid!)) {
      _appendLog('start skipped: already tracking running pid=$_pid', baseDir: baseDir);
      return;
    }
    final pidFile = _pidFile(baseDir);
    final existingPid = _readPid(pidFile);
    if (existingPid != null && await _isPidRunning(existingPid)) {
      if (!_hasFreshStatusFile(baseDir)) {
        _appendLog('existing service pid=$existingPid has no fresh status file, restarting', baseDir: baseDir);
        try {
          Process.killPid(existingPid);
        } catch (_) {}
        try {
          File(pidFile).deleteSync();
        } catch (_) {}
      } else {
        _pid = existingPid;
        _launchedHere = false;
        final existingStart = _readStatusFile(baseDir);
        _writeStatusFile(
          baseDir,
          <String, dynamic>{
            ...existingStart,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
            'service_running': true,
            'service_enabled': true,
            'phase': 'running',
            'status': 'already_running',
            'summary': '检测服务已在运行，等待状态同步',
          },
        );
        _appendLog('service already running pid=$existingPid', baseDir: baseDir);
        return;
      }
    }
    if (existingPid != null) {
      _appendLog('stale pid file detected pid=$existingPid', baseDir: baseDir);
      try {
        File(pidFile).deleteSync();
      } catch (_) {}
    }
    final environment = Map<String, String>.from(Platform.environment);
    environment['IDE_CLAW_BASE_DIR'] = baseDir;
    environment['IDE_CLAW_CASCADE_DIR'] = cascadeDir;
    try {
      late final Process process;
      if (bundledServiceAvailable) {
        _appendLog('resolved bundled runtime executable=$bundledServiceExecutable', baseDir: baseDir);
        process = await Process.start(
          bundledServiceExecutable,
          const <String>[],
          workingDirectory: File(bundledServiceExecutable).parent.path,
          environment: environment,
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
      } else {
        final pythonExecutable = await _resolvePythonExecutable(baseDir);
        _appendLog('resolved python executable=$pythonExecutable', baseDir: baseDir);
        process = await Process.start(
          pythonExecutable,
          <String>[serviceScript],
          workingDirectory: _join(baseDir, 'cascade'),
          environment: environment,
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
      }
      _process = process;
      _pid = process.pid;
      _launchedHere = true;
      // Write PID file immediately so concurrent start() calls see it
      try {
        File(pidFile).writeAsStringSync('${process.pid}', flush: true);
      } catch (_) {}
      // Clear any stale error status from previous crashes
      _writeStatusFile(
        baseDir,
        <String, dynamic>{
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          'service_running': true,
          'service_enabled': true,
          'phase': 'running',
          'status': 'starting',
          'summary': '检测服务正在启动...',
          'selected_target': '',
          'candidate_target': '',
          'candidate_streak': 0,
          'confirm_rounds': 0,
          'action_executed': false,
          'last_action_target': '',
          'last_action_status': '',
          'last_action_at': 0,
          'awaiting_progress_reset': false,
          'awaiting_progress_target': '',
          'cooldown_remaining_ms': 0,
          'quiet_remaining_ms': 0,
          'holdoff_remaining_ms': 0,
          'has_target_button': false,
          'detected_target_names': <String>[],
          'button_states': <Map<String, dynamic>>[],
          'confidence_trace': <String>[],
          'gate_reason': '',
        },
      );
      _appendLog('service process started pid=${process.pid}', baseDir: baseDir);
    } catch (e, st) {
      final existingFail = _readStatusFile(baseDir);
      _writeStatusFile(
        baseDir,
        <String, dynamic>{
          ...existingFail,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          'service_running': false,
          'service_enabled': true,
          'phase': 'error',
          'status': 'start_failed',
          'summary': '检测服务启动失败：$e',
        },
      );
      _appendLog('service process start failed: $e\n$st', baseDir: baseDir);
    }
  }

  Future<void> stop({bool force = false}) async {
    final baseDir = _baseDir ?? _resolveBaseDir();
    final pid = _pid ?? (baseDir == null ? null : _readPid(_pidFile(baseDir)));
    if (!_launchedHere && !force && pid == null) {
      if (baseDir != null) {
        _appendLog('stop skipped: no running service pid found', baseDir: baseDir);
      }
      _process = null;
      _pid = null;
      _launchedHere = false;
      return;
    }
    if (_process != null) {
      _process!.kill();
    }
    if (pid != null) {
      try {
        Process.killPid(pid);
      } catch (_) {}
    }
    // Delete PID file to prevent stale detection on next start()
    if (baseDir != null) {
      try {
        final pf = File(_pidFile(baseDir));
        if (pf.existsSync()) pf.deleteSync();
      } catch (_) {}
    }
    if (baseDir != null) {
      // Read existing status to preserve detection data on pause
      final existing = _readStatusFile(baseDir);
      final merged = <String, dynamic>{
        ...existing,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'service_running': false,
        'service_enabled': true,
        'phase': 'stopped',
        'status': 'stopped',
        'summary': '检测服务已停止',
        'selected_target': '',
        'candidate_target': '',
        'candidate_streak': 0,
        'confirm_rounds': 0,
        'action_executed': false,
        'awaiting_progress_reset': false,
        'awaiting_progress_target': '',
        'cooldown_remaining_ms': 0,
        'quiet_remaining_ms': 0,
        'holdoff_remaining_ms': 0,
      };
      _writeStatusFile(baseDir, merged);
      _appendLog('stop requested pid=$pid force=$force launchedHere=$_launchedHere', baseDir: baseDir);
    }
    _process = null;
    _pid = null;
    _launchedHere = false;
  }

  void _appendLog(String message, {String? baseDir}) {
    final rootDir = baseDir ?? File(Platform.resolvedExecutable).parent.path;
    final dataDir = Directory(_join(rootDir, 'data'));
    final logFile = File(_join(rootDir, 'data', 'windsurf_auto_service_launcher.log'));
    final timestamp = DateTime.now().toIso8601String();
    try {
      dataDir.createSync(recursive: true);
      logFile.writeAsStringSync('[$timestamp] $message\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Map<String, dynamic> _readStatusFile(String baseDir) {
    final file = File(_join(baseDir, 'data', 'windsurf_auto_service_status.json'));
    try {
      if (file.existsSync()) {
        final raw = file.readAsStringSync();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  void _writeStatusFile(String baseDir, Map<String, dynamic> payload) {
    final file = File(_join(baseDir, 'data', 'windsurf_auto_service_status.json'));
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(payload), flush: true);
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _loadConfig(String baseDir) async {
    final file = File(_join(_resolveCascadeDir(baseDir), 'config', 'windsurf_dialog_config.json'));
    if (!file.existsSync()) {
      return <String, dynamic>{};
    }
    try {
      final raw = await file.readAsString();
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        return data;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<String> _resolvePythonExecutable(String baseDir) async {
    final parentDir = Directory(baseDir).parent.path;
    final candidates = <String>[
      if (Platform.isWindows) _join(baseDir, 'venv', 'Scripts', 'pythonw.exe'),
      _join(baseDir, 'venv', 'Scripts', 'python.exe'),
      if (Platform.isWindows) _join(parentDir, 'venv', 'Scripts', 'pythonw.exe'),
      _join(parentDir, 'venv', 'Scripts', 'python.exe'),
      _join(baseDir, 'venv', 'bin', 'python'),
      _join(parentDir, 'venv', 'bin', 'python'),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    for (final command in <String>['pythonw', 'python', 'pyw', 'py']) {
      try {
        final result = await Process.run('where', <String>[command]);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().split(RegExp(r'\r?\n'));
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty) {
              return trimmed;
            }
          }
        }
      } catch (_) {}
    }
    return 'python';
  }

  String _resolveBundledRuntimeDir(String baseDir) => _join(baseDir, 'windsurf_runtime');

  String _resolveBundledServiceExecutable(String baseDir) =>
      _join(_resolveBundledRuntimeDir(baseDir), 'windsurf_auto_service.exe');

  String _resolveCascadeDir(String baseDir) {
    final bundledCascadeDir = _join(_resolveBundledRuntimeDir(baseDir), 'cascade');
    if (Directory(bundledCascadeDir).existsSync()) {
      return bundledCascadeDir;
    }
    return _join(baseDir, 'cascade');
  }

  Future<bool> _isPidRunning(int pid) async {
    try {
      final result = await Process.run('tasklist', <String>['/FI', 'PID eq $pid']);
      if (result.exitCode != 0) {
        return false;
      }
      return result.stdout.toString().contains('$pid');
    } catch (_) {
      return false;
    }
  }

  bool _hasFreshStatusFile(String baseDir) {
    final file = File(_join(baseDir, 'data', 'windsurf_auto_service_status.json'));
    try {
      if (!file.existsSync()) {
        return false;
      }
      final modified = file.lastModifiedSync();
      return DateTime.now().difference(modified) <= const Duration(seconds: 20);
    } catch (_) {
      return false;
    }
  }

  int? _readPid(String pidFile) {
    try {
      final file = File(pidFile);
      if (!file.existsSync()) {
        return null;
      }
      return int.tryParse(file.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  String? _resolveBaseDir() {
    final candidates = <String>[];
    void addParents(String path, int depth) {
      var current = Directory(path);
      for (var i = 0; i < depth; i++) {
        final normalized = current.path;
        if (!candidates.contains(normalized)) {
          candidates.add(normalized);
        }
        final parent = current.parent;
        if (parent.path == current.path) {
          break;
        }
        current = parent;
      }
    }

    addParents(File(Platform.resolvedExecutable).parent.path, 8);
    addParents(Directory.current.path, 6);

    for (final candidate in candidates) {
      final dialogScript = File(_join(candidate, 'cascade', 'dialog.py'));
      final serviceScript = File(_join(candidate, 'cascade', 'windsurf_auto_service.py'));
      final bundledServiceExecutable = File(_resolveBundledServiceExecutable(candidate));
      final bundledConfig = File(
        _join(_join(candidate, 'windsurf_runtime', 'cascade'), 'config', 'windsurf_dialog_config.json'),
      );
      if (
        dialogScript.existsSync() ||
        serviceScript.existsSync() ||
        bundledServiceExecutable.existsSync() ||
        bundledConfig.existsSync()
      ) {
        return candidate;
      }
    }
    return null;
  }

  String _pidFile(String baseDir) => _join(baseDir, 'data', 'windsurf_auto_service.pid');

  String _join(String first, String second, [String? third, String? fourth]) {
    final segments = <String>[first, second];
    if (third != null) {
      segments.add(third);
    }
    if (fourth != null) {
      segments.add(fourth);
    }
    return segments.join(Platform.pathSeparator);
  }
}
