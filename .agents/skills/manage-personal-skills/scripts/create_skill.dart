import 'dart:io';

void showUsageAndExit() {
  print(
    'Usage: dart create_skill.dart --name <skill-name> --description <description>',
  );
  print('Arguments:');
  print('  --name <skill-name>       The kebab-case name of the new skill.');
  print(
    '  --description <desc>      A short description of what the skill does.',
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

bool hasFlag(List<String> args, String flag) {
  return args.contains(flag);
}

void main(List<String> args) async {
  if (args.isEmpty || hasFlag(args, '--help') || hasFlag(args, '-h')) {
    showUsageAndExit();
  }

  final String? name = getOption(args, '--name');
  final String? description = getOption(args, '--description');

  if (name == null || description == null) {
    print('Error: Missing required arguments.');
    showUsageAndExit();
  }

  final String skillName = name!;
  final String skillDesc = description!;

  // Enforce kebab-case format
  if (!RegExp(r'^[a-z0-9\-]+$').hasMatch(skillName)) {
    print(
      'Error: Skill name must be lowercase kebab-case (e.g. "my-new-skill").',
    );
    exit(1);
  }

  final String centralRepoPath =
      '/Users/awolff/Projects/andywolff/andywolff_skills/.agents/skills';
  final String parentRepoPath = '/Users/awolff/Projects/andywolff';

  final Directory centralSkillsDir = Directory(centralRepoPath);

  if (!centralSkillsDir.existsSync()) {
    print('Error: Central skills repository not found at $centralRepoPath.');
    exit(1);
  }

  final String targetSkillPath = '$centralRepoPath/$skillName';
  final Directory targetDir = Directory(targetSkillPath);

  if (targetDir.existsSync()) {
    print(
      'Error: A skill named "$skillName" already exists in the central repository.',
    );
    exit(1);
  }

  print('📁 Creating skill directory structure: $targetSkillPath...');
  targetDir.createSync(recursive: true);
  Directory('$targetSkillPath/scripts').createSync(recursive: true);

  // Write template SKILL.md
  final File skillMdFile = File('$targetSkillPath/SKILL.md');
  final String formattedTitle = skillName
      .split('-')
      .map(
        (String word) =>
            word.isEmpty ? '' : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');

  final String skillMdContent =
      '''---
name: $skillName
description: $skillDesc
---

# $formattedTitle

Use this skill whenever you need to ...

## Step 1: Execute ...
Describe details of what this skill does and how to run it.
''';

  await skillMdFile.writeAsString(skillMdContent);
  print('📝 Generated starter template SKILL.md.');

  // Find all sibling flutter repositories/worktrees
  final Directory parentDir = Directory(parentRepoPath);
  final List<Directory> targetSkillsDirs = [];

  if (parentDir.existsSync()) {
    for (final FileSystemEntity entity in parentDir.listSync()) {
      if (entity is Directory) {
        final String name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (name == 'flutter' || name.startsWith('flutter-')) {
          final Directory targetSkillsDir = Directory('${entity.path}/.agents/skills');
          if (targetSkillsDir.existsSync()) {
            targetSkillsDirs.add(targetSkillsDir);
          }
        }
      }
    }
  }

  if (targetSkillsDirs.isEmpty) {
    print('⚠️  Warning: No flutter worktrees or repositories found under $parentRepoPath.');
  } else {
    print('\n🔗 Creating symbolic links across all detected worktrees:');
    for (final Directory targetDir in targetSkillsDirs) {
      final String symlinkPath = '${targetDir.path}/personal-$skillName';
      final Link symlink = Link(symlinkPath);

      if (symlink.existsSync()) {
        symlink.deleteSync();
      }

      symlink.createSync(targetSkillPath);
      print('   - Installed in: ${targetDir.parent.path}');
    }
  }

  print('\n✨ Custom skill "$skillName" successfully created and installed!');
  print('   - Central Path: $targetSkillPath\n');
}

