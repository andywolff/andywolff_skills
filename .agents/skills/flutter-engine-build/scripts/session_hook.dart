import 'dart:convert';
import 'dart:io';

/// Generic agent lifecycle hook for Flutter worktree session leases.
///
/// Compile to a native binary for low-latency hook execution (~10-20ms):
///   dart compile exe scripts/session_hook.dart -o ~/.cache/flutter_engine_build/session_hook
///
/// Handles `post` (PostToolUse), `stop` (Stop), and `pre` (PreToolUse) events
/// to maintain `<gitdir>/agent_session.json` without dirtying git status,
/// surface dehydration/eviction notices, and optionally notify queued space
/// waiters via `AGENT_NOTIFY_CMD`.
void main(List<String> args) {
  final mode = args.isNotEmpty ? args.first : 'post';
  Map<String, dynamic> payload = const {};
  try {
    final raw = _readAllStdin();
    if (raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        payload = decoded;
      }
    }
  } catch (_) {}

  final sessionId =
      (payload['sessionId'] as String?) ??
      (payload['conversationId'] as String?);
  if (sessionId == null || sessionId.isEmpty) {
    stdout.writeln('{}');
    return;
  }

  final out = switch (mode) {
    'post' => _handlePostToolUse(payload, sessionId),
    'stop' => _handleStop(payload, sessionId),
    'pre' => _handlePreToolUse(payload),
    _ => const <String, dynamic>{},
  };

  stdout.writeln(jsonEncode(out));
}

String _readAllStdin() {
  final buffer = StringBuffer();
  while (true) {
    final line = stdin.readLineSync();
    if (line == null) break;
    buffer.writeln(line);
  }
  return buffer.toString();
}

String _nowIso() => DateTime.now().toUtc().toIso8601String();

bool _isFlutterWorktree(Directory dir) {
  try {
    return Directory('${dir.path}/engine/src/flutter').existsSync() &&
        (Directory('${dir.path}/.git').existsSync() ||
            File('${dir.path}/.git').existsSync());
  } catch (_) {
    return false;
  }
}

Directory? _resolveGitDir(Directory worktree) {
  final dotGitDir = Directory('${worktree.path}/.git');
  if (dotGitDir.existsSync()) return dotGitDir;
  final dotGitFile = File('${worktree.path}/.git');
  if (dotGitFile.existsSync()) {
    try {
      final text = dotGitFile.readAsStringSync().trim();
      if (text.startsWith('gitdir:')) {
        final raw = text.substring('gitdir:'.length).trim();
        final resolved = raw.startsWith('/')
            ? Directory(raw)
            : Directory('${worktree.path}/$raw');
        if (resolved.existsSync()) {
          return Directory(resolved.resolveSymbolicLinksSync());
        }
      }
    } catch (_) {}
  }
  return null;
}

String? _readBranch(Directory gitDir) {
  try {
    final head = File('${gitDir.path}/HEAD').readAsStringSync().trim();
    const prefix = 'ref: refs/heads/';
    if (head.startsWith(prefix)) {
      return head.substring(prefix.length);
    }
  } catch (_) {}
  return null;
}

dynamic _readJson(File file) {
  if (!file.existsSync()) return null;
  try {
    return jsonDecode(file.readAsStringSync());
  } catch (_) {
    return null;
  }
}

void _writeJson(File file, Map<String, dynamic> data) {
  try {
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(data)}\n',
    );
  } catch (_) {}
}

String _baseName(String path) =>
    path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;

List<Directory> _findCandidateWorktrees(Map<String, dynamic> payload) {
  final found = <Directory>[];
  final seen = <String>{};

  void addIfWorktree(Directory dir) {
    try {
      if (!dir.existsSync()) return;
      final resolved = Directory(dir.resolveSymbolicLinksSync());
      if (seen.contains(resolved.path)) return;
      if (_isFlutterWorktree(resolved)) {
        seen.add(resolved.path);
        found.add(resolved);
      }
    } catch (_) {}
  }

  final rawWorkspaces = payload['workspacePaths'];
  final workspacePaths = <Directory>[
    if (rawWorkspaces is List)
      for (final p in rawWorkspaces.whereType<String>()) Directory(p),
  ];

  for (final ws in workspacePaths) {
    addIfWorktree(ws);
  }

  final toolInput = payload['toolInput'] ?? payload['args'] ?? const {};
  var toolBlob = jsonEncode(toolInput);
  // Strip SDK binary invocations so calling flutter/bin/dart does not claim flutter/.
  toolBlob = toolBlob.replaceAll(RegExp(r'flutter/bin/(dart|flutter)\b'), '');

  for (final ws in workspacePaths) {
    if (!ws.existsSync()) continue;
    try {
      for (final entity in ws.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = _baseName(entity.path);
        if (name.startsWith('.') || name == 'andywolff_skills') continue;
        final childStr = entity.path;
        final matched =
            toolBlob.contains('$childStr/') ||
            toolBlob.contains('$childStr"') ||
            toolBlob.contains('$childStr ') ||
            RegExp(
              '(?:^|[\\s"\'=(])${RegExp.escape(name)}/',
            ).hasMatch(toolBlob);
        if (matched) {
          addIfWorktree(entity);
        }
      }
    } catch (_) {}
  }

  return found;
}

Map<String, dynamic> _handlePostToolUse(
  Map<String, dynamic> payload,
  String sessionId,
) {
  for (final wt in _findCandidateWorktrees(payload)) {
    final gitDir = _resolveGitDir(wt);
    if (gitDir == null) continue;
    final leaseFile = File('${gitDir.path}/agent_session.json');
    final existing = _readJson(leaseFile);
    final existingMap = existing is Map<String, dynamic>
        ? existing
        : const <String, dynamic>{};
    final lease = <String, dynamic>{
      'sessionId': sessionId,
      'branch': _readBranch(gitDir) ?? existingMap['branch'],
      'state': 'busy',
      'lastHeartbeat': _nowIso(),
      if (existingMap['buildPid'] is int) 'buildPid': existingMap['buildPid'],
    };
    _writeJson(leaseFile, lease);
  }
  return const {};
}

Map<String, dynamic> _handleStop(
  Map<String, dynamic> payload,
  String sessionId,
) {
  final rawWorkspaces = payload['workspacePaths'];
  final workspacePaths = <Directory>[
    if (rawWorkspaces is List)
      for (final p in rawWorkspaces.whereType<String>()) Directory(p),
  ];

  final checkedParents = <String>{};
  final updatedWorktrees = <String>[];

  void maybeFlipIdle(Directory wt) {
    if (!_isFlutterWorktree(wt)) return;
    final gitDir = _resolveGitDir(wt);
    if (gitDir == null) return;
    final leaseFile = File('${gitDir.path}/agent_session.json');
    final existing = _readJson(leaseFile);
    if (existing is! Map<String, dynamic>) return;
    final owner =
        (existing['sessionId'] as String?) ??
        (existing['conversationId'] as String?);
    if (owner != sessionId) return;
    if (existing['state'] == 'busy') {
      existing['state'] = 'idle';
      existing['lastHeartbeat'] = _nowIso();
      existing.remove('buildPid');
      _writeJson(leaseFile, existing);
      updatedWorktrees.add(_baseName(wt.path));
      checkedParents.add(wt.parent.path);
    }
  }

  for (final ws in workspacePaths) {
    if (!ws.existsSync()) continue;
    if (_isFlutterWorktree(ws)) {
      maybeFlipIdle(ws);
    } else {
      checkedParents.add(ws.path);
      try {
        for (final entity in ws.listSync(followLinks: false)) {
          if (entity is Directory && !_baseName(entity.path).startsWith('.')) {
            maybeFlipIdle(entity);
          }
        }
      } catch (_) {}
    }
  }

  final notifyCmd = Platform.environment['AGENT_NOTIFY_CMD'];
  if (updatedWorktrees.isNotEmpty &&
      notifyCmd != null &&
      notifyCmd.trim().isNotEmpty) {
    final shortId = sessionId.length > 8
        ? sessionId.substring(0, 8)
        : sessionId;
    for (final parentPath in checkedParents) {
      final waiters = _readJson(File('$parentPath/.flutter_space_waiters.json'));
      if (waiters is! List) continue;
      for (final w in waiters.whereType<Map<String, dynamic>>()) {
        final targetId =
            (w['sessionId'] as String?) ?? (w['conversationId'] as String?);
        if (targetId == null || targetId.isEmpty || targetId == sessionId) {
          continue;
        }
        final msg =
            'Turn finished for session $shortId on ${updatedWorktrees.join(', ')}. '
            'If you are still blocked on disk space, check `engine_build.dart --status` or request release.';
        try {
          Process.start(
            'sh',
            ['-c', '$notifyCmd "\$1" "\$2"', '_', targetId, msg],
            mode: ProcessStartMode.detached,
          );
        } catch (_) {}
      }
    }
  }

  return const {};
}

Map<String, dynamic> _handlePreToolUse(Map<String, dynamic> payload) {
  final toolInput = payload['toolInput'] ?? payload['args'] ?? const {};
  final toolBlob = jsonEncode(toolInput);
  if (!RegExp(r'\b(ninja|et\s+build|gn\s+gen)\b').hasMatch(toolBlob)) {
    return const {};
  }

  final warnings = <String>[];
  for (final wt in _findCandidateWorktrees(payload)) {
    final gitDir = _resolveGitDir(wt);
    if (gitDir == null) continue;
    final eviction = _readJson(File('${gitDir.path}/eviction_state.json'));
    if (eviction is Map<String, dynamic>) {
      final action = eviction['action'] ?? 'evicted';
      final at = eviction['at'] ?? 'unknown time';
      final reclaimed = eviction['reclaimedHuman'] ?? 'unknown size';
      final wtName = _baseName(wt.path);
      warnings.add(
        "Worktree '$wtName' was $action at $at (reclaimed $reclaimed). "
        'Use `engine_build.dart --workspace $wtName -- <cmd>` to rehydrate and enforce the 40G disk floor.',
      );
    }
  }

  if (warnings.isNotEmpty) {
    return {'systemMessage': warnings.join(' ')};
  }
  return const {};
}
