import 'dart:io';

void main(List<String> args) async {
  final outDir = _findOutDirectory();
  if (outDir == null) {
    stderr.writeln('Error: Could not locate engine output directory (engine/src/out).');
    exit(1);
  }

  if (args.length < 2 || args.contains('--help') || args.contains('-h')) {
    _printUsage(outDir.path);
    exit(1);
  }

  final variantArg = args[0];
  final targetApp = args[1];
  final extraArgs = args.sublist(2);

  final engineVariant = _resolveEngineVariant(outDir, variantArg);
  if (engineVariant == null) {
    stderr.writeln('Error: Engine variant "$variantArg" does not exist in ${outDir.path}.');
    _listVariants(outDir);
    exit(1);
  }

  stdout.writeln('🚀 Launching $targetApp using local engine variant: $engineVariant...');

  final processArgs = [
    'run',
    '-d',
    'macos',
    '-t',
    targetApp,
    '--local-engine-src-path=${outDir.parent.path}',
    '--local-engine=$engineVariant',
    '--local-engine-host=$engineVariant',
    ...extraArgs,
  ];

  String flutterBin = 'flutter';
  final repoFlutter = File('${outDir.parent.parent.parent.path}/bin/flutter');
  if (repoFlutter.existsSync()) {
    flutterBin = repoFlutter.path;
  }

  final process = await Process.start(flutterBin, processArgs, mode: ProcessStartMode.inheritStdio);

  final exitCode = await process.exitCode;
  exit(exitCode);
}

void _printUsage(String outPath) {
  stdout.writeln(
    'Usage: dart run_app_variant.dart <variant_name> <target_dart_file> [extra flutter run args...]',
  );
  stdout.writeln('');
  stdout.writeln('Examples:');
  stdout.writeln('  dart run_app_variant.dart full_fix repro/main.dart');
  stdout.writeln(
    '  dart run_app_variant.dart baseline repro/main.dart --dart-define=CAPTURE_PATH=/tmp/baseline.png',
  );
  stdout.writeln('  dart run_app_variant.dart host_debug_ablated repro/main.dart');
  stdout.writeln('');
  stdout.writeln('Output Directory: $outPath');
}

void _listVariants(Directory outDir) {
  stdout.writeln('Available engine build variants in ${outDir.path}:');
  final entries =
      outDir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .where((name) => name.startsWith('host_'))
          .toList()
        ..sort();

  for (final name in entries) {
    stdout.writeln('  - $name');
  }
}

String? _resolveEngineVariant(Directory outDir, String variant) {
  if (Directory('${outDir.path}/$variant').existsSync()) {
    return variant;
  }
  if (Directory('${outDir.path}/host_debug_unopt_arm64_$variant').existsSync()) {
    return 'host_debug_unopt_arm64_$variant';
  }
  if (Directory('${outDir.path}/host_debug_$variant').existsSync()) {
    return 'host_debug_$variant';
  }
  if (Directory('${outDir.path}/host_release_$variant').existsSync()) {
    return 'host_release_$variant';
  }
  return null;
}

Directory? _findOutDirectory() {
  final envOut = Platform.environment['FLUTTER_ENGINE_OUT'] ?? Platform.environment['ENGINE_OUT'];
  if (envOut != null && envOut.isNotEmpty) {
    final dir = Directory(envOut);
    if (dir.existsSync()) {
      return dir;
    }
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final candidate = Directory('$flutterRoot/engine/src/out');
    if (candidate.existsSync()) {
      return candidate;
    }
  }

  var current = Directory.current;
  for (var i = 0; i < 5; i++) {
    final candidate = Directory('${current.path}/engine/src/out');
    if (candidate.existsSync()) {
      return candidate;
    }
    final directOut = Directory('${current.path}/out');
    if (directOut.existsSync() && current.path.endsWith('engine/src')) {
      return directOut;
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }

  // Check relative to the script location
  var scriptDir = File(Platform.script.toFilePath()).parent;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${scriptDir.path}/engine/src/out');
    if (candidate.existsSync()) {
      return candidate;
    }
    final parent = scriptDir.parent;
    if (parent.path == scriptDir.path) break;
    scriptDir = parent;
  }

  return null;
}
