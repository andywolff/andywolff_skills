import 'dart:convert';
import 'dart:io';

const Map<String, String> builders = <String, String>{
  'Linux_android_emu_vulkan_stable_android_hardware_smoke_vulkan_tests': 'Vulkan Host-Driven (Linux_android_emu_vulkan_stable android_hardware_smoke_vulkan_tests)',
  'Linux_android_emu_android_hardware_smoke_opengles_tests': 'OpenGLES Host-Driven (Linux_android_emu android_hardware_smoke_opengles_tests)',
  'Linux_android_emu_vulkan_stable_android_hardware_smoke_vulkan_instrumented_tests': 'Vulkan Instrumented (Linux_android_emu_vulkan_stable android_hardware_smoke_vulkan_instrumented_tests)',
  'Linux_android_emu_android_hardware_smoke_opengles_instrumented_tests': 'OpenGLES Instrumented (Linux_android_emu android_hardware_smoke_opengles_instrumented_tests)',
};

const Map<String, String> environments = <String, String>{
  'staging': 'Staging (Bringup / Shadow)',
  'prod': 'Prod (Post-Submit / Mainline)',
  'try': 'Try (Pre-Submit / Pull Request)',
};

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart analyze_flakiness.dart <output_report.md>');
    exit(1);
  }

  // Check if 'bb' CLI is installed before starting
  if (!isCommandAvailable('bb')) {
    stderr.writeln("Error: 'bb' CLI tool is not installed or not in PATH.");
    exit(1);
  }

  final String outReportPath = args[0];
  final reportMd = <String>[
    '# Flakiness Analysis and Baseline Report',
    'This report presents the historical success rates and failure patterns for',
    'the `android_hardware_smoke_test` shards across all environments (**Staging**,',
    '`Prod`, and `Try`). The analysis spans the last 100 valid runs per builder',
    'in each environment, ignoring the fixed AGP migration failures.\n',
    '## Executive Summary',
    'The following table summarizes the success rates for all builders across',
    'the environments:\n',
    '| Environment | Shard | Success Rate | Failures | AGP Ignored | Notes / Warnings |',
    '| --- | --- | --- | --- | --- | --- |',
  ];

  final summaryRows = <List<dynamic>>[];
  final detailedReports = <String>[];

  for (final envCode in environments.keys) {
    final envName = environments[envCode]!;
    detailedReports.add('# Environment: $envName\n');

    for (final builderCode in builders.keys) {
      final builderTitle = builders[builderCode]!;
      final builderQueryName = getBuilderQueryName(builderCode);

      print('Querying $envName / $builderQueryName...');

      final runs = fetchBuilds(envCode, builderQueryName);
      if (runs.isEmpty) continue;

      final validRuns = <Map<String, dynamic>>[];
      final failures = <Map<String, dynamic>>[];
      final failureSummaries = <String>[];
      int ignoredAgpCount = 0;

      for (final run in runs) {
        if (validRuns.length >= 100) break;

        final status = run['status'] as String?;
        final buildId = run['id'] as String?;

        if (status == 'SUCCESS') {
          validRuns.add(run);
          continue;
        }

        if (status == 'STARTED' || status == 'SCHEDULED') {
          continue;
        }

        final summary = getBuildSummary(buildId);

        if (isAgpFailure(summary)) {
          ignoredAgpCount++;
          continue;
        }

        validRuns.add(run);
        failures.add(run);
        failureSummaries.add(summary);
      }

      final totalValid = validRuns.length;
      final successCount = validRuns
          .where((r) => r['status'] == 'SUCCESS')
          .length;
      final successRate = totalValid > 0
          ? (successCount / totalValid * 100)
          : 0.0;

      String timeWindowStr = 'N/A';
      String? latestTimeStr;
      if (validRuns.isNotEmpty) {
        latestTimeStr = validRuns.first['createTime'] as String?;
        final latestTime = formatTime(latestTimeStr);
        final earliestTime = formatTime(
          validRuns.last['createTime'] as String?,
        );
        timeWindowStr = '**$earliestTime** to **$latestTime**';
      }

      String warningNote = '';
      if (envCode == 'staging' && isOldBuild(latestTimeStr)) {
        warningNote = '⚠️ **Warning**: Staging results are outdated (>7 days). Shard has likely been promoted out of bringup (removed `bringup: true` from `.ci.yaml`).';
      }

      summaryRows.add([
        envName,
        builderTitle,
        '`${successRate.toStringAsFixed(2)}%`',
        failures.length,
        ignoredAgpCount,
        warningNote.isNotEmpty ? warningNote : 'None',
      ]);

      detailedReports.addAll([
        '## $builderTitle',
        '- **Time Window**: $timeWindowStr',
        '- **Success Rate**: `${successRate.toStringAsFixed(2)}%` (Successes: $successCount, Failures: ${failures.length})',
        '- **AGP Migration Failures Ignored**: $ignoredAgpCount',
        if (warningNote.isNotEmpty) '- **Note**: $warningNote',
        '',
      ]);

      if (failures.isNotEmpty) {
        detailedReports.addAll([
          '### Failure Details',
          '| Build # | Build ID | Date & Time (UTC) | Status | Failure Category / Key Error |',
          '| --- | --- | --- | --- | --- |',
        ]);

        for (int i = 0; i < failures.length; i++) {
          final run = failures[i];
          final summary = failureSummaries[i];
          final buildId = run['id'] as String?;
          final buildNumber = run['number']?.toString();
          final status = run['status'] as String?;
          final createTime = formatTime(run['createTime'] as String?);
          final category = categorizeFailure(status, summary);

          final buildLink =
              '[$buildNumber](https://ci.chromium.org/b/$buildId)';
          detailedReports.add(
            '| $buildLink | `$buildId` | $createTime | `$status` | $category |',
          );
        }
        detailedReports.add('');
      } else {
        detailedReports.add('No non-AGP failures found in this run window.\n');
      }
    }
    detailedReports.add('\n---\n');
  }

  for (final row in summaryRows) {
    reportMd.add(
      '| ${row[0]} | ${row[1]} | ${row[2]} | ${row[3]} | ${row[4]} | ${row[5]} |',
    );
  }

  reportMd.add('\n---\n');
  reportMd.addAll(detailedReports);

  final outFile = File(outReportPath);
  outFile.writeAsStringSync(reportMd.join('\n'));
  print('Report successfully written to $outReportPath');
}

/// Checks if a CLI command is available on the system PATH.
bool isCommandAvailable(String command) {
  try {
    final result = Platform.isWindows
        ? Process.runSync('where', [command])
        : Process.runSync('which', [command]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Converts a builder code name to its queryable representation (e.g. replacing underscores).
String getBuilderQueryName(String builderCode) {
  final displayName = builderCode.replaceAll('_', ' ');
  final parts = displayName.split(' ');
  if (parts.length <= 1) return displayName;
  return '${parts[0]} ${parts.sublist(1).join(' ')}';
}

/// Formats UTC timestamp strings into a clean representation.
String formatTime(String? tStr) {
  if (tStr == null || tStr.isEmpty) return 'N/A';
  try {
    final parts = tStr.split('.');
    final base = parts[0].replaceAll('T', ' ');
    return '$base UTC';
  } catch (_) {
    return tStr;
  }
}

/// Determines if a build is older than 7 days.
bool isOldBuild(String? tStr) {
  if (tStr == null || tStr.isEmpty) return false;
  try {
    final parts = tStr.split('.');
    final base = parts[0].replaceAll('Z', '');
    final dt = DateTime.parse(base).toUtc();
    final now = DateTime.now().toUtc();
    final diff = now.difference(dt);
    return diff.inDays > 7;
  } catch (_) {
    return false;
  }
}

/// Queries Buildbucket for the last 150 builds of the specified builder.
List<Map<String, dynamic>> fetchBuilds(
  String envCode,
  String builderQueryName,
) {
  try {
    final result = Process.runSync('bb', [
      'ls',
      '-n',
      '150',
      '-json',
      'flutter/$envCode/$builderQueryName',
    ]);
    if (result.exitCode != 0) return [];

    final runs = <Map<String, dynamic>>[];
    for (final line in (result.stdout as String).split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        runs.add(jsonDecode(trimmed) as Map<String, dynamic>);
      } catch (_) {
        // Skip malformed lines
      }
    }

    // Sort descending by build number
    runs.sort((a, b) {
      final numA = int.tryParse(a['number']?.toString() ?? '0') ?? 0;
      final numB = int.tryParse(b['number']?.toString() ?? '0') ?? 0;
      return numB.compareTo(numA);
    });

    return runs;
  } catch (_) {
    return [];
  }
}

/// Retrieves the detailed build summary for a build ID.
String getBuildSummary(String? buildId) {
  if (buildId == null || buildId.isEmpty) return '';
  try {
    final result = Process.runSync('bb', ['get', buildId, '-json']);
    if (result.exitCode != 0) return '';

    final detail = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return detail['summaryMarkdown']?.toString() ?? '';
  } catch (_) {
    return '';
  }
}

/// Filters out AGP-migration compile failures.
bool isAgpFailure(String summary) {
  return summary.contains('Script compilation errors') ||
      summary.contains('BaseAppModuleExtension') ||
      summary.contains('android.newDsl=true') ||
      summary.contains('var jvmTarget: String') ||
      summary.contains('kotlinOptions');
}

/// Categorizes a build failure based on its status and summary.
String categorizeFailure(String? status, String summary) {
  if (summary.contains('download dependencies') ||
      summary.contains('download dependencies (2)')) {
    return 'Infrastructure Failure (Dependency Download)';
  }
  if (status == 'CANCELED') {
    return 'Canceled (Timeout/Infra)';
  }
  if (status == 'INFRA_FAILURE') {
    return 'Infrastructure Failure';
  }
  if (summary.contains('gradlew :app:connectedDebugAndroidTest')) {
    if (summary.contains('Test failed') || summary.contains('exit code 1')) {
      return 'JUnit Test Failure (On-device)';
    }
    return 'Gradle Instrumentation Execution Failure';
  }
  if (summary.contains('Failing tests:')) {
    final tests = <String>[];
    for (final line in summary.split('\n')) {
      if (line.trim().startsWith('.:')) {
        tests.add(line.replaceFirst('.:', '').trim());
      }
    }
    if (tests.isNotEmpty) {
      return 'Host Driver Test Failure (${tests.join(', ')})';
    }
    return 'Host Driver Test Failure';
  }
  if (summary.contains('result-state.json: No result file found')) {
    return 'Host Driver Test Failure (No result file)';
  }
  if (summary.contains('exit code 1')) {
    return 'Command Exit Code 1';
  }
  return 'Other/Unknown Failure';
}
