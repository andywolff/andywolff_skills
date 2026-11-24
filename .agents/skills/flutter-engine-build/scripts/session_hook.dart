import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lib/workspace_utils.dart';

/// Generic agent lifecycle hook for Flutter worktree session leases.
///
/// Compile to a native binary for low-latency hook execution (~10-20ms):
///   dart compile exe scripts/session_hook.dart -o ~/.cache/flutter_engine_build/session_hook
///
/// Handles `post` (PostToolUse), `stop` (Stop), `pre-invocation`
/// (PreInvocation), and `pre` (PreToolUse) events to maintain
/// `<gitdir>/agent_session.json` without dirtying git status, surface
/// dehydration/eviction notices, and optionally notify queued space waiters
/// via `AGENT_NOTIFY_CMD`.
void main(List<String> args) {
  final mode = args.isNotEmpty ? args.first : 'post';
  Map<String, dynamic> payload = const <String, dynamic>{};
  try {
    final raw = _readAllStdin();
    if (raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        payload = decoded;
      }
    }
  } catch (_) {
    // Ignore malformed hook payloads and fall back to a safe no-op response.
  }

  final sessionId =
      (payload['sessionId'] as String?) ??
      (payload['conversationId'] as String?);
  if (sessionId == null || sessionId.isEmpty) {
    stdout.writeln(
      jsonEncode(
        mode == 'pre'
            ? const <String, dynamic>{'decision': 'allow'}
            : mode == 'stop'
            ? const <String, dynamic>{'decision': 'stop'}
            : const <String, dynamic>{},
      ),
    );
    return;
  }

  final out = switch (mode) {
    'post' => _handlePostToolUse(payload, sessionId),
    'stop' => _handleStop(payload, sessionId),
    'pre' => _handlePreToolUse(payload),
    'pre-invocation' => _handlePreInvocation(payload),
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
    } catch (_) {
      return null;
    }
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
  } catch (_) {
    // Detached HEAD or unreadable HEAD file.
  }
  return null;
}

Object _extractToolInput(Map<String, dynamic> payload) {
  final toolCall = payload['toolCall'];
  if (toolCall is Map && toolCall['args'] != null) {
    return toolCall['args'] as Object;
  }
  return (payload['toolInput'] ?? payload['args'] ?? const <String, dynamic>{})
      as Object;
}

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
    } catch (_) {
      // Skip inaccessible directories.
    }
  }

  final rawWorkspaces = payload['workspacePaths'];
  final workspacePaths = <Directory>[
    if (rawWorkspaces is List)
      for (final p in rawWorkspaces.whereType<String>()) Directory(p),
  ];

  for (final ws in workspacePaths) {
    addIfWorktree(ws);
  }

  var toolBlob = jsonEncode(_extractToolInput(payload));
  // Strip SDK binary invocations so calling flutter/bin/dart does not claim flutter/.
  toolBlob = toolBlob.replaceAll(RegExp(r'flutter/bin/(dart|flutter)\b'), '');

  for (final ws in workspacePaths) {
    if (!ws.existsSync()) continue;
    try {
      for (final entity in ws.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = baseName(entity.path);
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
    } catch (_) {
      // Skip unreadable parent directories.
    }
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
    final existing = readJsonMap(leaseFile.path) ?? const <String, dynamic>{};
    final lease = <String, dynamic>{
      'sessionId': sessionId,
      'branch': _readBranch(gitDir) ?? existing['branch'],
      'state': 'busy',
      'lastHeartbeat': _nowIso(),
      if (existing['buildPid'] is int) 'buildPid': existing['buildPid'],
    };
    atomicWriteJson(leaseFile, lease);
  }
  return const <String, dynamic>{};
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
    final existing = readJsonMap(leaseFile.path);
    if (existing == null) return;
    final owner =
        (existing['sessionId'] as String?) ??
        (existing['conversationId'] as String?);
    if (owner != sessionId) return;
    if (existing['state'] == 'busy') {
      existing['state'] = 'idle';
      existing['lastHeartbeat'] = _nowIso();
      existing.remove('buildPid');
      atomicWriteJson(leaseFile, existing);
      updatedWorktrees.add(baseName(wt.path));
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
          if (entity is Directory && !baseName(entity.path).startsWith('.')) {
            maybeFlipIdle(entity);
          }
        }
      } catch (_) {
        // Skip unreadable parent directories.
      }
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
      final waiters = readJsonDynamic(
        File('$parentPath/.flutter_space_waiters.json'),
      );
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
          unawaited(
            Process.start(
              'sh',
              <String>['-c', '$notifyCmd "\$1" "\$2"', '_', targetId, msg],
              mode: ProcessStartMode.detached,
            ),
          );
        } catch (_) {
          // Best-effort notification.
        }
      }
    }
  }

  return const <String, dynamic>{'decision': 'stop'};
}

Map<String, dynamic> _handlePreToolUse(Map<String, dynamic> payload) {
  final toolBlob = jsonEncode(_extractToolInput(payload));
  if (!RegExp(r'\b(ninja|et\s+build|gn\s+gen)\b').hasMatch(toolBlob)) {
    return const <String, dynamic>{'decision': 'allow'};
  }

  final warnings = <String>[];
  for (final wt in _findCandidateWorktrees(payload)) {
    final gitDir = _resolveGitDir(wt);
    if (gitDir == null) continue;
    final eviction = readJsonMap('${gitDir.path}/eviction_state.json');
    if (eviction != null) {
      final action = eviction['action'] ?? 'evicted';
      final at = eviction['at'] ?? 'unknown time';
      final reclaimed = eviction['reclaimedHuman'] ?? 'unknown size';
      final wtName = baseName(wt.path);
      warnings.add(
        "Worktree '$wtName' was $action at $at (reclaimed $reclaimed). "
        'Use `engine_build.dart --workspace $wtName -- <cmd>` to rehydrate and enforce the 40G disk floor.',
      );
    }
  }

  if (warnings.isNotEmpty) {
    return <String, dynamic>{'decision': 'deny', 'reason': warnings.join(' ')};
  }
  return const <String, dynamic>{'decision': 'allow'};
}

Map<String, dynamic> _handlePreInvocation(Map<String, dynamic> payload) {
  final rawWorkspaces = payload['workspacePaths'];
  final workspacePaths = <Directory>[
    if (rawWorkspaces is List)
      for (final p in rawWorkspaces.whereType<String>()) Directory(p),
  ];
  final warnings = <String>[];
  for (final ws in workspacePaths) {
    if (!ws.existsSync() || !_isFlutterWorktree(ws)) continue;
    final gitDir = _resolveGitDir(ws);
    if (gitDir == null) continue;
    final eviction = readJsonMap('${gitDir.path}/eviction_state.json');
    if (eviction != null) {
      final action = eviction['action'] ?? 'evicted';
      final at = eviction['at'] ?? 'unknown time';
      final reclaimed = eviction['reclaimedHuman'] ?? 'unknown size';
      final wtName = baseName(ws.path);
      warnings.add(
        "Worktree '$wtName' was $action at $at (reclaimed $reclaimed). "
        'Use `engine_build.dart --workspace $wtName -- <cmd>` to rehydrate before building.',
      );
    }
  }
  if (warnings.isEmpty) return const <String, dynamic>{};
  return <String, dynamic>{
    'injectSteps': <Map<String, dynamic>>[
      <String, dynamic>{
        'systemMessage': <String, dynamic>{
          'systemMessage': warnings.join(' '),
        },
      },
    ],
  };
}
