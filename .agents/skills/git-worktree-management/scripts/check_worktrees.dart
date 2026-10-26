import 'dart:convert';
import 'dart:io';

import 'get_active_sessions.dart';

final _returnIntentPattern = RegExp(
  r'\b(come\s+back|coming\s+back|reopen|revisit|return\s+to|at\s+some\s+point|paused?|on\s+hold|(resume|finish|work\s+on|try|investigate)\s+later|pick\s+(this|it)\s+(back\s+)?up)\b',
  caseSensitive: false,
);

class WorktreeReport {
  final String pathBase;
  final String branch;
  final String mergeStatus;
  final String cleanStatus;
  final String prStatus;
  final String activeStatus;

  const WorktreeReport({
    required this.pathBase,
    required this.branch,
    required this.mergeStatus,
    required this.cleanStatus,
    required this.prStatus,
    required this.activeStatus,
  });

  List<String> toRowValues() => [
    pathBase,
    branch,
    mergeStatus,
    cleanStatus,
    prStatus,
    activeStatus,
  ];
}

const _tableColumns = [
  (title: 'Worktree Path', width: 40),
  (title: 'Branch', width: 25),
  (title: 'Merge Status', width: 18),
  (title: 'Clean Status', width: 12),
  (title: 'PR Status', width: 32),
  (title: 'Active Session', width: 25),
];

Future<void> main() async {
  final repoRootResult = await Process.run('git', ['rev-parse', '--show-toplevel']);
  if (repoRootResult.exitCode != 0) {
    stderr.write('Error: Not in a git repository.\n');
    exit(1);
  }
  final repoRoot = (repoRootResult.stdout as String).trim();

  final upstreamBranch = await detectUpstreamBranch(repoRoot);
  print('Using upstream branch: $upstreamBranch\n');

  final activeSessions = await getActiveJetskiSessions();

  final worktreeResult = await Process.run('git', ['worktree', 'list']);
  if (worktreeResult.exitCode != 0) {
    stderr.write('Error listing worktrees: ${worktreeResult.stderr}\n');
    exit(1);
  }

  final lines = (worktreeResult.stdout as String).trim().split('\n');
  final worktreePaths = lines
      .map((line) => line.split(RegExp(r'\s+')).firstOrNull)
      .whereType<String>()
      .where((path) => path.isNotEmpty && path != repoRoot)
      .toList();

  printTable([
    for (final path in worktreePaths)
      await evaluateWorktree(path, repoRoot, upstreamBranch, activeSessions),
  ]);
}

/// Evaluates git, PR, and active session status for a single worktree directory.
Future<WorktreeReport> evaluateWorktree(
  String path,
  String repoRoot,
  String upstreamBranch,
  Map<String, List<SessionInfo>> activeSessions,
) async {
  final pathBase = path.split('/').last;

  if (!Directory(path).existsSync()) {
    return WorktreeReport(
      pathBase: pathBase,
      branch: '(missing)',
      mergeStatus: 'N/A',
      cleanStatus: 'N/A',
      prStatus: 'N/A',
      activeStatus: '-',
    );
  }

  final branch = await getBranchName(path);
  final isDetached = branch == '(detached)';
  final cleanStatus = await getCleanStatus(path);
  final prInfo = isDetached ? null : await getPRInfo(branch, repoRoot);
  final mergeStatus = await getMergeStatus(
    path,
    branch,
    upstreamBranch,
    prInfo: prInfo != null ? (state: prInfo.state, number: prInfo.number) : null,
  );

  return WorktreeReport(
    pathBase: pathBase,
    branch: branch,
    mergeStatus: mergeStatus,
    cleanStatus: cleanStatus,
    prStatus: formatPrStatus(prInfo, isDetached: isDetached),
    activeStatus: formatActiveStatus(activeSessions[path] ?? const []),
  );
}

/// Formats the PR status label, adding a return-intent indicator for closed PRs.
String formatPrStatus(
  ({String state, int number, bool returnIntent})? prInfo, {
  required bool isDetached,
}) {
  if (prInfo == null) {
    return isDetached ? 'N/A' : 'No PR';
  }

  if (prInfo.state.toUpperCase() == 'CLOSED' && prInfo.returnIntent) {
    return 'CLOSED (#${prInfo.number}) [return later]';
  }

  return '${prInfo.state} (#${prInfo.number})';
}

/// Formats active Jetski sessions into a concise status string.
String formatActiveStatus(List<SessionInfo> sessions) {
  if (sessions.isEmpty) {
    return '-';
  }
  if (sessions.length == 1) {
    return 'Active: ${sessions.first.title}';
  }
  return 'Active (${sessions.length} sessions)';
}

/// Detects the upstream main or master branch name from git references.
Future<String> detectUpstreamBranch(String repoRoot) async {
  for (final branch in ['upstream/master', 'upstream/main', 'origin/master', 'origin/main']) {
    final check = await Process.run('git', [
      'rev-parse',
      '--verify',
      branch,
    ], workingDirectory: repoRoot);
    if (check.exitCode == 0) {
      return branch;
    }
  }
  return 'master';
}

/// Resolves the checked-out branch name for a given worktree path.
Future<String> getBranchName(String path) async {
  final result = await Process.run('git', ['-C', path, 'rev-parse', '--abbrev-ref', 'HEAD']);
  final branch = (result.stdout as String).trim();
  return (branch == 'HEAD' || branch.isEmpty) ? '(detached)' : branch;
}

/// Counts modified/untracked files in the worktree to determine dirty status.
Future<String> getCleanStatus(String path) async {
  final stagedCount = await countGitOutputLines(['diff', '--cached', '--name-only'], path);
  final unstagedCount = await countGitOutputLines(['diff', '--name-only'], path);

  final statusResult = await Process.run('git', ['-C', path, 'status', '--short']);
  int untrackedCount = 0;
  for (final line in (statusResult.stdout as String).split('\n')) {
    if (line.trim().startsWith('??')) {
      untrackedCount++;
    }
  }

  if (stagedCount == 0 && unstagedCount == 0 && untrackedCount == 0) {
    return 'Clean';
  }
  return '${stagedCount}S / ${unstagedCount}M / ${untrackedCount}U';
}

/// Helper to count stdout lines returned by a git command.
Future<int> countGitOutputLines(List<String> gitArgs, String path) async {
  final result = await Process.run('git', ['-C', path, ...gitArgs]);
  if (result.exitCode != 0) return 0;
  final trimmed = (result.stdout as String).trim();
  return trimmed.isEmpty ? 0 : trimmed.split('\n').length;
}

/// Determines the merge status of the branch relative to the upstream branch.
Future<String> getMergeStatus(
  String path,
  String branch,
  String upstreamBranch, {
  ({String state, int number})? prInfo,
}) async {
  if (branch == '(detached)') {
    return 'N/A';
  }

  // 1. Direct Ancestor Merge Check
  final ancestorCheck = await Process.run('git', [
    '-C',
    path,
    'merge-base',
    '--is-ancestor',
    branch,
    upstreamBranch,
  ]);
  if (ancestorCheck.exitCode == 0) {
    return 'Merged (direct)';
  }

  // 2. Authoritative GitHub PR check (if PR is merged on upstream remote)
  if (prInfo != null && prInfo.state.toUpperCase() == 'MERGED') {
    return 'Merged (PR #${prInfo.number})';
  }

  // 3. Search for PR number reference in upstream branch commit history
  if (prInfo != null) {
    final prLogCheck = await Process.run('git', [
      '-C',
      path,
      'log',
      upstreamBranch,
      '--grep=(#${prInfo.number})',
      '-n',
      '1',
      '--oneline',
    ]);
    if (prLogCheck.exitCode == 0 && (prLogCheck.stdout as String).trim().isNotEmpty) {
      return 'Merged (PR #${prInfo.number})';
    }
  }

  // 4. Squash/Patch Merge Check via diff comparison
  final diffFilesResult = await Process.run('git', [
    '-C',
    path,
    'diff',
    '--name-only',
    '$upstreamBranch...$branch',
  ]);
  if (diffFilesResult.exitCode != 0) {
    return 'Unmerged';
  }

  final diffFilesStr = (diffFilesResult.stdout as String).trim();
  if (diffFilesStr.isEmpty) {
    return 'Merged (empty diff)';
  }

  final diffFiles = diffFilesStr.split('\n').map((f) => f.trim()).toList();
  final diffCompare = await Process.run('git', [
    '-C',
    path,
    'diff',
    upstreamBranch,
    branch,
    '--',
    ...diffFiles,
  ]);
  if (diffCompare.exitCode == 0 && (diffCompare.stdout as String).trim().isEmpty) {
    return 'Merged (squashed)';
  }

  return 'Unmerged';
}

/// Fetches the PR status and return intent using the GitHub CLI.
Future<({String state, int number, bool returnIntent})?> getPRInfo(
  String branch,
  String repoRoot,
) async {
  try {
    final result = await Process.run('gh', [
      'pr',
      'list',
      '--head',
      branch,
      '--state',
      'all',
      '--json',
      'state,number',
    ], workingDirectory: repoRoot);

    if (result.exitCode != 0) {
      return null;
    }

    final List<dynamic> prs = jsonDecode(result.stdout as String) as List<dynamic>;
    if (prs.isEmpty) {
      return null;
    }

    final first = prs.first as Map<String, dynamic>;
    final state = first['state'] as String;
    final number = first['number'] as int;

    bool returnIntent = false;
    if (state.toUpperCase() == 'CLOSED') {
      returnIntent = await checkClosedPRReturnIntent(number, repoRoot);
    }

    return (state: state, number: number, returnIntent: returnIntent);
  } catch (_) {
    return null; // gh CLI not installed or failed
  }
}

/// Checks if a closed PR has an author comment indicating intent to return or reopen.
Future<bool> checkClosedPRReturnIntent(int prNumber, String repoRoot) async {
  try {
    final result = await Process.run('gh', [
      'pr',
      'view',
      '$prNumber',
      '--json',
      'comments',
    ], workingDirectory: repoRoot);

    if (result.exitCode != 0) {
      return false;
    }

    final Map<String, dynamic> data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final List<dynamic> comments = data['comments'] as List<dynamic>? ?? [];

    for (final comment in comments) {
      final map = comment as Map<String, dynamic>;
      final viewerDidAuthor = map['viewerDidAuthor'] == true;
      final body = (map['body'] as String?) ?? '';

      if (viewerDidAuthor && _returnIntentPattern.hasMatch(body)) {
        return true;
      }
    }
  } catch (_) {}
  return false;
}

/// Prints a collection of worktree reports in a standardized formatted table.
void printTable(List<WorktreeReport> reports) {
  final header = _tableColumns.map((c) => c.title.padRight(c.width)).join(' | ');
  final divider = _tableColumns.map((c) => '-' * c.width).join(' | ');

  print(header);
  print(divider);

  for (final report in reports) {
    final values = report.toRowValues();
    final row = [
      for (int i = 0; i < _tableColumns.length; i++) values[i].padRight(_tableColumns[i].width),
    ].join(' | ');
    print(row);
  }
}
