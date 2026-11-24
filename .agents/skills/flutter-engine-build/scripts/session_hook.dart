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
    'pre' => _handlePreToolUse(payload, sessionId),
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

String? _extractToolName(Map<String, dynamic> payload) {
  final toolCall = payload['toolCall'];
  if (toolCall is Map && toolCall['name'] is String) {
    return toolCall['name'] as String;
  }
  return payload['toolName'] as String?;
}

String? _extractCommandLine(Map<String, dynamic> payload) {
  final input = _extractToolInput(payload);
  if (input is Map) {
    final cmd = input['CommandLine'] ?? input['command'] ?? input['cmd'];
    if (cmd is String) return cmd;
  }
  return null;
}

bool _isPidAlive(int pidToCheck) {
  if (pidToCheck <= 0) return false;
  if (Platform.isLinux) {
    return Directory('/proc/$pidToCheck').existsSync();
  }
  final res = Process.runSync('kill', <String>['-0', '$pidToCheck']);
  return res.exitCode == 0;
}

/// Returns the active [LeaseInfo] if [gitDir] is currently leased by a
/// different session (live build PID or heartbeat within [idleMinutes] and not
/// released). Returns `null` if unowned, owned by [sessionId], released, or
/// expired.
LeaseInfo? _foreignActiveLease(
  Directory gitDir,
  String sessionId, {
  int idleMinutes = 60,
}) {
  final existing = readJsonMap('${gitDir.path}/agent_session.json');
  if (existing == null) return null;
  final lease = LeaseInfo.fromJson(existing);
  final owner = lease.sessionId;
  if (owner == null || owner.isEmpty || owner == sessionId) return null;
  if (lease.state == 'released') return null;

  final hasLivePid = lease.buildPid != null && _isPidAlive(lease.buildPid!);
  final withinIdleWindow =
      lease.lastHeartbeat != null &&
      DateTime.now().difference(lease.lastHeartbeat!).inMinutes < idleMinutes;
  if (hasLivePid || withinIdleWindow) {
    return lease;
  }
  return null;
}

bool _isReadOnlyCommand(String cmd) {
  final trimmed = cmd.trim();
  if (trimmed.isEmpty) return true;
  if (RegExp(
    r'(--release|--dehydrate|--force|--clean-|--include-active|\b(rm|mv|cp|mkdir|touch|ninja|et|gclient|gn)\b|>>?|\bgit\b[^;&|]*\b(worktree\s+(add|remove)|checkout|commit|reset|apply|rebase|merge|cherry-pick|stash|clean|pull|push)\b)',
  ).hasMatch(trimmed)) {
    return false;
  }
  return RegExp(
    r'(engine_build\.dart[^\n]*--status|audit_disk\.dart|check_worktrees\.dart|get_active_sessions\.dart|^(ls|du|df|cat|head|tail|stat|wc|file|pwd|echo)\b|\bgit\b[^;&|]*\b(status|log|branch|worktree\s+list|diff|show|rev-parse)\b)',
  ).hasMatch(trimmed);
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
        final escapedName = RegExp.escape(name);
        final matched =
            toolBlob.contains('$childStr/') ||
            toolBlob.contains('$childStr"') ||
            toolBlob.contains('$childStr ') ||
            RegExp('(?:^|[\\s"\'=(])$escapedName/').hasMatch(toolBlob) ||
            RegExp(
              '--workspace[=\\s]+["\']?$escapedName(?:["\'\\s\\\\]|\\\$)',
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
  final toolName = _extractToolName(payload);
  final cmd = _extractCommandLine(payload);
  if (toolName == 'run_command' && cmd != null && _isReadOnlyCommand(cmd)) {
    return const <String, dynamic>{};
  }

  for (final wt in _findCandidateWorktrees(payload)) {
    final gitDir = _resolveGitDir(wt);
    if (gitDir == null) continue;
    // Never steal an active lease owned by another session.
    if (_foreignActiveLease(gitDir, sessionId) != null) continue;
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

Map<String, dynamic> _handlePreToolUse(
  Map<String, dynamic> payload,
  String sessionId,
) {
  final toolBlob = jsonEncode(_extractToolInput(payload));
  final cmd = _extractCommandLine(payload) ?? toolBlob;

  // 1. Block lease release, dehydration, or destructive cleanup of worktrees
  // actively leased by another session.
  final isLeaseMutation =
      (cmd.contains('engine_build.dart') &&
          RegExp(r'(--release|--dehydrate|--force)\b').hasMatch(cmd)) ||
      (cmd.contains('audit_disk.dart') &&
          RegExp(r'(--clean-|--include-active)\b').hasMatch(cmd)) ||
      (RegExp(r'\brm\b').hasMatch(cmd) &&
          RegExp(
            r'(engine/src/out|\.gclient_entries|\.cipd|agent_session\.json)',
          ).hasMatch(cmd)) ||
      RegExp(r'\bgit\b[^\n]*\bworktree\s+remove\b').hasMatch(cmd);

  if (isLeaseMutation) {
    final targets = _findCandidateWorktrees(payload);
    // If `--include-active` is passed to audit_disk.dart without scoping to a
    // single workspace, check every sibling worktree under workspacePaths.
    if (targets.isEmpty && cmd.contains('--include-active')) {
      final rawWorkspaces = payload['workspacePaths'];
      if (rawWorkspaces is List) {
        for (final p in rawWorkspaces.whereType<String>()) {
          final ws = Directory(p);
          if (!ws.existsSync()) continue;
          try {
            for (final entity in ws.listSync(followLinks: false)) {
              if (entity is Directory && _isFlutterWorktree(entity)) {
                targets.add(entity);
              }
            }
          } catch (_) {}
        }
      }
    }

    final denials = <String>[];
    for (final wt in targets) {
      final gitDir = _resolveGitDir(wt);
      if (gitDir == null) continue;
      final foreign = _foreignActiveLease(gitDir, sessionId);
      if (foreign != null) {
        final wtName = baseName(wt.path);
        denials.add(
          "Worktree '$wtName' is actively leased by session ${foreign.sessionId} (state=${foreign.state}). "
          'You may not release, dehydrate, or clean a workspace owned by another session.',
        );
      }
    }
    if (denials.isNotEmpty) {
      return <String, dynamic>{'decision': 'deny', 'reason': denials.join(' ')};
    }
  }

  // 2. Block raw ninja / et build / gn gen on dehydrated or evicted worktrees
  // unless already wrapped by engine_build.dart.
  if (toolBlob.contains('engine_build.dart') ||
      !RegExp(r'\b(ninja|et\s+build|gn\s+gen)\b').hasMatch(toolBlob)) {
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
