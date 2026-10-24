import 'dart:io';

void main(List<String> args) async {
  final outDir = _findOutDirectory();
  if (outDir == null) {
    stderr.writeln('Error: Could not locate engine output directory (engine/src/out).');
    exit(1);
  }

  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    _printUsage(outDir.path);
    exit(1);
  }

  if (args.contains('--list') || args.contains('-l')) {
    _listVariants(outDir);
    exit(0);
  }

  final variantName = args[0];
  final sourceDir = _findSourceDirectory(outDir, args.length > 1 ? args[1] : null);

  if (sourceDir == null || !sourceDir.existsSync()) {
    stderr.writeln('Error: Source engine directory does not exist in ${outDir.path}.');
    stderr.writeln('Build the engine first (e.g. et build -c host_debug).');
    exit(1);
  }

  final sourceName = sourceDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  final targetName = '${sourceName}_$variantName';
  final targetDir = Directory('${outDir.path}/$targetName');

  stdout.writeln('📦 Snapshotting engine variant: $sourceName -> $targetName...');
  if (targetDir.existsSync()) {
    targetDir.deleteSync(recursive: true);
  }

  await _copyDirectory(sourceDir, targetDir);
  stdout.writeln('✅ Snapshot created at: ${targetDir.path}');
}

void _printUsage(String outPath) {
  stdout.writeln('Usage: dart snapshot_variant.dart <variant_name> [source_dir] | --list');
  stdout.writeln('');
  stdout.writeln('Examples:');
  stdout.writeln('  dart snapshot_variant.dart full_fix');
  stdout.writeln('  dart snapshot_variant.dart baseline');
  stdout.writeln('  dart snapshot_variant.dart ablated');
  stdout.writeln('  dart snapshot_variant.dart --list');
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

Directory? _findSourceDirectory(Directory outDir, String? specified) {
  if (specified != null && specified.isNotEmpty) {
    final dir = Directory('${outDir.path}/$specified');
    if (dir.existsSync()) {
      return dir;
    }
  }

  final candidates = ['host_debug_unopt_arm64', 'host_debug', 'host_release'];
  for (final name in candidates) {
    final dir = Directory('${outDir.path}/$name');
    if (dir.existsSync()) {
      return dir;
    }
  }
  return null;
}

Directory? _findOutDirectory() {
  var current = Directory.current;
  for (var i = 0; i < 5; i++) {
    final candidate = Directory('${current.path}/engine/src/out');
    if (candidate.existsSync()) {
      return candidate;
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }

  const hardcodedPaths = [
    '/Users/awolff/Projects/andywolff/flutter-corners/engine/src/out',
    '/Users/awolff/Projects/andywolff/flutter/engine/src/out',
  ];
  for (final path in hardcodedPaths) {
    final dir = Directory(path);
    if (dir.existsSync()) {
      return dir;
    }
  }

  return null;
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  if (Platform.isMacOS) {
    await destination.parent.create(recursive: true);
    final result = await Process.run('cp', ['-cR', source.path, destination.path]);
    if (result.exitCode == 0) {
      return;
    }
  }

  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: false, followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final newPath = '${destination.path}/$name';
    if (entity is Link) {
      final target = await entity.target();
      await Link(newPath).create(target);
    } else if (entity is Directory) {
      await _copyDirectory(entity, Directory(newPath));
    } else if (entity is File) {
      await entity.copy(newPath);
    }
  }
}
