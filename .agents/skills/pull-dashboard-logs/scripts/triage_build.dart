// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

final List<RegExp> failurePatterns = <RegExp>[
  RegExp(
    r'FAILED TESTS \(\d+/\d+\):.*?(?=(?:SUMMARY:|\n\n\n|$))',
    dotAll: true,
  ),
  RegExp(
    r'\[ERROR:flutter/fml/backtrace\.cc\(\d+\)\].*?(?=\n\n|$)',
    dotAll: true,
  ),
  RegExp(r'Caught signal SIG\w+.*?(?=\n\n|$)', dotAll: true),
  RegExp(
    r'Traceback \(most recent call last\):.*?(?=\n[A-Z][a-zA-Z0-9_]*Error:|$)',
    dotAll: true,
  ),
  RegExp(r'FAILED:\s+.*?\n.*?(?=\n\[\d+/\d+\]|$)', dotAll: true),
  RegExp(
    r'Expected:\s+.*?\n\s+Actual:\s+.*?\n\s+Which:\s+.*?(?=\n\s*(?:package:|test\\|$))',
    dotAll: true,
  ),
  RegExp(r'╔═╡ERROR #\d+╞═+.*?(?=╚═+)', dotAll: true),
  RegExp(r'Failing tests:.*?(?=\n\n|$)', dotAll: true),
  RegExp(r'.*did not complete.*', caseSensitive: false),
];

String? getOption(List<String> args, String option) {
  final int index = args.indexOf(option);
  if (index != -1 && index + 1 < args.length) {
    return args[index + 1];
  }
  return null;
}

int runCommandToFile(List<String> cmd, String outputFile) {
  final file = File(outputFile);
  file.parent.createSync(recursive: true);
  final result = Process.runSync(
    cmd.first,
    cmd.skip(1).toList(),
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  file.writeAsStringSync('${result.stdout}${result.stderr}');
  return result.exitCode;
}

String _detectRepo() {
  try {
    final result = Process.runSync('gh', <String>[
      'repo',
      'view',
      '--json',
      'nameWithOwner',
      '--jq',
      '.nameWithOwner',
    ]);
    if (result.exitCode == 0) {
      final name = (result.stdout as String).trim();
      if (name.isNotEmpty && name.contains('/')) {
        return name;
      }
    }
  } catch (_) {}
  return 'flutter/flutter';
}

String getHeadSha(String prNumber, String repo) {
  final result = Process.runSync('gh', <String>[
    'pr',
    'view',
    prNumber,
    '-R',
    repo,
    '--json',
    'headRefOid',
    '--jq',
    '.headRefOid',
  ]);
  return (result.stdout as String).trim();
}

List<String> getFailingPresubmitBuilders(String sha, String repo) {
  final result = Process.runSync('gh', <String>[
    'api',
    'repos/$repo/commits/$sha/check-runs',
    '--jq',
    '.check_runs[] | select(.name == "Dashboard Checks") | .output.text',
  ]);
  final lines = (result.stdout as String).split('\n');
  final builders = <String>[];
  for (var line in lines) {
    line = line.trim();
    if (line.startsWith('- `') && line.endsWith('`')) {
      builders.add(line.substring(3, line.length - 1));
    }
  }
  return builders;
}

String listBuildsForSha(String sha, String outputDir) {
  final buildsFile = '$outputDir/builds_$sha.txt';
  runCommandToFile(<String>[
    'bb',
    'ls',
    '-t',
    'buildset:sha/git/$sha',
  ], buildsFile);
  return buildsFile;
}

List<Map<String, String>> parseBuildsForBuilder(
  String buildsFile,
  String builderName,
) {
  final file = File(buildsFile);
  if (!file.existsSync()) {
    return <Map<String, String>>[];
  }
  final matches = <Map<String, String>>[];
  for (final line in file.readAsLinesSync()) {
    if (line.toLowerCase().contains(builderName.toLowerCase())) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 3) {
        final url = parts[0];
        final status = parts[1];
        final name = parts[2].replaceAll("'", '');
        final buildId = url.split('/').last;
        matches.add(<String, String>{
          'id': buildId,
          'status': status,
          'name': name,
          'url': url,
        });
      }
    }
  }
  return matches;
}

String getBuildSteps(String buildId, String outputDir) {
  final stepsFile = '$outputDir/steps_$buildId.txt';
  runCommandToFile(<String>['bb', 'get', buildId, '-steps'], stepsFile);
  return stepsFile;
}

({List<String> failures, List<String> subBuilds}) findFailuresInSteps(
  String stepsFile,
) {
  final file = File(stepsFile);
  if (!file.existsSync()) {
    return (failures: <String>[], subBuilds: <String>[]);
  }
  final failures = <String>[];
  final subBuilds = <String>[];
  final subBuildRegex = RegExp(
    r'https://cr-buildbucket\.appspot\.com/build/(\d+)',
  );

  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    final match = subBuildRegex.firstMatch(trimmed);
    if (match != null &&
        (trimmed.contains('launch builds') ||
            trimmed.contains('display builds') ||
            trimmed.toLowerCase().contains('drone') ||
            trimmed.toLowerCase().contains('build failed'))) {
      final subId = match.group(1)!;
      if (!subBuilds.contains(subId)) {
        subBuilds.add(subId);
      }
    }

    if (trimmed.contains('FAILURE')) {
      final stepMatch = RegExp(r'Step "([^"]+)"').firstMatch(trimmed);
      if (stepMatch != null) {
        failures.add(stepMatch.group(1)!);
      }
    }
  }
  return (failures: failures, subBuilds: subBuilds);
}

String fetchStepLog(String buildId, String stepName, String outputDir) {
  final slug = stepName.replaceAll(RegExp(r'[^a-zA-Z0-9_]+'), '_');
  final shortSlug = slug.length > 50 ? slug.substring(0, 50) : slug;
  final logFile = '$outputDir/log_${buildId}_$shortSlug.txt';
  runCommandToFile(<String>['bb', 'log', buildId, stepName], logFile);
  return logFile;
}

String extractLogSignals(String logFile) {
  final file = File(logFile);
  if (!file.existsSync() || file.lengthSync() == 0) {
    return 'Log file empty or not found.';
  }
  final content = file.readAsStringSync();
  final signals = <String>[];

  for (final reg in failurePatterns) {
    for (final m in reg.allMatches(content)) {
      final snippet = m.group(0)?.trim() ?? '';
      final truncated = snippet.length > 2000
          ? snippet.substring(0, 2000)
          : snippet;
      if (truncated.isNotEmpty && !signals.contains(truncated)) {
        signals.add(truncated);
      }
    }
  }

  if (signals.isEmpty) {
    final lines = content.split('\n');
    final count = lines.length > 40 ? 40 : lines.length;
    signals.add(lines.sublist(lines.length - count).join('\n'));
  }

  return signals.take(3).join('\n\n---\n\n');
}

void main(List<String> args) {
  var pr = getOption(args, '--pr');
  var sha = getOption(args, '--sha');
  final build = getOption(args, '--build');
  final builder = getOption(args, '--builder');
  final repo = getOption(args, '--repo') ?? _detectRepo();
  final outputDir = getOption(args, '--output-dir') ?? '/tmp/dashboard_logs';

  Directory(outputDir).createSync(recursive: true);

  if (build == null && sha == null && pr == null) {
    stderr.writeln(
      'Error: No target specified. Please provide --pr <number>, --sha <commit_hash>, or --build <build_id>.\n'
      'Optional flags: [--builder <name>] [--repo <owner/repo>] [--output-dir <path>]',
    );
    exit(1);
  }

  if (sha == null && pr != null) {
    print('[*] Querying PR $pr on repository $repo...');
    sha = getHeadSha(pr, repo);
    print('[*] PR $pr Head SHA: $sha');
  }

  final targetBuilds = <({String builder, String id, String url})>[];

  if (build != null) {
    targetBuilds.add((
      builder: 'Target Build',
      id: build,
      url: 'https://cr-buildbucket.appspot.com/build/$build',
    ));
  } else if (sha != null) {
    final buildersToCheck = builder != null
        ? <String>[builder]
        : getFailingPresubmitBuilders(sha, repo);
    final buildsFile = listBuildsForSha(sha, outputDir);
    print('[*] Stored all build metadata in: file://$buildsFile');

    if (buildersToCheck.isNotEmpty) {
      for (final b in buildersToCheck) {
        final matches = parseBuildsForBuilder(buildsFile, b);
        for (final m in matches) {
          if (m['status'] == 'FAILURE') {
            targetBuilds.add((builder: b, id: m['id']!, url: m['url']!));
          }
        }
      }
    } else {
      print('[*] Scanning build list for all failed builds...');
      final file = File(buildsFile);
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.contains('FAILURE') || line.contains('INFRA_FAILURE')) {
            final parts = line.trim().split(RegExp(r'\s+'));
            if (parts.length >= 3) {
              final url = parts[0];
              final id = url.split('/').last;
              final name = parts[2].replaceAll("'", '');
              targetBuilds.add((builder: name, id: id, url: url));
            }
          }
        }
      }
    }
  } else {
    print(
      'Usage: dart triage_build.dart [--pr <num> | --sha <hash> | --build <id>] [--builder <name>] [--repo <owner/repo>] [--output-dir <path>]',
    );
    exit(1);
  }

  if (targetBuilds.isEmpty) {
    print('[+] No failed builds found.');
    return;
  }

  for (final item in targetBuilds) {
    print('\n=======================================================');
    print('Builder: ${item.builder}');
    print('Build ID: ${item.id} (${item.url})');
    print('=======================================================');

    final stepsFile = getBuildSteps(item.id, outputDir);
    print('[*] Steps saved to: file://$stepsFile');

    final result = findFailuresInSteps(stepsFile);

    for (final sId in result.subBuilds) {
      final sSteps = getBuildSteps(sId, outputDir);
      final sResult = findFailuresInSteps(sSteps);
      for (final sf in sResult.failures) {
        if (sf.contains('test:') ||
            sf.contains('run ') ||
            sf.contains('build ') ||
            sf.contains('compile')) {
          final logFile = fetchStepLog(sId, sf, outputDir);
          print('\n[-] Sub-build $sId Step: "$sf"');
          print('    Saved log: file://$logFile');
          final summary = extractLogSignals(logFile);
          print('    Failure Excerpt:\n$summary');
        }
      }
    }

    for (final fStep in result.failures) {
      if (fStep.contains('test:') ||
          fStep.contains('run ') ||
          fStep.contains('build ') ||
          fStep.contains('compile') ||
          fStep.contains('check')) {
        final logFile = fetchStepLog(item.id, fStep, outputDir);
        print('\n[-] Step: "$fStep"');
        print('    Saved log: file://$logFile');
        final summary = extractLogSignals(logFile);
        print('    Failure Excerpt:\n$summary');
      }
    }
  }
}
