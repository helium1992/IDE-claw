import 'dart:convert';
import 'dart:io';

class WindsurfAccountScriptService {
  String? _baseDir;

  String? get baseDir => _baseDir ??= _resolveBaseDir();

  String? get cascadeDir {
    final resolvedBaseDir = baseDir;
    if (resolvedBaseDir == null || resolvedBaseDir.isEmpty) {
      return null;
    }
    return _join(resolvedBaseDir, 'cascade');
  }

  String? get scriptPath {
    final resolvedCascadeDir = cascadeDir;
    if (resolvedCascadeDir == null || resolvedCascadeDir.isEmpty) {
      return null;
    }
    return _join(resolvedCascadeDir, 'windsurf_account_switch.py');
  }

  String? get accountsFilePath {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) {
        return null;
      }
      return _join(
        appData,
        'Windsurf',
        'User',
        'globalStorage',
        'windsurf-login-accounts.json',
      );
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return null;
    }
    if (Platform.isMacOS) {
      return _join(
        home,
        'Library',
        'Application Support',
        'Windsurf',
        'User',
        'globalStorage',
        'windsurf-login-accounts.json',
      );
    }
    return _join(
      home,
      '.config',
      'Windsurf',
      'User',
      'globalStorage',
      'windsurf-login-accounts.json',
    );
  }

  Future<Map<String, dynamic>> getStatus() {
    return _runJsonCommand(const <String>['status']);
  }

  Future<Map<String, dynamic>> refreshCredits({
    List<String>? emails,
    bool force = false,
  }) {
    final args = <String>['refresh_credits'];
    for (final email in emails ?? const <String>[]) {
      final trimmed = email.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      args
        ..add('--email')
        ..add(trimmed);
    }
    if (force) {
      args.add('--force');
    }
    return _runJsonCommand(args);
  }

  Future<Map<String, dynamic>> switchTo(
    String email, {
    bool allowBootstrap = true,
  }) {
    final trimmed = email.trim();
    final args = <String>['switch_to', '--email', trimmed];
    if (allowBootstrap) {
      args.add('--allow-bootstrap');
    }
    return _runJsonCommand(args);
  }

  Future<Map<String, dynamic>> switchNext({
    bool allowBootstrap = true,
    bool ignoreCooldown = true,
  }) {
    final args = <String>['switch'];
    if (allowBootstrap) {
      args.add('--allow-bootstrap');
    }
    if (ignoreCooldown) {
      args.add('--ignore-cooldown');
    }
    return _runJsonCommand(args);
  }

  Future<Map<String, dynamic>> importAndBootstrap(
    List<Map<String, String>> accounts,
  ) async {
    if (accounts.isEmpty) {
      return <String, dynamic>{
        'status': 'no_action',
        'message': '没有可导入的账号',
      };
    }
    final tempDir = await Directory.systemTemp.createTemp('windsurf_accounts_');
    final inputFile = File(_join(tempDir.path, 'accounts.json'));
    try {
      final payload = <String, dynamic>{'accounts': accounts};
      await inputFile.writeAsString(jsonEncode(payload), flush: true);
      return await _runJsonCommand(<String>[
        'import_and_bootstrap',
        '--input-file',
        inputFile.path,
      ]);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  Future<List<Map<String, dynamic>>> loadLocalAccounts() async {
    final path = accountsFilePath;
    if (path == null || path.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    final file = File(path);
    if (!await file.exists()) {
      return const <Map<String, dynamic>>[];
    }
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <Map<String, dynamic>>[];
      }
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<Map<String, dynamic>> _runJsonCommand(List<String> args) async {
    final resolvedBaseDir = baseDir;
    final resolvedCascadeDir = cascadeDir;
    final resolvedScriptPath = scriptPath;
    if (resolvedBaseDir == null ||
        resolvedCascadeDir == null ||
        resolvedScriptPath == null) {
      return <String, dynamic>{
        'status': 'error',
        'message': '无法定位 Windsurf 脚本目录',
      };
    }
    final pythonExecutable = await _resolvePythonExecutable(resolvedBaseDir);
    final result = await Process.run(
      pythonExecutable,
      <String>[resolvedScriptPath, ...args],
      workingDirectory: resolvedCascadeDir,
      runInShell: false,
    );
    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    if (result.exitCode != 0) {
      return <String, dynamic>{
        'status': 'error',
        'message': stderr.isNotEmpty
            ? stderr
            : (stdout.isNotEmpty ? stdout : '命令执行失败 (${result.exitCode})'),
        'exit_code': result.exitCode,
        'stdout': stdout,
        'stderr': stderr,
      };
    }
    if (stdout.isEmpty) {
      return <String, dynamic>{
        'status': 'error',
        'message': '脚本没有输出 JSON',
        'stderr': stderr,
      };
    }
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return <String, dynamic>{
        'status': 'error',
        'message': '脚本返回不是对象',
        'stdout': stdout,
      };
    } catch (_) {
      return <String, dynamic>{
        'status': 'error',
        'message': '脚本返回不是合法 JSON',
        'stdout': stdout,
        'stderr': stderr,
      };
    }
  }

  Future<String> _resolvePythonExecutable(String baseDir) async {
    final parentDir = Directory(baseDir).parent.path;
    final candidates = <String>[
      if (Platform.isWindows) _join(baseDir, 'venv', 'Scripts', 'pythonw.exe'),
      if (Platform.isWindows) _join(baseDir, 'venv', 'Scripts', 'python.exe'),
      if (Platform.isWindows) _join(parentDir, 'venv', 'Scripts', 'pythonw.exe'),
      if (Platform.isWindows) _join(parentDir, 'venv', 'Scripts', 'python.exe'),
      _join(baseDir, 'venv', 'bin', 'python'),
      _join(parentDir, 'venv', 'bin', 'python'),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    if (Platform.isWindows) {
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
    }
    return 'python';
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
      final accountScript = File(_join(candidate, 'cascade', 'windsurf_account_switch.py'));
      final dialogScript = File(_join(candidate, 'cascade', 'dialog.py'));
      if (accountScript.existsSync() || dialogScript.existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  String _join(
    String first,
    String second, [
    String? third,
    String? fourth,
    String? fifth,
    String? sixth,
    String? seventh,
  ]) {
    final segments = <String>[first, second];
    if (third != null) {
      segments.add(third);
    }
    if (fourth != null) {
      segments.add(fourth);
    }
    if (fifth != null) {
      segments.add(fifth);
    }
    if (sixth != null) {
      segments.add(sixth);
    }
    if (seventh != null) {
      segments.add(seventh);
    }
    return segments.join(Platform.pathSeparator);
  }
}
