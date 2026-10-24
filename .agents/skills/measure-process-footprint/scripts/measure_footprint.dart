import 'dart:convert';
import 'dart:io';

void showUsageAndExit() {
  print('''
Usage:
  dart measure_footprint.dart [options]

Target Selection (Pick one):
  --pid <pid>                 Target process by PID.
  --name <process_name>       Target process by name (resolves running PID).
  --android <package_or_pid>  Target Android application via adb.

Sampling Options:
  --samples <count>           Number of samples to collect (default: 1).
  --interval <seconds>        Delay between samples in seconds (default: 1.0).
  --output <file.json>        Save collected memory snapshot(s) to JSON.

Comparison:
  --compare <baseline.json> <patched.json>
                              Compare two saved memory snapshots and output a markdown diff table.

Examples:
  # Capture macOS process footprint:
  dart measure_footprint.dart --pid 12345

  # Capture 5 samples every 2 seconds and save to baseline.json:
  dart measure_footprint.dart --name repro_app --samples 5 --interval 2 --output baseline.json

  # Compare baseline vs patched snapshots:
  dart measure_footprint.dart --compare baseline.json patched.json
''');
  exit(1);
}

String? getOption(List<String> args, String option) {
  final int index = args.indexOf(option);
  if (index != -1 && index + 1 < args.length) {
    return args[index + 1];
  }
  return null;
}

bool hasFlag(List<String> args, String flag) {
  return args.contains(flag);
}

class MemorySnapshot {
  MemorySnapshot({
    required this.timestamp,
    required this.platform,
    required this.target,
    required this.physFootprintBytes,
    required this.physFootprintPeakBytes,
    required this.regions,
    this.rawOutput = '',
  });

  factory MemorySnapshot.fromJson(Map<String, dynamic> json) {
    return MemorySnapshot(
      timestamp: DateTime.parse(json['timestamp'] as String),
      platform: json['platform'] as String,
      target: json['target'] as String,
      physFootprintBytes: json['physFootprintBytes'] as int,
      physFootprintPeakBytes: json['physFootprintPeakBytes'] as int,
      regions: (json['regions'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v as int),
      ),
      rawOutput: json['rawOutput'] as String? ?? '',
    );
  }

  final DateTime timestamp;
  final String platform;
  final String target;
  final int physFootprintBytes;
  final int physFootprintPeakBytes;
  final Map<String, int> regions;
  final String rawOutput;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'timestamp': timestamp.toIso8601String(),
    'platform': platform,
    'target': target,
    'physFootprintBytes': physFootprintBytes,
    'physFootprintPeakBytes': physFootprintPeakBytes,
    'regions': regions,
    'rawOutput': rawOutput,
  };
}

String formatBytes(int bytes) {
  if (bytes.abs() < 1024) return '$bytes B';
  if (bytes.abs() < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(2)} KB';
  }
  if (bytes.abs() < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

int parseBytesString(String str) {
  final clean = str.trim().toUpperCase();
  final match = RegExp(r'([\d\.]+)\s*(B|KB|MB|GB|K|M|G)?').firstMatch(clean);
  if (match == null) return 0;
  final double val = double.tryParse(match.group(1)!) ?? 0;
  final unit = match.group(2) ?? 'B';
  switch (unit) {
    case 'GB':
    case 'G':
      return (val * 1024 * 1024 * 1024).round();
    case 'MB':
    case 'M':
      return (val * 1024 * 1024).round();
    case 'KB':
    case 'K':
      return (val * 1024).round();
    default:
      return val.round();
  }
}

Future<int?> resolvePidByName(String name) async {
  final res = await Process.run('pgrep', ['-f', name]);
  if (res.exitCode == 0) {
    final lines = res.stdout.toString().trim().split('\n');
    for (final l in lines) {
      final pid = int.tryParse(l.trim());
      if (pid != null && pid != pid) return pid;
    }
  }
  return null;
}

Future<MemorySnapshot> captureMacFootprint(int targetPid) async {
  final res = await Process.run('/usr/bin/footprint', [targetPid.toString()]);
  if (res.exitCode != 0) {
    throw Exception('Failed to run footprint on PID $targetPid: ${res.stderr}');
  }

  final stdoutStr = res.stdout.toString();
  int physFootprint = 0;
  int physFootprintPeak = 0;
  final Map<String, int> regions = <String, int>{};

  for (final line in stdoutStr.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.contains('phys_footprint:')) {
      final match = RegExp(r'phys_footprint:\s*([^\n|]+)').firstMatch(trimmed);
      if (match != null) {
        physFootprint = parseBytesString(match.group(1)!);
      }
    }
    if (trimmed.contains('phys_footprint_peak:')) {
      final match = RegExp(r'phys_footprint_peak:\s*([^\n|]+)')
          .firstMatch(trimmed);
      if (match != null) {
        physFootprintPeak = parseBytesString(match.group(1)!);
      }
    }
    if (trimmed.contains('VM_ALLOCATE') ||
        trimmed.contains('IOKit') ||
        trimmed.contains('IOSurface') ||
        trimmed.contains('MALLOC') ||
        trimmed.contains('Stack') ||
        trimmed.contains('TEXT') ||
        trimmed.contains('DATA')) {
      final parts = trimmed.split(RegExp(r'\s{2,}'));
      if (parts.length >= 2) {
        final category = parts.last.trim();
        final dirtyOrSize = parts.first.trim();
        regions[category] = parseBytesString(dirtyOrSize);
      }
    }
  }

  if (physFootprint == 0 && regions.containsKey('TOTAL')) {
    physFootprint = regions['TOTAL']!;
  }

  return MemorySnapshot(
    timestamp: DateTime.now(),
    platform: 'macOS',
    target: targetPid.toString(),
    physFootprintBytes: physFootprint,
    physFootprintPeakBytes: physFootprintPeak > 0
        ? physFootprintPeak
        : physFootprint,
    regions: regions,
    rawOutput: stdoutStr,
  );
}

Future<MemorySnapshot> captureAndroidFootprint(String packageOrPid) async {
  final res = await Process.run('adb', [
    'shell',
    'dumpsys',
    'meminfo',
    packageOrPid,
  ]);
  if (res.exitCode != 0) {
    throw Exception(
      'Failed to run dumpsys meminfo on Android target $packageOrPid: ${res.stderr}',
    );
  }

  final stdoutStr = res.stdout.toString();
  int totalPss = 0;
  int totalRss = 0;
  final Map<String, int> regions = <String, int>{};

  for (final line in stdoutStr.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('TOTAL PSS:')) {
      final match = RegExp(r'TOTAL PSS:\s*(\d+)').firstMatch(trimmed);
      if (match != null) {
        totalPss = (int.parse(match.group(1)!) * 1024);
      }
    }
    if (trimmed.startsWith('TOTAL RSS:')) {
      final match = RegExp(r'TOTAL RSS:\s*(\d+)').firstMatch(trimmed);
      if (match != null) {
        totalRss = (int.parse(match.group(1)!) * 1024);
      }
    }
    if (trimmed.startsWith('Native Heap') ||
        trimmed.startsWith('Java Heap') ||
        trimmed.startsWith('Code') ||
        trimmed.startsWith('Stack') ||
        trimmed.startsWith('Graphics') ||
        trimmed.startsWith('Private Other') ||
        trimmed.startsWith('System')) {
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final category =
            parts[0] + (parts[1].startsWith('Heap') ? ' Heap' : '');
        final pssVal =
            int.tryParse(
              parts.lastWhere(
                (p) => int.tryParse(p) != null,
                orElse: () => '0',
              ),
            ) ??
            0;
        regions[category] = pssVal * 1024;
      }
    }
  }

  return MemorySnapshot(
    timestamp: DateTime.now(),
    platform: 'Android',
    target: packageOrPid,
    physFootprintBytes: totalPss,
    physFootprintPeakBytes: totalRss,
    regions: regions,
    rawOutput: stdoutStr,
  );
}

void compareSnapshots(String baselinePath, String patchedPath) {
  final baselineFile = File(baselinePath);
  final patchedFile = File(patchedPath);

  if (!baselineFile.existsSync() || !patchedFile.existsSync()) {
    print('Error: Both snapshot files must exist.');
    exit(1);
  }

  final dynamic baseJson = jsonDecode(baselineFile.readAsStringSync());
  final dynamic patchJson = jsonDecode(patchedFile.readAsStringSync());

  final MemorySnapshot baseSnap = baseJson is List
      ? MemorySnapshot.fromJson((baseJson.last as Map).cast<String, dynamic>())
      : MemorySnapshot.fromJson((baseJson as Map).cast<String, dynamic>());

  final MemorySnapshot patchSnap = patchJson is List
      ? MemorySnapshot.fromJson((patchJson.last as Map).cast<String, dynamic>())
      : MemorySnapshot.fromJson((patchJson as Map).cast<String, dynamic>());

  final int fpDelta =
      patchSnap.physFootprintBytes - baseSnap.physFootprintBytes;
  final int peakDelta =
      patchSnap.physFootprintPeakBytes - baseSnap.physFootprintPeakBytes;

  print('\n## Memory Footprint Comparison\n');
  print(
    '| Metric | Baseline (${baseSnap.platform}) | Patched (${patchSnap.platform}) | Delta | % Change |',
  );
  print('| :--- | :--- | :--- | :--- | :--- |');

  String formatDelta(int delta, int base) {
    final sign = delta > 0 ? '+' : '';
    final pct = base > 0
        ? ' (${sign}${(delta / base * 100).toStringAsFixed(1)}%)'
        : '';
    return '$sign${formatBytes(delta)}$pct';
  }

  print(
    '| **Physical Footprint** | ${formatBytes(baseSnap.physFootprintBytes)} | ${formatBytes(patchSnap.physFootprintBytes)} | ${formatDelta(fpDelta, baseSnap.physFootprintBytes)} |',
  );
  print(
    '| **Peak Footprint** | ${formatBytes(baseSnap.physFootprintPeakBytes)} | ${formatBytes(patchSnap.physFootprintPeakBytes)} | ${formatDelta(peakDelta, baseSnap.physFootprintPeakBytes)} |',
  );

  final allCategories = {
    ...baseSnap.regions.keys,
    ...patchSnap.regions.keys,
  }.toList()..sort();
  if (allCategories.isNotEmpty) {
    print('\n### Detailed Memory Regions\n');
    print('| Region / Category | Baseline | Patched | Delta |');
    print('| :--- | :--- | :--- | :--- |');
    for (final cat in allCategories) {
      final int bVal = baseSnap.regions[cat] ?? 0;
      final int pVal = patchSnap.regions[cat] ?? 0;
      final int diff = pVal - bVal;
      print(
        '| `$cat` | ${formatBytes(bVal)} | ${formatBytes(pVal)} | ${formatDelta(diff, bVal)} |',
      );
    }
  }
  print('');
}

void main(List<String> args) async {
  if (args.isEmpty || hasFlag(args, '--help') || hasFlag(args, '-h')) {
    showUsageAndExit();
  }

  final String? compareBase = getOption(args, '--compare');
  if (compareBase != null) {
    final compareIndex = args.indexOf('--compare');
    if (compareIndex + 2 < args.length) {
      final String comparePatched = args[compareIndex + 2];
      compareSnapshots(compareBase, comparePatched);
      return;
    } else {
      print(
        'Error: --compare requires two snapshot file paths: --compare <base.json> <patch.json>',
      );
      exit(1);
    }
  }

  final String? pidStr = getOption(args, '--pid');
  final String? nameStr = getOption(args, '--name');
  final String? androidTarget = getOption(args, '--android');
  final String? outputJsonPath = getOption(args, '--output');

  final int sampleCount =
      int.tryParse(getOption(args, '--samples') ?? '1') ?? 1;
  final double sampleInterval =
      double.tryParse(getOption(args, '--interval') ?? '1.0') ?? 1.0;

  int? targetPid;
  if (pidStr != null) {
    targetPid = int.tryParse(pidStr);
  } else if (nameStr != null) {
    targetPid = await resolvePidByName(nameStr);
    if (targetPid == null) {
      print('Error: Could not find running process matching "$nameStr".');
      exit(1);
    }
    print('Resolved process "$nameStr" to PID $targetPid.');
  }

  if (targetPid == null && androidTarget == null) {
    print('Error: Must specify --pid, --name, or --android.');
    showUsageAndExit();
  }

  final List<MemorySnapshot> snapshots = <MemorySnapshot>[];

  for (int i = 0; i < sampleCount; i++) {
    try {
      final MemorySnapshot snap = targetPid != null
          ? await captureMacFootprint(targetPid)
          : await captureAndroidFootprint(androidTarget!);

      snapshots.add(snap);
      print(
        '[$i/${sampleCount}] Target: ${snap.target} | Phys Footprint: ${formatBytes(snap.physFootprintBytes)} | Peak: ${formatBytes(snap.physFootprintPeakBytes)}',
      );

      if (i + 1 < sampleCount) {
        await Future<void>.delayed(
          Duration(milliseconds: (sampleInterval * 1000).round()),
        );
      }
    } catch (e) {
      print('Error sampling memory: $e');
      break;
    }
  }

  if (outputJsonPath != null && snapshots.isNotEmpty) {
    final file = File(outputJsonPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(snapshots.map((s) => s.toJson()).toList()),
    );
    print('💾 Saved ${snapshots.length} sample(s) to $outputJsonPath');
  }
}
