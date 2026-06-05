import 'dart:convert';
import 'dart:io';

void showUsageAndExit() {
  print(
    'Usage: dart manage_impeller_backend.dart --package-dir <dir> --action <detect|set|restore> [options]',
  );
  print('Options:');
  print(
    '  --backend <vulkan|opengles>   Specify target Impeller backend (required for --action set)',
  );
  print(
    '  --backup-data <json>          Specify JSON backup string (required for --action restore)',
  );
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
  final Directory searchDir = appSrcDir.existsSync()
      ? appSrcDir
      : Directory('$packageDir/android');
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

Future<void> detectAndroidImpellerBackend(String packageDir) async {
  final List<File> allManifests = _findAllManifests(packageDir);
  if (allManifests.isEmpty) {
    print('🔍 No AndroidManifest.xml files found in $packageDir.');
    return;
  }

  final metadataPattern = RegExp(
    r'io\.flutter\.embedding\.android\.ImpellerBackend"\s+android:value="([^"]+)"',
  );

  // Find the base/main manifest value
  String baseBackend = 'defaults to vulkan';
  for (final File file in allManifests) {
    if (file.path.contains('/main/AndroidManifest.xml') ||
        file.path.contains('\\main\\AndroidManifest.xml')) {
      try {
        final String content = await file.readAsString();
        final RegExpMatch? match = metadataPattern.firstMatch(content);
        if (match != null) {
          baseBackend = match.group(1)!;
        }
      } catch (_) {}
      break;
    }
  }

  print('\n🔍 Detected Android Impeller Backend Configurations:');

  for (final File file in allManifests) {
    try {
      final String content = await file.readAsString();
      final String relativePath = file.path.replaceFirst('$packageDir/', '');

      String variant = 'unknown';
      final List<String> segments = file.path.split(Platform.pathSeparator);
      final int srcIndex = segments.lastIndexOf('src');
      if (srcIndex != -1 && srcIndex + 1 < segments.length) {
        variant = segments[srcIndex + 1];
      }

      final bool isMain = variant == 'main';
      final RegExpMatch? match = metadataPattern.firstMatch(content);

      if (match != null) {
        if (isMain) {
          print(
            '   - main ($relativePath): ${match.group(1)} [Base Configuration]',
          );
        } else {
          print(
            '   - $variant ($relativePath): ${match.group(1)} [Explicit Override]',
          );
        }
      } else {
        if (isMain) {
          print(
            '   - main ($relativePath): Not configured (defaults to vulkan) [Base Configuration]',
          );
        } else {
          print(
            '   - $variant ($relativePath): Inherited from main (value: $baseBackend)',
          );
        }
      }
    } catch (e) {
      print('   - Error reading ${file.path}: $e');
    }
  }
  print('');
}

Future<String?> setAndroidImpellerBackend(
  String packageDir,
  String backend,
) async {
  final List<File> allManifests = _findAllManifests(packageDir);
  if (allManifests.isEmpty) {
    stderr.writeln(
      '⚠️ No AndroidManifest.xml found in $packageDir. Skipping configuration.',
    );
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
    stderr.writeln(
      '⚠️ No valid application AndroidManifest.xml found. Skipping configuration.',
    );
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
        modifiedContent = originalContent.replaceAllMapped(metadataPattern, (
          Match match,
        ) {
          return '${match.group(1)}$backend${match.group(2)}';
        });
      } else {
        final applicationPattern = RegExp(r'(<application[^>]*>)');
        modifiedContent = originalContent.replaceFirst(
          applicationPattern,
          '\$1\n        $newMetadataTag',
        );
      }

      stderr.writeln(
        '📝 Configuring ${file.path}: set Impeller backend to "$backend"',
      );
      await file.writeAsString(modifiedContent);
    } catch (e) {
      stderr.writeln('⚠️ Failed to configure ${file.path}: $e');
    }
  }

  return backups.isEmpty ? null : jsonEncode(backups);
}

Future<void> restoreAndroidManifest(
  String packageDir,
  String originalContent,
) async {
  if (originalContent.isEmpty) {
    return;
  }
  try {
    final Map<String, dynamic> backups =
        jsonDecode(originalContent) as Map<String, dynamic>;
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

  final String? parsedPackageDir = getOption(args, '--package-dir');
  final String? parsedAction = getOption(args, '--action');

  if (parsedPackageDir == null || parsedAction == null) {
    stderr.writeln('Error: Missing package-dir or action.');
    showUsageAndExit();
  }

  final String packageDir = parsedPackageDir!;
  final String action = parsedAction!;

  if (action == 'detect') {
    await detectAndroidImpellerBackend(packageDir);
  } else if (action == 'set') {
    final String? parsedBackend = getOption(args, '--backend');
    if (parsedBackend == null ||
        (parsedBackend != 'vulkan' && parsedBackend != 'opengles')) {
      stderr.writeln('Error: --backend must be either "vulkan" or "opengles".');
      showUsageAndExit();
    }
    final String backend = parsedBackend!;
    final String? backupToken = await setAndroidImpellerBackend(
      packageDir,
      backend,
    );
    if (backupToken != null) {
      print(backupToken); // Print only backup token to stdout
    }
  } else if (action == 'restore') {
    final String? parsedBackupData = getOption(args, '--backup-data');
    if (parsedBackupData == null) {
      stderr.writeln('Error: Missing --backup-data.');
      showUsageAndExit();
    }
    final String backupData = parsedBackupData!;
    await restoreAndroidManifest(packageDir, backupData);
  } else {
    stderr.writeln('Error: Invalid action "$action".');
    showUsageAndExit();
  }
}
