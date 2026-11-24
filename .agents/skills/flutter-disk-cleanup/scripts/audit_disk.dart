import 'dart:convert';
import 'dart:io';

class CleanupItem {
  final String category;
  final String label;
  final String path;
  final int sizeKiB;
  final String humanSize;
  final bool hasActiveSession;
  final bool isSnapshot;

  const CleanupItem({
    required this.category,
    required this.label,
    required this.path,
    required this.sizeKiB,
    required this.humanSize,
    this.hasActiveSession = false,
    this.isSnapshot = false,
  });

  Map<String, dynamic> toJson() => {
    'category': category,
    'label': label,
    'path': path,
    'sizeKiB': sizeKiB,
    'humanSize': humanSize,
    'hasActiveSession': hasActiveSession,
    'isSnapshot': isSnapshot,
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

  final activeWorkspaces = await _loadActiveWorkspacePaths();
  final items = <CleanupItem>[];

  if (!jsonMode) {
    final dfBefore = await _getDiskSummary();
    stdout.writeln('=== Disk Status ===');
    stdout.writeln(dfBefore);
    stdout.writeln('');
  }

  // 1. Scan workspaces for engine builds and framework test/example builds.
  final workspaceDirs = await _discoverWorkspaces(parentDirPath);
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
    final isActive = activeWorkspaces.contains(ws.path);

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
            isSnapshot: _isSnapshotDir(target, targetName),
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
      final cacheTargets = [
        (
          cat: 'cache',
          label: 'VS Code C++ IntelliSense Cache',
          path: '$home/Library/Caches/vscode-cpptools',
        ),
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
            (!item.hasActiveSession || includeActive),
      'framework_build' =>
        cleanFrameworkBuilds && (!item.hasActiveSession || includeActive),
      'cache' => cleanCaches,
      'gradle' => cleanGradle,
      _ => false,
    };

    if (item.hasActiveSession &&
        !includeActive &&
        (cleanEngineOut || cleanSnapshots || cleanFrameworkBuilds)) {
      if ((item.category == 'engine_out' &&
              (cleanEngineOut || (cleanSnapshots && item.isSnapshot))) ||
          (item.category == 'framework_build' && cleanFrameworkBuilds)) {
        stdout.writeln(
          '⏭️  Skipping active session workspace target: ${item.label}',
        );
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
  stdout.writeln(await _getDiskSummary());
}

void _printAuditReport(List<CleanupItem> items) {
  void printSection(String title, List<CleanupItem> sectionItems) {
    if (sectionItems.isEmpty) return;
    final sorted = [...sectionItems]
      ..sort((a, b) => b.sizeKiB.compareTo(a.sizeKiB));
    final totalKiB = sorted.fold<int>(0, (sum, item) => sum + item.sizeKiB);
    stdout.writeln('=== $title (~${_formatKiB(totalKiB)}) ===');
    for (final item in sorted) {
      final badges = <String>[
        if (item.isSnapshot) '[SNAPSHOT]',
        if (item.hasActiveSession) '[ACTIVE SESSION]',
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
  return File(resolvedScript).parent.parent.parent.parent.parent.path;
}

Future<Set<String>> _loadActiveWorkspacePaths() async {
  try {
    final resolvedScript = File(Platform.script.toFilePath())
        .resolveSymbolicLinksSync();
    final skillsRoot = File(resolvedScript).parent.parent.parent.path;
    final activeScript =
        '$skillsRoot/git-worktree-management/scripts/get_active_sessions.dart';
    if (!File(activeScript).existsSync()) {
      return {};
    }
    final result = await Process.run(Platform.resolvedExecutable, [
      activeScript,
      '--json',
    ]);
    if (result.exitCode != 0) {
      return {};
    }
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return decoded.keys.toSet();
  } catch (_) {
    return {};
  }
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

Future<String> _getDiskSummary() async {
  final target =
      Platform.isMacOS && _safeExists(Directory('/System/Volumes/Data'))
      ? '/System/Volumes/Data'
      : '/';
  final res = await _runSystemCmd('df', ['-h', target]);
  if (res == null) return 'Unable to query disk summary.';
  return (res.stdout as String).trim();
}
