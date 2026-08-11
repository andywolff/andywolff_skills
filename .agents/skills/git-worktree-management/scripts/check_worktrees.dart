import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  // Find repository root
  final repoRootResult = await Process.run('git', ['rev-parse', '--show-toplevel']);
  if (repoRootResult.exitCode != 0) {
    stderr.write('Error: Not in a git repository.\n');
    exit(1);
  }
  final repoRoot = (repoRootResult.stdout as String).trim();

  // Detect upstream branch
  final upstreamBranch = await detectUpstreamBranch(repoRoot);
  print('Using upstream branch: $upstreamBranch\n');

  // List worktrees
  final worktreeResult = await Process.run('git', ['worktree', 'list']);
  if (worktreeResult.exitCode != 0) {
    stderr.write('Error listing worktrees: ${worktreeResult.stderr}\n');
    exit(1);
  }

  final lines = (worktreeResult.stdout as String).trim().split('\n');

  // Format header
  printRow('Worktree Path', 'Branch', 'Merge Status', 'Clean Status', 'PR Status');
  printRow('-' * 40, '-' * 25, '-' * 18, '-' * 12, '-' * 20);

  for (final line in lines) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.isEmpty) continue;
    final path = parts[0];

    // Skip main worktree
    if (path == repoRoot) continue;

    // Handle missing worktree directories on disk
    if (!Directory(path).existsSync()) {
      final pathBase = path.split('/').last;
      printRow(pathBase, '(missing)', 'N/A', 'N/A', 'N/A');
      continue;
    }

    final branch = await getBranchName(path);
    final cleanStatus = await getCleanStatus(path);
    final mergeStatus = await getMergeStatus(path, branch, upstreamBranch);
    final prStatus = branch == '(detached)' ? 'N/A' : await getPRStatus(branch, repoRoot);

    final pathBase = path.split('/').last;
    printRow(pathBase, branch, mergeStatus, cleanStatus, prStatus);
  }
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

  // Count untracked files natively by parsing status output
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
Future<String> getMergeStatus(String path, String branch, String upstreamBranch) async {
  if (branch == '(detached)') {
    return 'N/A';
  }

  // 1. Direct Merge Check
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

  // 2. Squash/Patch Merge Check via diff comparison
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

/// Fetches the PR status using the GitHub CLI.
Future<String> getPRStatus(String branch, String repoRoot) async {
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
      return 'No PR';
    }

    final List<dynamic> prs = jsonDecode(result.stdout as String) as List<dynamic>;
    if (prs.isEmpty) {
      return 'No PR';
    }

    final first = prs.first as Map<String, dynamic>;
    final state = first['state'] as String;
    final number = first['number'] as int;
    return '$state (#$number)';
  } catch (_) {
    return 'N/A'; // gh CLI not installed or failed
  }
}

/// Prints a formatted row to stdout.
void printRow(String col1, String col2, String col3, String col4, String col5) {
  print(
    '${col1.padRight(40)} | '
    '${col2.padRight(25)} | '
    '${col3.padRight(18)} | '
    '${col4.padRight(12)} | '
    '${col5.padRight(20)}',
  );
}
