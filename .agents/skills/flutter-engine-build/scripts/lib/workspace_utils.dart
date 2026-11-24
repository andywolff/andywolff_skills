import 'dart:convert';
import 'dart:io';

const standardBaseTargets = <String>{
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

enum LivenessClass { hardActive, softActive, released, inactive }

class LeaseInfo {
  final String? sessionId;
  final String? branch;
  final String state; // busy | idle | released | unknown
  final DateTime? lastHeartbeat;
  final int? buildPid;

  const LeaseInfo({
    this.sessionId,
    this.branch,
    this.state = 'unknown',
    this.lastHeartbeat,
    this.buildPid,
  });

  factory LeaseInfo.fromJson(Map<String, dynamic> json) {
    DateTime? parsedTime;
    final rawTime = json['lastHeartbeat'] as String?;
    if (rawTime != null && rawTime.isNotEmpty) {
      parsedTime = DateTime.tryParse(rawTime);
    }
    return LeaseInfo(
      sessionId:
          (json['sessionId'] as String?) ?? (json['conversationId'] as String?),
      branch: json['branch'] as String?,
      state: (json['state'] as String?) ?? 'unknown',
      lastHeartbeat: parsedTime,
      buildPid: json['buildPid'] is int ? json['buildPid'] as int : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (sessionId != null) 'sessionId': sessionId,
    if (branch != null) 'branch': branch,
    'state': state,
    if (lastHeartbeat != null)
      'lastHeartbeat': lastHeartbeat!.toUtc().toIso8601String(),
    if (buildPid != null) 'buildPid': buildPid,
  };
}

LivenessClass classifyLiveness({
  required LeaseInfo lease,
  required bool hasLiveBuildPid,
  required bool hasOpenSession,
  required bool hasActiveSessionInventory,
  required int idleMinutes,
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final withinIdleWindow =
      lease.lastHeartbeat != null &&
      current.difference(lease.lastHeartbeat!).inMinutes < idleMinutes;

  if (hasLiveBuildPid || (lease.state == 'busy' && withinIdleWindow)) {
    return LivenessClass.hardActive;
  }
  if (lease.state == 'released') {
    return LivenessClass.released;
  }
  if (withinIdleWindow && (!hasActiveSessionInventory || hasOpenSession)) {
    return LivenessClass.hardActive;
  }
  if (hasOpenSession) {
    return LivenessClass.softActive;
  }
  return LivenessClass.inactive;
}

Set<String> parseGclientEntries(String content) {
  final paths = <String>{};
  final keyRegex = RegExp(r'''['"]([^'"]+)['"]\s*:''');
  for (final match in keyRegex.allMatches(content)) {
    final raw = match.group(1)!;
    final rel = raw.split(':').first.replaceAll(RegExp(r'^/+|/+$'), '');
    if (rel.isNotEmpty && rel != '.') {
      paths.add(rel);
    }
  }
  return paths;
}

bool isSnapshotDir(Directory dir, String name) {
  try {
    if (File('${dir.path}${Platform.pathSeparator}.snapshot_variant')
        .existsSync()) {
      return true;
    }
  } catch (_) {}
  if (standardBaseTargets.contains(name)) return false;
  return standardBaseTargets.any((base) => name.startsWith('${base}_'));
}

String baseName(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String formatKiB(int kib) {
  if (kib <= 0) return '0B';
  const mib = 1024;
  const gib = 1024 * 1024;
  if (kib >= gib) return '${(kib / gib).toStringAsFixed(1)}G';
  if (kib >= mib) return '${(kib / mib).round()}M';
  return '${kib}K';
}

String formatAge(DateTime modified, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(modified);
  if (diff.isNegative || diff.inMinutes < 60) {
    final mins = diff.inMinutes < 1 ? 1 : diff.inMinutes;
    return '${mins}m ago';
  }
  if (diff.inHours < 48) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

dynamic readJsonDynamic(File file) {
  if (!safeExists(file)) return null;
  try {
    return jsonDecode(file.readAsStringSync());
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? readJsonMap(String path) {
  final decoded = readJsonDynamic(File(path));
  return decoded is Map<String, dynamic> ? decoded : null;
}

/// Atomically writes JSON to [file] using a sibling temporary file and rename
/// so concurrent hooks and builds never read a partially written file.
void atomicWriteJson(File file, Object data) {
  final tmpFile = File('${file.path}.tmp.$pid');
  try {
    final encoded = '${const JsonEncoder.withIndent('  ').convert(data)}\n';
    tmpFile.writeAsStringSync(encoded, flush: true);
    tmpFile.renameSync(file.path);
  } catch (_) {
    try {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    } catch (_) {}
  }
}

bool safeExists(FileSystemEntity entity) {
  try {
    return entity.existsSync();
  } catch (_) {
    return false;
  }
}
