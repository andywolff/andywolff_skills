import 'dart:convert';
import 'dart:io';

import 'lib/workspace_utils.dart';

/// Centralized Flutter engine build wrapper and disk-space admission gate.
///
/// Enforces a minimum free disk floor (default 40 GB) via two-tier LRU
/// eviction (engine/src/out targets first, then in-place gclient dehydration)
/// while protecting hard-active workspaces (live build PID or heartbeat within
/// the idle window, default 60 minutes).
const _defaultMinFreeGiB = 40;
const _defaultBuildHeadroomGiB = 10;
const _defaultRehydrateHeadroomGiB = 25;
const _defaultIdleMinutes = 60;

class WorktreeState {
  final String name;
  final String path;
  final String? gitDir;
  final LeaseInfo lease;
  final LivenessClass liveness;
  final bool isHydrated;
  final bool hasLiveBuildPid;
  final List<({String name, String path, int sizeKiB, bool isSnapshot})>
  outTargets;
  final DateTime lastUsed;
  final Map<String, dynamic>? evictionState;

  const WorktreeState({
    required this.name,
    required this.path,
    required this.gitDir,
    required this.lease,
    required this.liveness,
    required this.isHydrated,
    required this.hasLiveBuildPid,
    required this.outTargets,
    required this.lastUsed,
    required this.evictionState,
  });

  int get totalOutKiB => outTargets.fold<int>(0, (sum, t) => sum + t.sizeKiB);
}

Future<void> main(List<String> args) async {
  final sepIndex = args.indexOf('--');
  final wrapperArgs = sepIndex == -1 ? args : args.sublist(0, sepIndex);
  final commandArgs = sepIndex == -1 ? <String>[] : args.sublist(sepIndex + 1);

  if (wrapperArgs.contains('--help') ||
      wrapperArgs.contains('-h') ||
      (wrapperArgs.isEmpty && commandArgs.isEmpty)) {
    _printUsage();
    exit(0);
  }

  final statusMode = wrapperArgs.contains('--status');
  final jsonMode = wrapperArgs.contains('--json');
  final releaseMode = wrapperArgs.contains('--release');
  final dehydrateMode = wrapperArgs.contains('--dehydrate');
  final dryRun = wrapperArgs.contains('--dry-run');
  final noRehydrate = wrapperArgs.contains('--no-rehydrate');
  final waitMode = wrapperArgs.contains('--wait');
  final requestHandoff = wrapperArgs.contains('--request-handoff');
  final notifyWaiters = wrapperArgs.contains('--notify-waiters');

  final minFreeGiB =
      int.tryParse(_getOption(wrapperArgs, '--min-free-gb') ?? '') ??
      _defaultMinFreeGiB;
  final idleMinutes =
      int.tryParse(_getOption(wrapperArgs, '--idle-minutes') ?? '') ??
      _defaultIdleMinutes;
  final waitTimeoutMin =
      int.tryParse(_getOption(wrapperArgs, '--wait-timeout-min') ?? '') ?? 30;
  final conversationId =
      _getOption(wrapperArgs, '--session-id') ??
      _getOption(wrapperArgs, '--conversation-id') ??
      Platform.environment['AGENT_SESSION_ID'];
  final notifyCmd =
      _getOption(wrapperArgs, '--notify-cmd') ??
      Platform.environment['AGENT_NOTIFY_CMD'];

  final workspaceArg = _getOption(wrapperArgs, '--workspace');
  final parentDirPath =
      _getOption(wrapperArgs, '--parent-dir') ??
      await _detectParentDir(workspaceArg);
  final currentWorktreePath = await _resolveTargetWorktree(
    workspaceArg,
    parentDirPath,
  );

  if (statusMode) {
    await _runStatus(parentDirPath, minFreeGiB, idleMinutes, jsonMode: jsonMode);
    return;
  }

  if (releaseMode) {
    if (currentWorktreePath == null) {
      stderr.writeln(
        'Error: Could not resolve target worktree. Pass --workspace <name-or-path>.',
      );
      exit(1);
    }
    await _releaseLease(
      currentWorktreePath,
      parentDirPath,
      conversationId: conversationId,
      notifyWaiters: notifyWaiters,
      notifyCmd: notifyCmd,
    );
    return;
  }

  if (dehydrateMode) {
    if (currentWorktreePath == null) {
      stderr.writeln(
        'Error: Could not resolve target worktree. Pass --workspace <name-or-path>.',
      );
      exit(1);
    }
    final reclaimedKiB = await _dehydrateWorktree(
      currentWorktreePath,
      byConversation: conversationId ?? 'manual',
      reason: 'manual_dehydrate',
      dryRun: dryRun,
    );
    stdout.writeln(
      '${dryRun ? "[DRY RUN] Would dehydrate" : "Dehydrated"} ${baseName(currentWorktreePath)} (~${formatKiB(reclaimedKiB)} estimated).',
    );
    return;
  }

  if (commandArgs.isEmpty) {
    stderr.writeln(
      'Error: No build command provided. Use `-- <command...>` or pass --status / --release / --dehydrate.',
    );
    _printUsage();
    exit(1);
  }

  if (currentWorktreePath == null) {
    stderr.writeln(
      'Error: Could not resolve target Flutter worktree. Run inside a worktree or pass --workspace <name-or-path>.',
    );
    exit(1);
  }

  final gitDir = await _resolveGitDir(currentWorktreePath);
  final branch = await _resolveBranch(currentWorktreePath);
  final isSyncCommand =
      commandArgs.first == 'gclient' &&
      commandArgs.length > 1 &&
      commandArgs[1] == 'sync';

  // 1. Check eviction tombstone and hydration status before running.
  final evictionState = gitDir != null ? readJsonMap('$gitDir/eviction_state.json') : null;
  final hydrated = _isWorktreeHydrated(currentWorktreePath);
  final needsRehydrate = !hydrated && !isSyncCommand;

  if (evictionState != null) {
    final action = evictionState['action'] ?? 'evicted';
    final at = evictionState['at'] ?? 'unknown time';
    final by = evictionState['byConversation'] ?? 'another session';
    final reclaimed = evictionState['reclaimedHuman'] ?? 'unknown size';
    stdout.writeln(
      'Notice: ${baseName(currentWorktreePath)} was $action at $at by $by (reclaimed $reclaimed).',
    );
  }

  if (needsRehydrate && noRehydrate) {
    stderr.writeln(
      'Error: ${baseName(currentWorktreePath)} is currently dehydrated and --no-rehydrate was specified.',
    );
    stderr.writeln('Run `gclient sync -D` (or omit --no-rehydrate) to rehydrate.');
    exit(3);
  }

  final headroomGiB =
      int.tryParse(_getOption(wrapperArgs, '--headroom-gb') ?? '') ??
      ((needsRehydrate || isSyncCommand)
          ? _defaultRehydrateHeadroomGiB
          : _defaultBuildHeadroomGiB);

  // 2. Run the 40 GB pre-build admission gate (with optional wait/handoff loop).
  final admitted = await _ensureDiskSpaceOrWait(
    parentDirPath: parentDirPath,
    currentWorktreePath: currentWorktreePath,
    minFreeGiB: minFreeGiB,
    headroomGiB: headroomGiB,
    idleMinutes: idleMinutes,
    conversationId: conversationId,
    notifyCmd: notifyCmd,
    dryRun: dryRun,
    waitMode: waitMode,
    waitTimeoutMin: waitTimeoutMin,
    requestHandoff: requestHandoff,
  );
  if (!admitted) {
    exit(2);
  }

  if (dryRun) {
    stdout.writeln(
      '[DRY RUN] Admission gate passed. Would run: ${commandArgs.join(' ')}',
    );
    return;
  }

  // 3. Stamp busy lease before starting sync/build.
  if (gitDir != null) {
    _writeLease(
      gitDir,
      LeaseInfo(
        sessionId: conversationId,
        branch: branch,
        state: 'busy',
        lastHeartbeat: DateTime.now().toUtc(),
        buildPid: pid,
      ),
    );
  }

  int exitCode = 0;
  try {
    // Auto-rehydrate if dehydrated.
    if (needsRehydrate) {
      stdout.writeln(
        'Rehydrating ${baseName(currentWorktreePath)} via `gclient sync -D`...',
      );
      final syncExit = await _streamCommand(
        'gclient',
        <String>['sync', '-D'],
        workingDirectory: currentWorktreePath,
      );
      if (syncExit != 0) {
        stderr.writeln('gclient sync -D failed with exit code $syncExit.');
        exitCode = syncExit;
        return;
      }
      if (gitDir != null) {
        _deleteFileIfExists('$gitDir/eviction_state.json');
      }
    }

    // Run the wrapped build command.
    exitCode = await _streamCommand(
      commandArgs.first,
      commandArgs.sublist(1),
      workingDirectory: currentWorktreePath,
    );

    if (exitCode == 0 && isSyncCommand && gitDir != null) {
      _deleteFileIfExists('$gitDir/eviction_state.json');
    }
  } finally {
    if (gitDir != null) {
      _writeLease(
        gitDir,
        LeaseInfo(
          sessionId: conversationId,
          branch: branch,
          state: 'idle',
          lastHeartbeat: DateTime.now().toUtc(),
          buildPid: null,
        ),
      );
    }
    if (conversationId != null && conversationId.isNotEmpty) {
      _removeWaiter(parentDirPath, conversationId);
    }
  }

  exit(exitCode);
}

Future<bool> _ensureDiskSpaceOrWait({
  required String parentDirPath,
  required String currentWorktreePath,
  required int minFreeGiB,
  required int headroomGiB,
  required int idleMinutes,
  required String? conversationId,
  required String? notifyCmd,
  required bool dryRun,
  required bool waitMode,
  required int waitTimeoutMin,
  required bool requestHandoff,
}) async {
  final targetFreeGiB = minFreeGiB + headroomGiB;
  final deadline = DateTime.now().add(Duration(minutes: waitTimeoutMin));
  final handoffSentTo = <String>{};

  while (true) {
    final freeBeforeGiB = await _getFreeGiB(parentDirPath);
    if (freeBeforeGiB >= targetFreeGiB) {
      stdout.writeln(
        'Disk admission OK: ${freeBeforeGiB.toStringAsFixed(1)}G free (floor ${minFreeGiB}G + headroom ${headroomGiB}G = ${targetFreeGiB}G).',
      );
      return true;
    }

    stdout.writeln(
      'Disk free space is ${freeBeforeGiB.toStringAsFixed(1)}G (need ${targetFreeGiB}G = ${minFreeGiB}G floor + ${headroomGiB}G headroom). Evaluating LRU evictions...',
    );

    final worktrees = await _scanWorktrees(parentDirPath, idleMinutes);
    final others = worktrees
        .where((w) => w.path != currentWorktreePath)
        .toList();

    var currentFreeGiB = freeBeforeGiB;

    // Tier 1a: Engine snapshots in released / inactive / soft-active worktrees.
    currentFreeGiB = await _evictOutTargets(
      others.where((w) => w.liveness != LivenessClass.hardActive).toList(),
      snapshotsOnly: true,
      currentFreeGiB: currentFreeGiB,
      targetFreeGiB: targetFreeGiB,
      byConversation: conversationId ?? 'engine_build',
      dryRun: dryRun,
    );

    // Tier 1b: All engine/src/out targets in released / inactive worktrees.
    if (currentFreeGiB < targetFreeGiB) {
      currentFreeGiB = await _evictOutTargets(
        others
            .where(
              (w) =>
                  w.liveness == LivenessClass.released ||
                  w.liveness == LivenessClass.inactive,
            )
            .toList(),
        snapshotsOnly: false,
        currentFreeGiB: currentFreeGiB,
        targetFreeGiB: targetFreeGiB,
        byConversation: conversationId ?? 'engine_build',
        dryRun: dryRun,
      );
    }

    // Tier 2: In-place dehydration of released / inactive hydrated worktrees.
    if (currentFreeGiB < targetFreeGiB) {
      final dehydrateCandidates = others
          .where(
            (w) =>
                w.isHydrated &&
                (w.liveness == LivenessClass.released ||
                    w.liveness == LivenessClass.inactive),
          )
          .toList()
        ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));

      for (final candidate in dehydrateCandidates) {
        if (currentFreeGiB >= targetFreeGiB) break;
        final reclaimedKiB = await _dehydrateWorktree(
          candidate.path,
          byConversation: conversationId ?? 'engine_build',
          reason: 'disk_floor_${minFreeGiB}gb',
          dryRun: dryRun,
        );
        final reclaimedGiB = reclaimedKiB / (1024 * 1024);
        stdout.writeln(
          '${dryRun ? "[DRY RUN] Would dehydrate" : "Dehydrated"} ${candidate.name} (~${reclaimedGiB.toStringAsFixed(1)}G).',
        );
        currentFreeGiB = dryRun
            ? currentFreeGiB + reclaimedGiB
            : await _getFreeGiB(parentDirPath);
      }
    }

    // Tier 3: engine/src/out targets in soft-active (idle > idleMinutes) worktrees.
    if (currentFreeGiB < targetFreeGiB) {
      currentFreeGiB = await _evictOutTargets(
        others.where((w) => w.liveness == LivenessClass.softActive).toList(),
        snapshotsOnly: false,
        currentFreeGiB: currentFreeGiB,
        targetFreeGiB: targetFreeGiB,
        byConversation: conversationId ?? 'engine_build',
        dryRun: dryRun,
      );
    }

    if (currentFreeGiB >= targetFreeGiB) {
      stdout.writeln(
        'Disk admission OK after eviction: ${currentFreeGiB.toStringAsFixed(1)}G free.',
      );
      return true;
    }

    // Still short of target: only Hard Active (or soft-active hydrated) workspaces remain.
    final blockers = others
        .where(
          (w) =>
              w.liveness == LivenessClass.hardActive &&
              (w.isHydrated || w.totalOutKiB > 0),
        )
        .toList()
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));

    if (!dryRun && conversationId != null && conversationId.isNotEmpty) {
      _registerWaiter(
        parentDirPath,
        conversationId: conversationId,
        worktree: baseName(currentWorktreePath),
        neededGiB: (targetFreeGiB - currentFreeGiB).ceil(),
      );
    }

    if (requestHandoff && !dryRun) {
      for (final b in blockers) {
        final ownerCid = b.lease.sessionId;
        if (ownerCid == null ||
            ownerCid.isEmpty ||
            ownerCid == conversationId ||
            handoffSentTo.contains(ownerCid)) {
          continue;
        }
        await _sendHandoffRequest(
          targetConversationId: ownerCid,
          requesterConversationId: conversationId,
          requesterWorktree: baseName(currentWorktreePath),
          blockerWorktree: b.name,
          neededGiB: (targetFreeGiB - currentFreeGiB).ceil(),
          notifyCmd: notifyCmd,
        );
        handoffSentTo.add(ownerCid);
      }
    }

    if (!waitMode || dryRun || DateTime.now().isAfter(deadline)) {
      stderr.writeln('');
      stderr.writeln(
        'Build blocked: ${currentFreeGiB.toStringAsFixed(1)}G free, need ${targetFreeGiB}G (${minFreeGiB}G floor + ${headroomGiB}G headroom).',
      );
      if (blockers.isNotEmpty) {
        stderr.writeln(
          'Remaining hydrated/built workspaces are Hard Active (< ${idleMinutes}m idle or live build):',
        );
        for (final b in blockers) {
          final cid = b.lease.sessionId ?? 'unknown';
          final age = formatAge(b.lastUsed);
          stderr.writeln(
            '  - ${b.name} (state=${b.lease.state}, lastUsed=$age, out=${formatKiB(b.totalOutKiB)}, session=$cid)',
          );
        }
        stderr.writeln('');
        stderr.writeln(
          'Options: re-run with --wait (and --request-handoff with AGENT_NOTIFY_CMD configured), or release a workspace with `engine_build.dart --release --workspace <name>`.',
        );
      }
      return false;
    }

    stdout.writeln(
      'Waiting for space (${currentFreeGiB.toStringAsFixed(1)}G / ${targetFreeGiB}G free; ${blockers.length} hard-active blocker(s))... sleeping 15s.',
    );
    await Future<void>.delayed(const Duration(seconds: 15));
  }
}

Future<double> _evictOutTargets(
  List<WorktreeState> candidates, {
  required bool snapshotsOnly,
  required double currentFreeGiB,
  required int targetFreeGiB,
  required String byConversation,
  required bool dryRun,
}) async {
  var freeGiB = currentFreeGiB;
  final sorted = [...candidates]
    ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));

  for (final ws in sorted) {
    if (freeGiB >= targetFreeGiB) break;
    final targets = ws.outTargets
        .where((t) => !snapshotsOnly || t.isSnapshot)
        .toList()
      ..sort((a, b) => b.sizeKiB.compareTo(a.sizeKiB));

    for (final t in targets) {
      if (freeGiB >= targetFreeGiB) break;
      final giB = t.sizeKiB / (1024 * 1024);
      stdout.writeln(
        '${dryRun ? "[DRY RUN] Would delete" : "Deleting"} ${ws.name}/engine/src/out/${t.name} (${formatKiB(t.sizeKiB)})...',
      );
      if (!dryRun) {
        final dir = Directory(t.path);
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
        if (ws.gitDir != null) {
          _writeEvictionState(
            ws.gitDir!,
            action: 'evicted_out',
            byConversation: byConversation,
            previousOwner: ws.lease.sessionId,
            previousBranch: ws.lease.branch,
            reclaimedKiB: t.sizeKiB,
            detail: 'engine/src/out/${t.name}',
          );
        }
        freeGiB = await _getFreeGiB(ws.path);
      } else {
        freeGiB += giB;
      }
    }
  }
  return freeGiB;
}

Future<int> _dehydrateWorktree(
  String worktreePath, {
  required String byConversation,
  required String reason,
  required bool dryRun,
}) async {
  final gitDir = await _resolveGitDir(worktreePath);
  final lease = gitDir != null ? _readLease(gitDir) : const LeaseInfo();
  final entriesFile = File('$worktreePath/.gclient_entries');
  final paths = <String>{
    'engine/src/out',
    '.cipd',
    'engine/src/build/linux/debian_bullseye_amd64-sysroot',
    'engine/src/build/linux/debian_bullseye_arm64-sysroot',
    'engine/src/flutter/buildtools/linux-x64',
    'engine/src/flutter/prebuilts/linux-x64',
    'engine/src/flutter/prebuilts/linux-arm64',
  };

  if (safeExists(entriesFile)) {
    paths.addAll(parseGclientEntries(entriesFile.readAsStringSync()));
  }

  var totalReclaimedKiB = 0;
  final sortedPaths = paths.toList()..sort();
  final deletedPrefixes = <String>[];

  for (final rel in sortedPaths) {
    if (deletedPrefixes.any((p) => rel.startsWith('$p/'))) {
      continue;
    }
    final full = '$worktreePath/$rel';
    final type = FileSystemEntity.typeSync(full, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;

    // Never delete any path containing tracked Git files.
    final lsRes = await _runSystemCmd('git', [
      '-C',
      worktreePath,
      'ls-files',
      '--',
      rel,
    ]);
    if (lsRes == null || (lsRes.stdout as String).trim().isNotEmpty) {
      continue;
    }

    final sizeKiB = await _measureDirKiB(full);
    totalReclaimedKiB += sizeKiB;
    deletedPrefixes.add(rel);

    if (!dryRun) {
      if (type == FileSystemEntityType.directory) {
        Directory(full).deleteSync(recursive: true);
      } else {
        File(full).deleteSync();
      }
    }
  }

  if (!dryRun) {
    if (safeExists(entriesFile)) {
      entriesFile.deleteSync();
    }
    if (gitDir != null) {
      _writeEvictionState(
        gitDir,
        action: 'dehydrated',
        byConversation: byConversation,
        previousOwner: lease.sessionId,
        previousBranch: lease.branch,
        reclaimedKiB: totalReclaimedKiB,
        detail: reason,
      );
    }
  }

  return totalReclaimedKiB;
}

Future<void> _releaseLease(
  String worktreePath,
  String parentDirPath, {
  required String? conversationId,
  required bool notifyWaiters,
  required String? notifyCmd,
}) async {
  final gitDir = await _resolveGitDir(worktreePath);
  if (gitDir == null) {
    stderr.writeln('Error: $worktreePath is not a Git worktree.');
    exit(1);
  }
  final existing = _readLease(gitDir);
  final branch = existing.branch ?? await _resolveBranch(worktreePath);
  _writeLease(
    gitDir,
    LeaseInfo(
      sessionId: conversationId ?? existing.sessionId,
      branch: branch,
      state: 'released',
      lastHeartbeat: DateTime.now().toUtc(),
      buildPid: null,
    ),
  );
  stdout.writeln(
    'Released lease on ${baseName(worktreePath)} (now immediately evictable if another build needs space).',
  );

  if (notifyWaiters) {
    final waiters = _readWaiters(parentDirPath);
    for (final w in waiters) {
      final cid =
          (w['sessionId'] as String?) ?? (w['conversationId'] as String?);
      if (cid == null || cid.isEmpty || cid == conversationId) continue;
      await _sendAgentMessage(
        cid,
        'Lease released on ${baseName(worktreePath)}; disk space can now be reclaimed if your build is waiting.',
        notifyCmd: notifyCmd,
      );
    }
  }
}

Future<void> _runStatus(
  String parentDirPath,
  int minFreeGiB,
  int idleMinutes, {
  required bool jsonMode,
}) async {
  final freeGiB = await _getFreeGiB(parentDirPath);
  final worktrees = await _scanWorktrees(parentDirPath, idleMinutes);
  final waiters = _readWaiters(parentDirPath);

  if (jsonMode) {
    final payload = <String, dynamic>{
      'freeGiB': double.parse(freeGiB.toStringAsFixed(2)),
      'minFreeGiB': minFreeGiB,
      'belowFloor': freeGiB < minFreeGiB,
      'idleMinutes': idleMinutes,
      'worktrees': worktrees
          .map(
            (w) => <String, dynamic>{
              'name': w.name,
              'path': w.path,
              'hydrated': w.isHydrated,
              'liveness': w.liveness.name,
              'lease': w.lease.toJson(),
              'totalOutKiB': w.totalOutKiB,
              'totalOutHuman': formatKiB(w.totalOutKiB),
              'lastUsed': w.lastUsed.toUtc().toIso8601String(),
              if (w.evictionState != null) 'evictionState': w.evictionState,
            },
          )
          .toList(),
      'waiters': waiters,
    };
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
    return;
  }

  final status = freeGiB >= minFreeGiB ? 'OK' : 'BELOW FLOOR';
  stdout.writeln('=== Flutter Engine Build Disk Status ===');
  stdout.writeln(
    'Free space: ${freeGiB.toStringAsFixed(1)}G (floor: ${minFreeGiB}G, status: $status, idle window: ${idleMinutes}m)',
  );
  stdout.writeln('');

  stdout.writeln('=== Worktrees ===');
  for (final w in worktrees) {
    final hydration = w.isHydrated ? 'HYDRATED' : 'DEHYDRATED';
    final live = switch (w.liveness) {
      LivenessClass.hardActive => 'HARD_ACTIVE',
      LivenessClass.softActive => 'SOFT_ACTIVE',
      LivenessClass.released => 'RELEASED',
      LivenessClass.inactive => 'INACTIVE',
    };
    final outSummary = w.totalOutKiB > 0
        ? 'out=${formatKiB(w.totalOutKiB)}'
        : 'out=0B';
    final ownerId = w.lease.sessionId;
    final owner = ownerId != null
        ? ' owner=${ownerId.substring(0, ownerId.length < 8 ? ownerId.length : 8)}'
        : '';
    final evicted = w.evictionState != null
        ? ' [EVICTED: ${w.evictionState!['action']}]'
        : '';
    stdout.writeln(
      '  ${w.name.padRight(32)} ${hydration.padRight(11)} ${live.padRight(12)} ${outSummary.padRight(12)} (${formatAge(w.lastUsed)})$owner$evicted',
    );
  }

  if (waiters.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('=== Space Waiters ===');
    for (final w in waiters) {
      stdout.writeln(
        '  - ${w['worktree']} (session=${w['sessionId'] ?? w['conversationId']}, needed=${w['neededGiB']}G, since=${w['since']})',
      );
    }
  }
}

Future<List<WorktreeState>> _scanWorktrees(
  String parentDirPath,
  int idleMinutes,
) async {
  final activeCids = await _loadActiveConversationIds();
  final dirs = _safeListDirs(Directory(parentDirPath));
  final results = <WorktreeState>[];
  final now = DateTime.now();

  for (final dir in dirs) {
    final name = baseName(dir.path);
    if (name == 'andywolff_skills' || name.startsWith('.')) continue;
    final gitDir = await _resolveGitDir(dir.path);
    if (gitDir == null) continue;
    // Only include Flutter repo worktrees.
    if (!safeExists(Directory('${dir.path}/engine/src/flutter'))) continue;

    final lease = _readLease(gitDir);
    final evictionState = readJsonMap('$gitDir/eviction_state.json');
    final isHydrated = _isWorktreeHydrated(dir.path);
    final hasLivePid =
        lease.buildPid != null && _isPidAlive(lease.buildPid!);

    final outTargets =
        <({String name, String path, int sizeKiB, bool isSnapshot})>[];
    final outDir = Directory('${dir.path}/engine/src/out');
    DateTime lastUsed = lease.lastHeartbeat ?? _dirModified(dir);

    for (final target in _safeListDirs(outDir)) {
      final tName = baseName(target.path);
      final kib = await _measureDirKiB(target.path);
      if (kib > 0) {
        outTargets.add((
          name: tName,
          path: target.path,
          sizeKiB: kib,
          isSnapshot: isSnapshotDir(target, tName),
        ));
      }
      final tMod = _dirModified(target);
      if (tMod.isAfter(lastUsed)) lastUsed = tMod;
    }

    final hasOpenSession =
        lease.sessionId != null && activeCids.contains(lease.sessionId);
    final liveness = classifyLiveness(
      lease: lease,
      hasLiveBuildPid: hasLivePid,
      hasOpenSession: hasOpenSession,
      hasActiveSessionInventory: activeCids.isNotEmpty,
      idleMinutes: idleMinutes,
      now: now,
    );

    results.add(
      WorktreeState(
        name: name,
        path: dir.path,
        gitDir: gitDir,
        lease: lease,
        liveness: liveness,
        isHydrated: isHydrated,
        hasLiveBuildPid: hasLivePid,
        outTargets: outTargets,
        lastUsed: lastUsed,
        evictionState: evictionState,
      ),
    );
  }

  return results;
}

bool _isWorktreeHydrated(String worktreePath) {
  return safeExists(File('$worktreePath/.gclient_entries')) ||
      safeExists(Directory('$worktreePath/engine/src/flutter/third_party/skia'));
}

bool _isPidAlive(int pidToCheck) {
  if (pidToCheck <= 0) return false;
  if (Platform.isLinux) {
    return Directory('/proc/$pidToCheck').existsSync();
  }
  final res = Process.runSync('kill', ['-0', '$pidToCheck']);
  return res.exitCode == 0;
}

Future<Set<String>> _loadActiveConversationIds() async {
  try {
    final resolvedScript = File(Platform.script.toFilePath())
        .resolveSymbolicLinksSync();
    final skillsRoot = File(resolvedScript).parent.parent.parent.path;
    final activeScript =
        '$skillsRoot/git-worktree-management/scripts/get_active_sessions.dart';
    if (!File(activeScript).existsSync()) return {};
    final res = await Process.run(Platform.resolvedExecutable, [
      activeScript,
      '--json',
    ]);
    if (res.exitCode != 0) return {};
    final decoded = jsonDecode(res.stdout as String);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((e) => e['conversationId'])
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();
    }
  } catch (_) {}
  return {};
}

Future<void> _sendHandoffRequest({
  required String targetConversationId,
  required String? requesterConversationId,
  required String requesterWorktree,
  required String blockerWorktree,
  required int neededGiB,
  required String? notifyCmd,
}) async {
  final replyHint = requesterConversationId != null
      ? ' Once released, notify session $requesterConversationId.'
      : '';
  final message =
      'Disk space handoff request: worktree $requesterWorktree needs ~${neededGiB}G to stay above the 40G free-space floor, and $blockerWorktree is currently marked active by your session. If you are done compiling, please run `engine_build.dart --release --workspace $blockerWorktree`.$replyHint';
  await _sendAgentMessage(
    targetConversationId,
    message,
    notifyCmd: notifyCmd,
  );
}

Future<void> _sendAgentMessage(
  String targetSessionId,
  String message, {
  required String? notifyCmd,
}) async {
  if (notifyCmd == null || notifyCmd.trim().isEmpty) {
    stdout.writeln(
      'Handoff notice for session $targetSessionId (set AGENT_NOTIFY_CMD to deliver automatically): $message',
    );
    return;
  }
  try {
    final res = await Process.run('sh', [
      '-c',
      '$notifyCmd "\$1" "\$2"',
      '_',
      targetSessionId,
      message,
    ]);
    if (res.exitCode == 0) {
      stdout.writeln('Sent handoff message to session $targetSessionId.');
    }
  } catch (_) {}
}

void _registerWaiter(
  String parentDirPath, {
  required String conversationId,
  required String worktree,
  required int neededGiB,
}) {
  final file = File('$parentDirPath/.flutter_space_waiters.json');
  final waiters = _readWaiters(parentDirPath)
    ..removeWhere(
      (w) =>
          w['sessionId'] == conversationId ||
          w['conversationId'] == conversationId,
    );
  waiters.add({
    'sessionId': conversationId,
    'worktree': worktree,
    'neededGiB': neededGiB,
    'since': DateTime.now().toUtc().toIso8601String(),
  });
  atomicWriteJson(file, waiters);
}

void _removeWaiter(String parentDirPath, String conversationId) {
  final file = File('$parentDirPath/.flutter_space_waiters.json');
  if (!safeExists(file)) return;
  final waiters = _readWaiters(parentDirPath)
    ..removeWhere(
      (w) =>
          w['sessionId'] == conversationId ||
          w['conversationId'] == conversationId,
    );
  try {
    if (waiters.isEmpty) {
      file.deleteSync();
    } else {
      atomicWriteJson(file, waiters);
    }
  } catch (_) {
    // Best-effort cleanup of waiter file.
  }
}

List<Map<String, dynamic>> _readWaiters(String parentDirPath) {
  final decoded = readJsonDynamic(
    File('$parentDirPath/.flutter_space_waiters.json'),
  );
  if (decoded is List) {
    return decoded.whereType<Map<String, dynamic>>().toList();
  }
  return <Map<String, dynamic>>[];
}

LeaseInfo _readLease(String gitDir) {
  final json = readJsonMap('$gitDir/agent_session.json');
  return json != null ? LeaseInfo.fromJson(json) : const LeaseInfo();
}

void _writeLease(String gitDir, LeaseInfo lease) {
  atomicWriteJson(File('$gitDir/agent_session.json'), lease.toJson());
}

void _writeEvictionState(
  String gitDir, {
  required String action,
  required String byConversation,
  required String? previousOwner,
  required String? previousBranch,
  required int reclaimedKiB,
  required String detail,
}) {
  final payload = <String, dynamic>{
    'action': action,
    'at': DateTime.now().toUtc().toIso8601String(),
    'byConversation': byConversation,
    if (previousOwner != null) 'previousOwner': previousOwner,
    if (previousBranch != null) 'previousBranch': previousBranch,
    'reclaimedKiB': reclaimedKiB,
    'reclaimedHuman': formatKiB(reclaimedKiB),
    'detail': detail,
  };
  atomicWriteJson(File('$gitDir/eviction_state.json'), payload);
}

void _deleteFileIfExists(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {
    // Best-effort file removal.
  }
}

Future<int> _streamCommand(
  String executable,
  List<String> args, {
  required String workingDirectory,
}) async {
  final proc = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return proc.exitCode;
}

Future<String?> _resolveTargetWorktree(
  String? workspaceArg,
  String parentDirPath,
) async {
  if (workspaceArg != null && workspaceArg.isNotEmpty) {
    final direct = Directory(workspaceArg);
    if (safeExists(direct)) {
      return direct.resolveSymbolicLinksSync();
    }
    final sibling = Directory('$parentDirPath/$workspaceArg');
    if (safeExists(sibling)) {
      return sibling.resolveSymbolicLinksSync();
    }
    return null;
  }
  final topRes = await _runSystemCmd('git', <String>[
    'rev-parse',
    '--show-toplevel',
  ]);
  if (topRes != null && topRes.exitCode == 0) {
    final top = (topRes.stdout as String).trim();
    if (top.isNotEmpty && safeExists(Directory('$top/engine/src/flutter'))) {
      return top;
    }
  }
  return null;
}

Future<String?> _resolveGitDir(String worktreePath) async {
  final res = await _runSystemCmd('git', <String>[
    '-C',
    worktreePath,
    'rev-parse',
    '--absolute-git-dir',
  ]);
  if (res != null && res.exitCode == 0) {
    final out = (res.stdout as String).trim();
    if (out.isNotEmpty) return out;
  }
  return null;
}

Future<String?> _resolveBranch(String worktreePath) async {
  final res = await _runSystemCmd('git', <String>[
    '-C',
    worktreePath,
    'branch',
    '--show-current',
  ]);
  if (res != null && res.exitCode == 0) {
    final out = (res.stdout as String).trim();
    if (out.isNotEmpty) return out;
  }
  return null;
}

Future<String> _detectParentDir(String? workspaceArg) async {
  if (workspaceArg != null &&
      workspaceArg.contains('/') &&
      safeExists(Directory(workspaceArg))) {
    return Directory(workspaceArg).parent.path;
  }
  final gitTop = await _runSystemCmd('git', <String>[
    'rev-parse',
    '--show-toplevel',
  ]);
  if (gitTop != null && gitTop.exitCode == 0) {
    final topPath = (gitTop.stdout as String).trim();
    if (topPath.isNotEmpty) {
      return Directory(topPath).parent.path;
    }
  }
  final resolvedScript = File(Platform.script.toFilePath())
      .resolveSymbolicLinksSync();
  // <parent>/andywolff_skills/.agents/skills/flutter-engine-build/scripts/engine_build.dart
  return File(resolvedScript).parent.parent.parent.parent.parent.parent.path;
}

Future<double> _getFreeGiB(String path) async {
  final target =
      Platform.isMacOS && safeExists(Directory('/System/Volumes/Data'))
      ? '/System/Volumes/Data'
      : safeExists(Directory(path))
      ? path
      : '/';
  final res = await _runSystemCmd('df', <String>['-Pk', target]);
  if (res == null || res.exitCode != 0) return 0;
  final lines = (res.stdout as String).trim().split('\n');
  if (lines.length < 2) return 0;
  final cols = lines.last.trim().split(RegExp(r'\s+'));
  if (cols.length < 4) return 0;
  final availKiB = int.tryParse(cols[3]) ?? 0;
  return availKiB / (1024 * 1024);
}

Future<int> _measureDirKiB(String path) async {
  final res = await _runSystemCmd('du', <String>['-sk', path]);
  if (res == null || res.exitCode != 0) return 0;
  final raw = (res.stdout as String).trim();
  if (raw.isEmpty) return 0;
  return int.tryParse(raw.split(RegExp(r'\s+')).first) ?? 0;
}

Future<ProcessResult?> _runSystemCmd(
  String cmd,
  List<String> args, {
  String? workingDirectory,
}) async {
  for (final candidate in <String>[cmd, '/usr/bin/$cmd', '/bin/$cmd']) {
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

DateTime _dirModified(Directory dir) {
  var newest = DateTime.fromMillisecondsSinceEpoch(0);
  void consider(FileSystemEntity e) {
    try {
      final m = e.statSync().modified;
      if (m.isAfter(newest)) newest = m;
    } catch (_) {
      // Ignore unreadable entries when computing modified timestamp.
    }
  }

  consider(dir);
  for (final marker in const <String>['.ninja_log', 'build.ninja', 'args.gn']) {
    final f = File('${dir.path}/$marker');
    if (safeExists(f)) consider(f);
  }
  return newest;
}

List<Directory> _safeListDirs(Directory dir) {
  try {
    if (!dir.existsSync()) return const <Directory>[];
    return dir.listSync(followLinks: false).whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  } catch (_) {
    return const <Directory>[];
  }
}

String? _getOption(List<String> args, String flag) {
  final idx = args.indexOf(flag);
  if (idx != -1 && idx + 1 < args.length) return args[idx + 1];
  return null;
}

void _printUsage() {
  stdout.writeln('Usage: dart engine_build.dart [options] -- <build-command...>');
  stdout.writeln('');
  stdout.writeln('Modes:');
  stdout.writeln('  --status                    Show disk floor, worktree hydration, leases, and waiters.');
  stdout.writeln('  --release                   Release lease on target worktree so it is immediately evictable.');
  stdout.writeln('  --dehydrate                 Safely dehydrate target worktree (removes untracked gclient deps + out/).');
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln('  --json                      With --status, output machine-readable JSON.');
  stdout.writeln('  --workspace <name|path>     Target Flutter worktree (defaults to git toplevel of cwd).');
  stdout.writeln('  --parent-dir <path>         Parent directory containing sibling worktrees.');
  stdout.writeln('  --session-id <id>           Current agent session ID for lease tracking.');
  stdout.writeln('  --notify-cmd <cmd>          Optional notifier command (overrides AGENT_NOTIFY_CMD).');
  stdout.writeln('  --min-free-gb <n>           Free disk floor in GiB (default: $_defaultMinFreeGiB).');
  stdout.writeln('  --headroom-gb <n>           Additional headroom GiB before build/sync (default: 10 build / 25 sync).');
  stdout.writeln('  --idle-minutes <n>          Hard-active idle window in minutes (default: $_defaultIdleMinutes).');
  stdout.writeln('  --no-rehydrate              Fail instead of auto-running `gclient sync -D` on dehydrated worktrees.');
  stdout.writeln('  --wait                      Wait if blocked by hard-active worktrees until space frees up.');
  stdout.writeln('  --wait-timeout-min <n>      Max minutes to wait in --wait mode (default: 30).');
  stdout.writeln('  --request-handoff           Send handoff request to hard-active blockers via AGENT_NOTIFY_CMD.');
  stdout.writeln('  --notify-waiters            With --release, notify queued waiters via AGENT_NOTIFY_CMD.');
  stdout.writeln('  --dry-run                   Preview evictions without deleting anything.');
}
