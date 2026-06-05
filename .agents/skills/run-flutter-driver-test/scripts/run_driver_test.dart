// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_print, avoid_escaping_inner_quotes

import 'dart:async';
import 'dart:convert';
import 'dart:io';

void showUsageAndExit() {
  print('Usage: dart run_driver_test.dart [options]');
  print('Required:');
  print(
    '  --package-dir <path>             Path to package directory (e.g. dev/integration_tests/android_hardware_smoke_test)',
  );
  print(
    '  --driver <path>                  Relative path to the test driver file (e.g. test_driver/driver_test.dart)',
  );
  print(
    '  --target <path>                  Relative path to the target dart entrypoint (e.g. lib/main.dart)',
  );
  print('Optional:');
  print(
    '  --recreate-platform <platforms>  Comma-separated list of platforms to recreate before running (e.g. android or android,ios)',
  );
  print('  --update-goldens                 Set UPDATE_GOLDENS=1 env variable');
  print(
    '  --android-impeller-backend <v>   Configure Impeller backend in AndroidManifest.xml (vulkan or opengles)',
  );
  print(
    '  --no-dds                         Disable Dart Development Service (adds --no-dds)',
  );
  print('  --device-id <id>                 Specify target device ID (or -d)');
  exit(1);
}

String? getOption(List<String> args, String name) {
  final int index = args.indexOf(name);
  if (index != -1 && index + 1 < args.length) {
    return args[index + 1];
  }
  return null;
}

bool hasFlag(List<String> args, String name) {
  return args.contains(name);
}

Future<void> recreatePlatforms(
  String packageDir,
  String recreatePlatformStr,
) async {
  final List<String> platforms = recreatePlatformStr
      .split(',')
      .map((String p) => p.trim())
      .where((String p) => p.isNotEmpty)
      .toList();

  for (final platform in platforms) {
    print('🔧 Recreating platform boilerplate for: $platform...');
    final ProcessResult result = await Process.run('flutter', <String>[
      'create',
      '--platform',
      platform,
      '--no-overwrite',
      '.',
    ], workingDirectory: packageDir);
    if (result.exitCode != 0) {
      stderr.writeln(
        '❌ Failed to recreate platform "$platform":\n${result.stderr}',
      );
      exit(result.exitCode);
    }
  }
}

Future<String?> getPackageId(String packageDir) async {
  final ktsGradle = File('$packageDir/android/app/build.gradle.kts');
  if (ktsGradle.existsSync()) {
    final String content = await ktsGradle.readAsString();
    final RegExpMatch? match = RegExp(
      r'applicationId\s*=\s*"([^"]+)"',
    ).firstMatch(content);
    if (match != null) {
      return match.group(1);
    }
  }

  final groovyGradle = File('$packageDir/android/app/build.gradle');
  if (groovyGradle.existsSync()) {
    final String content = await groovyGradle.readAsString();
    final RegExpMatch? match = RegExp(
      r'''applicationId\s*(?:=\s*)?["']([^"']+)["']''',
    ).firstMatch(content);
    if (match != null) {
      return match.group(1);
    }
  }

  final manifestFile = File(
    '$packageDir/android/app/src/main/AndroidManifest.xml',
  );
  if (manifestFile.existsSync()) {
    final String content = await manifestFile.readAsString();
    final RegExpMatch? match = RegExp(r'package="([^"]+)"').firstMatch(content);
    if (match != null) {
      return match.group(1);
    }
  }

  return null;
}

Future<bool> isAppRunning(String packageId) async {
  final ProcessResult result = await Process.run('adb', <String>[
    'shell',
    'pidof',
    packageId,
  ]);
  return result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty;
}

Future<int> runTest(
  String packageDir,
  String driver,
  String target,
  bool updateGoldens,
  bool noDds,
  String? deviceId,
) async {
  final env = <String, String>{...Platform.environment};
  if (updateGoldens) {
    env['UPDATE_GOLDENS'] = '1';
    print('📸 Running test with UPDATE_GOLDENS=1 environment variable set.');
  }

  final cmdArgs = <String>[
    'drive',
    '-v',
    '--driver=$driver',
    '--target=$target',
  ];
  if (noDds) {
    cmdArgs.add('--no-dds');
  }
  if (deviceId != null) {
    cmdArgs.addAll(<String>['-d', deviceId]);
  }

  print('🚀 Running command: flutter ${cmdArgs.join(' ')} inside $packageDir');

  final Process process = await Process.start(
    'flutter',
    cmdArgs,
    workingDirectory: packageDir,
    environment: env,
  );

  final String? packageId = await getPackageId(packageDir);
  final crashPattern = RegExp(
    r'(FATAL:flutter|Check failed:|Could not create Vulkan instance|Could not create surface from invalid Android context)',
    caseSensitive: false,
  );

  var didCrash = false;
  Timer? monitoringTimer;
  Timer? warningTimeoutTimer;

  void checkSuccessLine(String line) {
    if (line.contains('Connected to Flutter application') ||
        line.contains('00:00 +0:') ||
        line.contains('setUpAll')) {
      warningTimeoutTimer?.cancel();
      warningTimeoutTimer = null;
    }
  }

  if (packageId != null) {
    var hasStarted = false;
    var consecutiveDeadTicks = 0;

    monitoringTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final bool running = await isAppRunning(packageId);
      if (running) {
        hasStarted = true;
        consecutiveDeadTicks = 0;
      } else if (hasStarted) {
        consecutiveDeadTicks++;
        // If the app process has been dead for 3 consecutive checks (6 seconds)
        // while the flutter drive process is still active, it has crashed/hung.
        if (consecutiveDeadTicks >= 3 && !didCrash) {
          didCrash = true;
          stderr.writeln(
            '\n❌ [Proactive Crash Detection] The application process "$packageId" is no longer running on the device.',
          );
          stderr.writeln(
            '❌ Terminating execution early to prevent infinite connection hang...\n',
          );
          process.kill();
          timer.cancel();
        }
      }
    });
  }

  final StreamSubscription<String> stdoutSubscription = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) {
        print(line);
        checkSuccessLine(line);

        if (line.contains(
          'It is taking an unusually long time to connect to the VM',
        )) {
          warningTimeoutTimer ??= Timer(const Duration(seconds: 8), () {
            if (!didCrash) {
              didCrash = true;
              stderr.writeln(
                '\n❌ [Proactive Hang Detection] VM Service connection has timed out (failed to connect within 8 seconds of warnings).',
              );
              stderr.writeln(
                '❌ Terminating execution early to prevent infinite connection hang...\n',
              );
              process.kill();
            }
          });
        }

        if (crashPattern.hasMatch(line) && !didCrash) {
          didCrash = true;
          stderr.writeln(
            '\n❌ [Proactive Crash Detection] Detected fatal engine crash signature.',
          );
          stderr.writeln(
            '❌ Terminating execution early to prevent infinite connection hang...\n',
          );
          process.kill();
        }
      });

  final StreamSubscription<String> stderrSubscription = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) {
        stderr.writeln(line);
        checkSuccessLine(line);
        if (crashPattern.hasMatch(line) && !didCrash) {
          didCrash = true;
          stderr.writeln(
            '\n❌ [Proactive Crash Detection] Detected fatal engine crash signature.',
          );
          stderr.writeln(
            '❌ Terminating execution early to prevent infinite connection hang...\n',
          );
          process.kill();
        }
      });

  await Future.wait<void>(<Future<void>>[
    stdoutSubscription.asFuture(),
    stderrSubscription.asFuture(),
  ]);

  monitoringTimer?.cancel();
  warningTimeoutTimer?.cancel();
  await stdoutSubscription.cancel();
  await stderrSubscription.cancel();

  final int exitCode = await process.exitCode;
  return didCrash ? 1 : exitCode;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || hasFlag(args, '--help') || hasFlag(args, '-h')) {
    showUsageAndExit();
  }

  final String? parsedPackageDir = getOption(args, '--package-dir');
  final String? parsedDriver = getOption(args, '--driver');
  final String? parsedTarget = getOption(args, '--target');

  if (parsedPackageDir == null ||
      parsedDriver == null ||
      parsedTarget == null) {
    print('Error: Missing required arguments.');
    showUsageAndExit();
  }

  final String packageDir = parsedPackageDir!;
  final String driver = parsedDriver!;
  final String target = parsedTarget!;

  try {
    final String scriptPath = await File(
      Platform.script.toFilePath(),
    ).resolveSymbolicLinks();
    final Directory scriptDir = File(scriptPath).parent;
    final String diagnosticsScript =
        '${scriptDir.parent.parent.path}/diagnose-android-device/scripts/device_diagnostics.dart';

    if (File(diagnosticsScript).existsSync()) {
      final ProcessResult result = await Process.run('dart', <String>[
        diagnosticsScript,
      ]);
      stdout.write(result.stdout);
      stderr.write(result.stderr);
    } else {
      print(
        'Warning: Sibling diagnostics script not found at $diagnosticsScript',
      );
    }
  } catch (e) {
    print('Warning: Could not execute pre-flight device diagnostics: $e');
  }

  final String? recreatePlatform = getOption(args, '--recreate-platform');
  final bool updateGoldens = hasFlag(args, '--update-goldens');
  final String? backend = getOption(args, '--android-impeller-backend');
  final bool noDds = hasFlag(args, '--no-dds');
  final String? deviceId =
      getOption(args, '--device-id') ?? getOption(args, '-d');

  if (backend != null && backend != 'vulkan' && backend != 'opengles') {
    print('Error: Android Impeller backend must be either vulkan or opengles.');
    showUsageAndExit();
  }

  if (recreatePlatform != null) {
    await recreatePlatforms(packageDir, recreatePlatform);
  }

  String? originalManifest;
  if (backend != null) {
    try {
      final String scriptPath = await File(
        Platform.script.toFilePath(),
      ).resolveSymbolicLinks();
      final Directory scriptDir = File(scriptPath).parent;
      final String configScript =
          '${scriptDir.parent.parent.path}/manage-android-impeller-backend/scripts/manage_impeller_backend.dart';

      if (File(configScript).existsSync()) {
        final ProcessResult result = await Process.run('dart', <String>[
          configScript,
          '--package-dir',
          packageDir,
          '--action',
          'set',
          '--backend',
          backend,
        ]);
        stderr.write(result.stderr);
        final String output = result.stdout.toString().trim();
        if (output.isNotEmpty) {
          originalManifest = output;
        }
      } else {
        print('Error: Sibling configuration script not found at $configScript');
        exit(1);
      }
    } catch (e) {
      print('Error configuring backend: $e');
      exit(1);
    }
  }

  var exitCode = 1;
  try {
    exitCode = await runTest(
      packageDir,
      driver,
      target,
      updateGoldens,
      noDds,
      deviceId,
    );
  } finally {
    if (originalManifest != null) {
      try {
        final String scriptPath = await File(
          Platform.script.toFilePath(),
        ).resolveSymbolicLinks();
        final Directory scriptDir = File(scriptPath).parent;
        final String configScript =
            '${scriptDir.parent.parent.path}/manage-android-impeller-backend/scripts/manage_impeller_backend.dart';
        final ProcessResult result = await Process.run('dart', <String>[
          configScript,
          '--package-dir',
          packageDir,
          '--action',
          'restore',
          '--backup-data',
          originalManifest,
        ]);
        stderr.write(result.stderr);
      } catch (e) {
        print('Error restoring manifest: $e');
      }
    }
    final String? packageId = await getPackageId(packageDir);
    if (packageId != null) {
      print('🧹 Cleaning up device state: force-stopping app "$packageId"...');
      await Process.run('adb', <String>[
        'shell',
        'am',
        'force-stop',
        packageId,
      ]);
    }
  }

  exit(exitCode);
}
