// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_print

import 'dart:io';
import 'package:path/path.dart' as path;

Future<void> main(List<String> args) async {
  // 1. Resolve the repository root:
  // Check Directory.current and ancestors, FLUTTER_ROOT, or script location.
  Directory? findFlutterRepoRoot() {
    final flutterRootEnv = Platform.environment['FLUTTER_ROOT'];
    if (flutterRootEnv != null && flutterRootEnv.isNotEmpty) {
      final dir = Directory(flutterRootEnv);
      if (File(path.join(dir.path, '.ci.yaml')).existsSync()) {
        return dir;
      }
    }

    var current = Directory.current;
    for (var i = 0; i < 6; i++) {
      if (File(path.join(current.path, '.ci.yaml')).existsSync()) {
        return current;
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }

    final scriptFile = File(Platform.script.toFilePath());
    var candidate = scriptFile.parent;
    for (var i = 0; i < 6; i++) {
      if (File(path.join(candidate.path, '.ci.yaml')).existsSync()) {
        return candidate;
      }
      final parent = candidate.parent;
      if (parent.path == candidate.path) break;
      candidate = parent;
    }

    return null;
  }

  final Directory? resolvedRepoRoot = findFlutterRepoRoot();
  if (resolvedRepoRoot == null) {
    print(
      '❌ Error: Could not locate Flutter repository root containing .ci.yaml.\n'
      '   Ensure you are running from within a Flutter checkout or set FLUTTER_ROOT.',
    );
    exit(1);
  }
  final Directory repoRoot = resolvedRepoRoot;

  // 2. Read .ci.yaml to dynamically discover the exact ktlint version tag:
  final ciYamlFile = File(path.join(repoRoot.path, '.ci.yaml'));
  if (!ciYamlFile.existsSync()) {
    print('❌ Error: .ci.yaml not found at ${ciYamlFile.path}');
    exit(1);
  }

  final String ciContent = ciYamlFile.readAsStringSync();
  final RegExpMatch? match = RegExp(
    r'"dependency":\s*"ktlint",\s*"version":\s*"([^"]+)"',
  ).firstMatch(ciContent);
  if (match == null) {
    print('❌ Error: Could not find ktlint version dependency inside .ci.yaml');
    exit(1);
  }
  final String versionTag = match.group(1)!;

  // 3. Establish the standardized ktlint cache directory:
  final cacheDir = Directory(path.join(repoRoot.path, 'tmp_ktlint'));
  final ktlintBin = File(path.join(cacheDir.path, 'ktlint'));

  // 4. Automatically download and extract the linter package if it is not cached:
  if (!ktlintBin.existsSync()) {
    print('ℹ️ Resolving ktlint version $versionTag from CIPD...');
    cacheDir.createSync(recursive: true);
    final downloadUrl =
        'https://chrome-infra-packages.appspot.com/dl/flutter/ktlint/linux-amd64/+/$versionTag';
    final zipFile = File(path.join(cacheDir.path, 'ktlint.zip'));

    print('📥 Downloading ktlint binary...');
    final ProcessResult curlResult = await Process.run('curl', <String>[
      '-L',
      '-o',
      zipFile.path,
      downloadUrl,
    ]);
    if (curlResult.exitCode != 0) {
      print('❌ Error: Failed to download package: ${curlResult.stderr}');
      exit(1);
    }

    print('📦 Extracting ktlint package...');
    final ProcessResult unzipResult = await Process.run('unzip', <String>[
      '-o',
      '-d',
      cacheDir.path,
      zipFile.path,
    ]);
    if (unzipResult.exitCode != 0) {
      print('❌ Error: Failed to extract package: ${unzipResult.stderr}');
      exit(1);
    }

    await Process.run('chmod', <String>['+x', ktlintBin.path]);
    if (zipFile.existsSync()) {
      zipFile.deleteSync();
    }
    print('✅ ktlint setup completed successfully.');
  }

  // 5. Parse downstream target configurations and custom flags:
  final processArgs = <String>[];
  final customTargets = <String>[];
  var shouldCleanup = false;

  for (final arg in args) {
    if (arg == '--cleanup') {
      shouldCleanup = true;
    } else if (arg == '-F' || arg == '--format') {
      processArgs.add('-F');
    } else {
      customTargets.add(arg);
    }
  }

  // 6. Bind baseline and editorconfigs automatically:
  final String editorConfigPath = path.join(
    repoRoot.path,
    'dev/bots/test/analyze-test-input/.editorconfig',
  );
  final String baselinePath = path.join(
    repoRoot.path,
    'dev/bots/test/analyze-test-input/ktlint-baseline.xml',
  );

  processArgs.addAll(<String>['--editorconfig=$editorConfigPath', '--baseline=$baselinePath']);

  processArgs.addAll(customTargets);

  // 7. Execute style checks:
  print('🚀 Running Kotlin style linter...');
  final ProcessResult lintResult = await Process.run(
    ktlintBin.path,
    processArgs,
    workingDirectory: repoRoot.path,
  );

  if (lintResult.stdout.toString().trim().isNotEmpty) {
    print(lintResult.stdout);
  }
  if (lintResult.stderr.toString().trim().isNotEmpty) {
    print(lintResult.stderr);
  }

  // 8. Clean up the linter cache on request:
  if (shouldCleanup) {
    print('🧹 Cleaning up local ktlint downloader cache...');
    if (cacheDir.existsSync()) {
      cacheDir.deleteSync(recursive: true);
    }
  }

  if (lintResult.exitCode == 0) {
    print('🎉 Kotlin style checks passed successfully!');
  }

  exit(lintResult.exitCode);
}
