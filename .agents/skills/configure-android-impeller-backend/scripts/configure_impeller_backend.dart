import 'dart:convert';
import 'dart:io';

void showUsageAndExit() {
  print('Usage: dart configure_impeller_backend.dart --package-dir <dir> --action <set|restore> [options]');
  print('Options:');
  print('  --backend <vulkan|opengles>   Specify target Impeller backend (required for --action set)');
  print('  --backup-data <json>          Specify JSON backup string (required for --action restore)');
  exit(1);
}

String? getOption(List<String> args, String option) {
  final int index = args.indexOf(option);
  if (index != -1 && index + 1 < args.length) {
    return args[index + 1];
  }
  return null;
}

List<File> _findAllManifests(String packageDir) {
  final Directory appSrcDir = Directory('$packageDir/android/app/src');
  final Directory searchDir = appSrcDir.existsSync() ? appSrcDir : Directory('$packageDir/android');
  if (!searchDir.existsSync()) {
    return <File>[];
  }

  final List<File> manifests = <File>[];
  try {
    for (final FileSystemEntity entity in searchDir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('AndroidManifest.xml')) {
        manifests.add(entity);
      }
    }
  } catch (_) {}
  return manifests;
}

Future<String?> setAndroidImpellerBackend(String packageDir, String backend) async {
  final List<File> allManifests = _findAllManifests(packageDir);
  if (allManifests.isEmpty) {
    stderr.writeln('⚠️ No AndroidManifest.xml found in $packageDir. Skipping configuration.');
    return null;
  }

  List<File> targetFiles = allManifests.where((File file) {
    try {
      final String content = file.readAsStringSync();
      return content.contains('io.flutter.embedding.android.ImpellerBackend');
    } catch (_) {
      return false;
    }
  }).toList();

  if (targetFiles.isEmpty) {
    targetFiles = allManifests.where((File file) {
      try {
        final String content = file.readAsStringSync();
        return content.contains('<application');
      } catch (_) {
        return false;
      }
    }).toList();
  }

  if (targetFiles.isEmpty) {
    stderr.writeln('⚠️ No valid application AndroidManifest.xml found. Skipping configuration.');
    return null;
  }

  final Map<String, String> backups = <String, String>{};
  final metadataPattern = RegExp(
    r'(<meta-data\s+android:name="io\.flutter\.embedding\.android\.ImpellerBackend"\s+android:value=")[^"]*("\s*/>)',
  );
  final newMetadataTag =
      '<meta-data android:name="io.flutter.embedding.android.ImpellerBackend" android:value="$backend" />';

  for (final File file in targetFiles) {
    try {
      final String originalContent = await file.readAsString();
      backups[file.path] = originalContent;

      String modifiedContent;
      if (metadataPattern.hasMatch(originalContent)) {
        modifiedContent = originalContent.replaceAllMapped(metadataPattern, (Match match) {
          return '${match.group(1)}$backend${match.group(2)}';
        });
      } else {
        final applicationPattern = RegExp(r'(<application[^>]*>)');
        modifiedContent = originalContent.replaceFirst(
          applicationPattern,
          '\$1\n        $newMetadataTag',
        );
      }

      stderr.writeln('📝 Configuring ${file.path}: set Impeller backend to "$backend"');
      await file.writeAsString(modifiedContent);
    } catch (e) {
      stderr.writeln('⚠️ Failed to configure ${file.path}: $e');
    }
  }

  return backups.isEmpty ? null : jsonEncode(backups);
}

Future<void> restoreAndroidManifest(String packageDir, String originalContent) async {
  if (originalContent.isEmpty) {
    return;
  }
  try {
    final Map<String, dynamic> backups = jsonDecode(originalContent) as Map<String, dynamic>;
    for (final String filePath in backups.keys) {
      final File file = File(filePath);
      if (file.existsSync()) {
        stderr.writeln('📝 Restoring original manifest file: $filePath...');
        await file.writeAsString(backups[filePath] as String);
      }
    }
  } catch (e) {
    stderr.writeln('⚠️ Failed to restore manifests from backup token: $e');
  }
}

void main(List<String> args) async {
  if (args.isEmpty) {
    showUsageAndExit();
  }

  final String? packageDir = getOption(args, '--package-dir');
  final String? action = getOption(args, '--action');

  if (packageDir == null || action == null) {
    stderr.writeln('Error: Missing package-dir or action.');
    showUsageAndExit();
  }

  if (action == 'set') {
    final String? backend = getOption(args, '--backend');
    if (backend == null || (backend != 'vulkan' && backend != 'opengles')) {
      stderr.writeln('Error: --backend must be either "vulkan" or "opengles".');
      showUsageAndExit();
    }
    final String? backupToken = await setAndroidImpellerBackend(packageDir, backend);
    if (backupToken != null) {
      print(backupToken); // Print only backup token to stdout
    }
  } else if (action == 'restore') {
    final String? backupData = getOption(args, '--backup-data');
    if (backupData == null) {
      stderr.writeln('Error: Missing --backup-data.');
      showUsageAndExit();
    }
    await restoreAndroidManifest(packageDir, backupData);
  } else {
    stderr.writeln('Error: Invalid action "$action".');
    showUsageAndExit();
  }
}
