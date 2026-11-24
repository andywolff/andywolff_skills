import 'dart:convert';
import 'dart:io';

class CleanupItem {
  final String category;
  final String label;
  final String path;
  final int sizeKiB;
  final String humanSize;
  final bool hasActiveSession;
  final List<String> inferredSessions;
  final bool isSnapshot;
  final DateTime? lastModified;

  const CleanupItem({
    required this.category,
    required this.label,
    required this.path,
    required this.sizeKiB,
    required this.humanSize,
    this.hasActiveSession = false,
    this.inferredSessions = const [],
    this.isSnapshot = false,
    this.lastModified,
  });

  bool get isProtectedSession =>
      hasActiveSession || inferredSessions.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'category': category,
    'label': label,
    'path': path,
    'sizeKiB': sizeKiB,
    'humanSize': humanSize,
    'hasActiveSession': hasActiveSession,
    'inferredSessions': inferredSessions,
    'isSnapshot': isSnapshot,
    if (lastModified != null)
      'lastModified': lastModified!.toUtc().toIso8601String(),
  };
}

const _standardBaseTargets = {
  'host_debug',
  'host_debug_arm64',
  'host_debug_unopt',
  'host_debug_unopt_arm64',
  'host_profile',
  'host_profile_arm64',
  'host_release',
  'host_release_arm64',
  'linux_debug',
  'linux_debug_arm64',
  'linux_debug_unopt',
  'linux_debug_unopt_arm64',
  'linux_profile',
  'linux_profile_arm64',
  'linux_release',
  'linux_release_arm64',
  'android_debug',
  'android_debug_arm64',
  'android_debug_unopt',
  'android_debug_unopt_arm64',
  'android_profile',
  'android_profile_arm64',
  'android_release',
  'android_release_arm64',
};

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }

  final jsonMode = args.contains('--json');
  final cleanEngineOut = args.contains('--clean-engine-out');
  final cleanSnapshots = args.contains('--clean-snapshots');
  final cleanFrameworkBuilds = args.contains('--clean-framework-builds');
  final cleanCaches = args.contains('--clean-caches');
  final cleanGradle = args.contains('--clean-gradle');
  final includeActive = args.contains('--include-active');
  final workspaceOption = _getOption(args, '--workspace');
  final workspaceFilters = workspaceOption
      ?.split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
  final parentDirPath =
      _getOption(args, '--parent-dir') ?? await _detectParentDir();

  final items = <CleanupItem>[];

  if (!jsonMode) {
    final dfBefore = await _getDiskSummary(parentDirPath);
    stdout.writeln('=== Disk Status ===');
    stdout.writeln(dfBefore);
    stdout.writeln('');
  }

  // 1. Scan workspaces for engine builds and framework test/example builds.
  final workspaceDirs = await _discoverWorkspaces(parentDirPath);
  final activeState = await _loadActiveSessionState(
    parentDirPath,
    workspaceDirs,
  );
  var inaccessibleWorkspaces = 0;
  for (final ws in workspaceDirs) {
    final wsName = _baseName(ws.path);
    if (workspaceFilters != null &&
        !workspaceFilters.contains(wsName.toLowerCase())) {
      continue;
    }
    if (!_isReadableDir(ws)) {
      inaccessibleWorkspaces++;
      continue;
    }
    final leaseBadge = await _readWorktreeLeaseBadge(ws.path);
    final isReleasedLease = leaseBadge == 'RELEASED';
    final isActive =
        !isReleasedLease &&
        (activeState.directPaths.contains(ws.path) ||
            (leaseBadge != null && leaseBadge.startsWith('LEASE:')));
    final inferredOwners = isReleasedLease
        ? const <String>[]
        : (activeState.inferredOwners[ws.path] ?? const <String>[]);

    // Engine out targets
    final outDir = Directory('${ws.path}/engine/src/out');
    final outChildren = _safeListDirs(outDir);
    for (final target in outChildren) {
      final targetName = _baseName(target.path);
      final size = await _measureDir(target.path);
      if (size.kib > 0) {
        items.add(
          CleanupItem(
            category: 'engine_out',
            label: '$wsName/engine/src/out/$targetName',
            path: target.path,
            sizeKiB: size.kib,
            humanSize: size.human,
            hasActiveSession: isActive,
            inferredSessions: inferredOwners,
            isSnapshot: _isSnapshotDir(target, targetName),
            lastModified: _getLastModified(target),
          ),
        );
      }
    }

    // Framework build directories (dev/integration_tests, dev/benchmarks, examples)
    for (final relGroup in [
      'dev/integration_tests',
      'dev/benchmarks',
      'examples',
    ]) {
      final groupDir = Directory('${ws.path}/$relGroup');
      for (final appDir in _safeListDirs(groupDir)) {
        final buildDir = Directory('${appDir.path}/build');
        if (!_safeExists(buildDir)) continue;
        final size = await _measureDir(buildDir.path);
        // Only report builds >= 10 MiB to keep output high-signal, while cleaning all when requested.
        if (size.kib >= 10240 || cleanFrameworkBuilds) {
          items.add(
            CleanupItem(
              category: 'framework_build',
              label: '$wsName/$relGroup/${_baseName(appDir.path)}/build',
              path: buildDir.path,
              sizeKiB: size.kib,
              humanSize: size.human,
              hasActiveSession: isActive,
              inferredSessions: inferredOwners,
              lastModified: _getLastModified(buildDir),
            ),
          );
        }
      }
    }
  }

  // 2. Scan developer caches (skip if filtering to specific workspaces).
  if (workspaceFilters == null) {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      final xdgCache = Platform.environment['XDG_CACHE_HOME'];
      final linuxCacheHome = (xdgCache != null && xdgCache.isNotEmpty)
          ? xdgCache
          : '$home/.cache';
      final cacheTargets = [
        (
          cat: 'cache',
          label: 'VS Code C++ IntelliSense Cache',
          path: Platform.isMacOS
              ? '$home/Library/Caches/vscode-cpptools'
              : '$linuxCacheHome/vscode-cpptools',
        ),
        if (Platform.isMacOS) ...[
          (
            cat: 'cache',
            label: 'Xcode iOS DeviceSupport Symbols',
            path: '$home/Library/Developer/Xcode/iOS DeviceSupport',
          ),
          (
            cat: 'cache',
            label: 'Xcode DerivedData',
            path: '$home/Library/Developer/Xcode/DerivedData',
          ),
        ],
        (
          cat: 'cache',
          label: 'Dart Analysis Server Cache',
          path: '$home/.dartServer',
        ),
        (cat: 'gradle', label: 'Gradle Caches', path: '$home/.gradle/caches'),
        (
          cat: 'gradle',
          label: 'Gradle Wrapper Distributions',
          path: '$home/.gradle/wrapper',
        ),
        (
          cat: 'info',
          label: 'Android AVD Images (manual review)',
          path: '$home/.android/avd',
        ),
      ];

      for (final target in cacheTargets) {
        final dir = Directory(target.path);
        if (!_safeExists(dir)) continue;
        final size = await _measureDir(dir.path);
        if (size.kib >= 10240) {
          items.add(
            CleanupItem(
              category: target.cat,
              label: target.label,
              path: dir.path,
              sizeKiB: size.kib,
              humanSize: size.human,
            ),
          );
        }
      }
    }
  }

  final anyCleanRequested =
      cleanEngineOut ||
      cleanSnapshots ||
      cleanFrameworkBuilds ||
      cleanCaches ||
      cleanGradle;

  if (jsonMode && !anyCleanRequested) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ')
          .convert(items.map((e) => e.toJson()).toList()),
    );
    return;
  }

  if (!jsonMode && inaccessibleWorkspaces > 0) {
    stdout.writeln(
      'Note: $inaccessibleWorkspaces matching worktree(s) could not be read due to sandbox permissions; re-run outside the sandbox to access them.\n',
    );
  }

  if (!jsonMode && activeState.sessionDetectionUnavailable) {
    stdout.writeln(
      'Note: Active Jetski session detection is unavailable (presence directory not accessible, e.g. inside a sandbox); re-run outside the sandbox to populate session badges.\n',
    );
  }

  if (!anyCleanRequested) {
    _printAuditReport(items);
    return;
  }

  // Execute requested cleanups.
  var removedCount = 0;
  var reclaimedKiB = 0;

  for (final item in items) {
    final shouldDelete = switch (item.category) {
      'engine_out' =>
        (cleanEngineOut || (cleanSnapshots && item.isSnapshot)) &&
            (!item.isProtectedSession || includeActive),
      'framework_build' =>
        cleanFrameworkBuilds && (!item.isProtectedSession || includeActive),
      'cache' => cleanCaches,
      'gradle' => cleanGradle,
      _ => false,
    };

    if (item.isProtectedSession &&
        !includeActive &&
        (cleanEngineOut || cleanSnapshots || cleanFrameworkBuilds)) {
      if ((item.category == 'engine_out' &&
              (cleanEngineOut || (cleanSnapshots && item.isSnapshot))) ||
          (item.category == 'framework_build' && cleanFrameworkBuilds)) {
        final reason = item.hasActiveSession
            ? 'active session'
            : 'inferred active session (${item.inferredSessions.join(', ')})';
        stdout.writeln('⏭️  Skipping $reason workspace target: ${item.label}');
      }
      continue;
    }

    if (!shouldDelete) continue;

    final dir = Directory(item.path);
    if (dir.existsSync()) {
      stdout.writeln('🗑️  Deleting ${item.label} (${item.humanSize})...');
      if (item.category == 'cache') {
        // Delete contents so top-level directory permissions/existence stay intact.
        for (final child in dir.listSync(followLinks: false)) {
          child.deleteSync(recursive: true);
        }
      } else {
        dir.deleteSync(recursive: true);
      }
      removedCount++;
      reclaimedKiB += item.sizeKiB;
    }
  }

  stdout.writeln('');
  stdout.writeln(
    'Cleared $removedCount target(s) (~${_formatKiB(reclaimedKiB)} estimated).',
  );
  stdout.writeln('');
  stdout.writeln('=== Updated Disk Status ===');
  stdout.writeln(await _getDiskSummary(parentDirPath));
}

void _printAuditReport(List<CleanupItem> items) {
  void printSection(String title, List<CleanupItem> sectionItems) {
    if (sectionItems.isEmpty) return;
    final sorted = [...sectionItems]
      ..sort((a, b) => b.sizeKiB.compareTo(a.sizeKiB));
    final totalKiB = sorted.fold<int>(0, (sum, item) => sum + item.sizeKiB);
    stdout.writeln('=== $title (~${_formatKiB(totalKiB)}) ===');
    for (final item in sorted) {
      final age = item.lastModified != null
          ? '(${_formatAge(item.lastModified!)})'
          : '';
      final badges = <String>[
        if (age.isNotEmpty) age,
        if (item.isSnapshot) '[SNAPSHOT]',
        if (item.hasActiveSession) '[ACTIVE SESSION]',
        if (!item.hasActiveSession && item.inferredSessions.isNotEmpty)
          '[INFERRED ACTIVE: ${item.inferredSessions.join('; ')}]',
      ].join(' ');
      final suffix = badges.isEmpty ? '' : ' $badges';
      stdout.writeln('  ${item.humanSize.padLeft(6)}  ${item.label}$suffix');
    }
    stdout.writeln('');
  }

  printSection(
    'Engine Build Targets (engine/src/out)',
    items.where((i) => i.category == 'engine_out').toList(),
  );
  printSection(
    'Framework Integration Test & Example Builds (>= 10 MiB)',
    items.where((i) => i.category == 'framework_build').toList(),
  );
  printSection(
    'Developer & Tool Caches',
    items
        .where((i) => i.category == 'cache' || i.category == 'gradle')
        .toList(),
  );
  printSection(
    'Other Large Directories (Manual Review)',
    items.where((i) => i.category == 'info').toList(),
  );

  final reclaimableKiB = items
      .where((i) => i.category != 'info')
      .fold<int>(0, (sum, item) => sum + item.sizeKiB);
  stdout.writeln('Total Reclaimable Estimate: ~${_formatKiB(reclaimableKiB)}');
}

void _printUsage() {
  stdout.writeln('Usage: dart audit_disk.dart [options]');
  stdout.writeln('');
  stdout.writeln('Audit Options (default is read-only audit):');
  stdout.writeln(
    '  --parent-dir <path>         Parent folder containing Flutter worktrees.',
  );
  stdout.writeln(
    '  --workspace <name>          Scope scan/cleanup to a single workspace directory name.',
  );
  stdout.writeln('  --json                      Output audit items as JSON.');
  stdout.writeln('');
  stdout.writeln('Cleanup Options:');
  stdout.writeln(
    '  --clean-snapshots           Delete engine snapshot variants (*_baseline, *_patched).',
  );
  stdout.writeln(
    '  --clean-engine-out          Delete engine/src/out/* targets in inactive workspaces.',
  );
  stdout.writeln(
    '  --clean-framework-builds    Delete dev/ and examples/ build directories.',
  );
  stdout.writeln(
    '  --clean-caches              Clear vscode-cpptools, Xcode DeviceSupport/DerivedData, .dartServer.',
  );
  stdout.writeln(
    '  --clean-gradle              Clear ~/.gradle/caches and ~/.gradle/wrapper.',
  );
  stdout.writeln(
    '  --include-active            Allow cleaning workspaces that have an active Jetski session.',
  );
}

String? _getOption(List<String> args, String flag) {
  final idx = args.indexOf(flag);
  if (idx != -1 && idx + 1 < args.length) {
    return args[idx + 1];
  }
  return null;
}

String _baseName(String path) =>
    path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;

bool _isSnapshotDir(Directory dir, String name) {
  try {
    if (File('${dir.path}/.snapshot_variant').existsSync()) {
      return true;
    }
  } catch (_) {}
  if (_standardBaseTargets.contains(name)) {
    return false;
  }
  return _standardBaseTargets.any((base) => name.startsWith('${base}_'));
}

bool _safeExists(FileSystemEntity entity) {
  try {
    return entity.existsSync();
  } catch (_) {
    return false;
  }
}

bool _isReadableDir(Directory dir) {
  try {
    if (!dir.existsSync()) return false;
    dir.listSync(followLinks: false);
    return true;
  } catch (_) {
    return false;
  }
}

List<Directory> _safeListDirs(Directory dir) {
  try {
    if (!dir.existsSync()) return const [];
    return dir.listSync(followLinks: false).whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  } catch (_) {
    return const [];
  }
}

Future<List<Directory>> _discoverWorkspaces(String parentDirPath) async {
  final paths = <String>{};

  for (final dir in _safeListDirs(Directory(parentDirPath))) {
    paths.add(dir.path);
  }

  final gitRoots = <String>{
    Directory.current.path,
    '$parentDirPath/flutter',
    File(Platform.script.toFilePath()).parent.path,
  };

  for (final candidate in gitRoots) {
    if (!_safeExists(Directory(candidate))) continue;
    final res = await _runSystemCmd('git', [
      'worktree',
      'list',
    ], workingDirectory: candidate);
    if (res != null && res.exitCode == 0) {
      for (final line in (res.stdout as String).split('\n')) {
        final wtPath = line.trim().split(RegExp(r'\s+')).firstOrNull;
        if (wtPath != null && wtPath.isNotEmpty) {
          paths.add(wtPath);
        }
      }
    }
  }

  final sorted = paths.toList()..sort();
  return [for (final p in sorted) Directory(p)];
}

Future<ProcessResult?> _runSystemCmd(
  String cmd,
  List<String> args, {
  String? workingDirectory,
}) async {
  for (final candidate in [cmd, '/usr/bin/$cmd', '/bin/$cmd']) {
    try {
      return await Process.run(
        candidate,
        args,
        workingDirectory: workingDirectory,
      );
    } on ProcessException {
      continue;
    }
  }
  return null;
}

Future<String> _detectParentDir() async {
  final gitTop = await _runSystemCmd('git', ['rev-parse', '--show-toplevel']);
  if (gitTop != null && gitTop.exitCode == 0) {
    final topPath = (gitTop.stdout as String).trim();
    if (topPath.isNotEmpty) {
      return Directory(topPath).parent.path;
    }
  }
  final resolvedScript = File(Platform.script.toFilePath())
      .resolveSymbolicLinksSync();
  // <parent>/andywolff_skills/.agents/skills/flutter-disk-cleanup/scripts/audit_disk.dart
  return File(resolvedScript).parent.parent.parent.parent.parent.parent.path;
}

Future<
  ({
    Set<String> directPaths,
    Map<String, List<String>> inferredOwners,
    bool sessionDetectionUnavailable,
  })
>
_loadActiveSessionState(
  String parentDirPath,
  List<Directory> workspaceDirs,
) async {
  final home = Platform.environment['HOME'] ?? '';
  final presenceDir = Directory('$home/.gemini/jetski/presence');
  if (home.isEmpty || !_safeExists(presenceDir)) {
    return (
      directPaths: <String>{},
      inferredOwners: <String, List<String>>{},
      sessionDetectionUnavailable: true,
    );
  }

  try {
    final resolvedScript = File(Platform.script.toFilePath())
        .resolveSymbolicLinksSync();
    final skillsRoot = File(resolvedScript).parent.parent.parent.path;
    final activeScript =
        '$skillsRoot/git-worktree-management/scripts/get_active_sessions.dart';
    if (!File(activeScript).existsSync()) {
      return (
        directPaths: <String>{},
        inferredOwners: <String, List<String>>{},
        sessionDetectionUnavailable: false,
      );
    }
    final result = await Process.run(Platform.resolvedExecutable, [
      activeScript,
      '--json',
    ]);
    if (result.exitCode != 0) {
      return (
        directPaths: <String>{},
        inferredOwners: <String, List<String>>{},
        sessionDetectionUnavailable: false,
      );
    }
    final decoded = jsonDecode(result.stdout as String);
    final directPaths = <String>{};
    final inferredMap = <String, Set<String>>{};
    final normalizedParent = parentDirPath.replaceAll(RegExp(r'/+$'), '');

    if (decoded is List) {
      for (final entry in decoded.whereType<Map<String, dynamic>>()) {
        final wsPath = (entry['workspacePath'] as String?)?.replaceAll(
          RegExp(r'/+$'),
          '',
        );
        if (wsPath == null || wsPath.isEmpty) continue;
        directPaths.add(wsPath);

        if (wsPath == normalizedParent) {
          final cid = entry['conversationId'] as String?;
          final title = (entry['title'] as String?)?.trim();
          if (cid == null || cid.isEmpty) continue;
          final label = (title != null && title.isNotEmpty)
              ? title
              : cid.substring(0, cid.length < 8 ? cid.length : 8);
          final transcript = File(
            '$home/.gemini/jetski/brain/$cid/.system_generated/logs/transcript.jsonl',
          );
          if (!_safeExists(transcript)) continue;
          final owned = _inferWorktreesFromTranscript(
            transcript,
            normalizedParent,
            workspaceDirs,
          );
          for (final ownedPath in owned) {
            inferredMap.putIfAbsent(ownedPath, () => <String>{}).add(label);
          }
        }
      }
    } else if (decoded is Map<String, dynamic>) {
      directPaths.addAll(decoded.keys);
    }

    return (
      directPaths: directPaths,
      inferredOwners: {
        for (final e in inferredMap.entries) e.key: (e.value.toList()..sort()),
      },
      sessionDetectionUnavailable: false,
    );
  } catch (_) {
    return (
      directPaths: <String>{},
      inferredOwners: <String, List<String>>{},
      sessionDetectionUnavailable: false,
    );
  }
}

Set<String> _inferWorktreesFromTranscript(
  File transcriptFile,
  String parentDirPath,
  List<Directory> workspaceDirs,
) {
  final candidates = <String, String>{};
  for (final dir in workspaceDirs) {
    final normalized = dir.path.replaceAll(RegExp(r'/+$'), '');
    if (normalized == parentDirPath) continue;
    final name = _baseName(normalized);
    if (name.isEmpty || name == 'andywolff_skills') continue;
    candidates[name] = normalized;
  }
  if (candidates.isEmpty) return const {};

  final hitCounts = <String, int>{};
  final writeHits = <String>{};

  try {
    final lines = transcriptFile.readAsLinesSync();
    for (final line in lines) {
      if (!line.contains('"tool_calls"')) continue;
      dynamic decoded;
      try {
        decoded = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      final toolCalls = decoded['tool_calls'];
      if (toolCalls is! List) continue;

      for (final tc in toolCalls.whereType<Map<String, dynamic>>()) {
        final name = (tc['name'] as String?) ?? '';
        final args = tc['args'];
        if (args is! Map) continue;
        final isWriteTool =
            name == 'edit_file' ||
            name == 'write_file' ||
            name == 'replace_file_content' ||
            name == 'multi_replace_file_content';

        final rawText = args.values.whereType<String>().join(' ');
        if (rawText.isEmpty) continue;
        // Strip SDK binary invocations so calling flutter/bin/dart does not claim the flutter worktree.
        final sanitized = rawText
            .replaceAll('$parentDirPath/flutter/bin/dart', '')
            .replaceAll('$parentDirPath/flutter/bin/flutter', '')
            .replaceAll('flutter/bin/dart', '')
            .replaceAll('flutter/bin/flutter', '');

        for (final entry in candidates.entries) {
          final wsName = entry.key;
          final wsPath = entry.value;
          final absPrefix = '$parentDirPath/$wsName';
          final matched =
              sanitized.contains('$absPrefix/') ||
              sanitized.contains('$absPrefix"') ||
              sanitized.contains("$absPrefix'") ||
              sanitized.contains('$absPrefix ') ||
              RegExp(
                '(?:^|[\\s"\'=\\(])${RegExp.escape(wsName)}/',
              ).hasMatch(sanitized);
          if (matched) {
            hitCounts[wsPath] = (hitCounts[wsPath] ?? 0) + 1;
            if (isWriteTool) {
              writeHits.add(wsPath);
            }
          }
        }
      }
    }
  } catch (_) {
    return const {};
  }

  return {
    for (final entry in hitCounts.entries)
      if (entry.value >= 2 || writeHits.contains(entry.key)) entry.key,
  };
}

DateTime? _getLastModified(Directory dir) {
  DateTime? newest;
  void consider(FileSystemEntity entity) {
    try {
      final mod = entity.statSync().modified;
      if (newest == null || mod.isAfter(newest!)) {
        newest = mod;
      }
    } catch (_) {}
  }

  consider(dir);
  for (final marker in ['.ninja_log', 'build.ninja', 'args.gn']) {
    final f = File('${dir.path}/$marker');
    if (_safeExists(f)) consider(f);
  }
  return newest;
}

String _formatAge(DateTime modified) {
  final diff = DateTime.now().difference(modified);
  if (diff.isNegative || diff.inMinutes < 60) {
    final mins = diff.inMinutes < 1 ? 1 : diff.inMinutes;
    return '${mins}m ago';
  }
  if (diff.inHours < 48) {
    return '${diff.inHours}h ago';
  }
  return '${diff.inDays}d ago';
}

Future<String?> _readWorktreeLeaseBadge(String worktreePath) async {
  final gitRes = await _runSystemCmd('git', [
    '-C',
    worktreePath,
    'rev-parse',
    '--absolute-git-dir',
  ]);
  if (gitRes == null || gitRes.exitCode != 0) return null;
  final gitDir = (gitRes.stdout as String).trim();
  if (gitDir.isEmpty) return null;
  final leaseFile = File('$gitDir/agent_session.json');
  if (!_safeExists(leaseFile)) return null;
  try {
    final decoded = jsonDecode(leaseFile.readAsStringSync());
    if (decoded is! Map<String, dynamic>) return null;
    final state = (decoded['state'] as String?) ?? 'unknown';
    if (state == 'released') return 'RELEASED';
    final rawHb = decoded['lastHeartbeat'] as String?;
    final hb = rawHb != null ? DateTime.tryParse(rawHb) : null;
    final buildPid = decoded['buildPid'];
    final hasLivePid =
        buildPid is int &&
        buildPid > 0 &&
        (Platform.isLinux
            ? Directory('/proc/$buildPid').existsSync()
            : Process.runSync('kill', ['-0', '$buildPid']).exitCode == 0);
    if (hasLivePid) return 'LEASE:busy';
    if (hb != null && DateTime.now().difference(hb).inMinutes < 60) {
      return 'LEASE:$state';
    }
  } catch (_) {}
  return null;
}

Future<({int kib, String human})> _measureDir(String path) async {
  final kibRes = await _runSystemCmd('du', ['-sk', path]);
  if (kibRes == null || kibRes.exitCode != 0) {
    return (kib: 0, human: '0B');
  }
  final raw = (kibRes.stdout as String).trim();
  if (raw.isEmpty) {
    return (kib: 0, human: '0B');
  }
  final kib = int.tryParse(raw.split(RegExp(r'\s+')).first) ?? 0;
  return (kib: kib, human: _formatKiB(kib));
}

String _formatKiB(int kib) {
  if (kib <= 0) return '0B';
  const mib = 1024;
  const gib = 1024 * 1024;
  if (kib >= gib) {
    return '${(kib / gib).toStringAsFixed(1)}G';
  }
  if (kib >= mib) {
    return '${(kib / mib).round()}M';
  }
  return '${kib}K';
}

Future<String> _getDiskSummary([String? targetPath]) async {
  final home = Platform.environment['HOME'];
  final target =
      Platform.isMacOS && _safeExists(Directory('/System/Volumes/Data'))
      ? '/System/Volumes/Data'
      : (targetPath != null && _safeExists(Directory(targetPath)))
      ? targetPath
      : (home != null && home.isNotEmpty && _safeExists(Directory(home)))
      ? home
      : '/';
  final res = await _runSystemCmd('df', ['-h', target]);
  if (res == null) return 'Unable to query disk summary.';
  return (res.stdout as String).trim();
}
