import 'dart:convert';
import 'dart:io';

import '../lib/workspace_utils.dart';

void _expect(bool condition, String message) {
  if (!condition) {
    throw AssertionError('FAILED: $message');
  }
}

Future<void> main() async {
  var passed = 0;

  void test(String name, void Function() body) {
    body();
    passed++;
    stdout.writeln('  PASS: $name');
  }

  Future<void> asyncTest(String name, Future<void> Function() body) async {
    await body();
    passed++;
    stdout.writeln('  PASS: $name');
  }

  stdout.writeln('Running flutter-engine-build unit tests...');

  test('classifyLiveness handles all four liveness classes', () {
    final now = DateTime.utc(2026, 11, 24, 20, 0);

    _expect(
      classifyLiveness(
            lease: LeaseInfo(
              sessionId: 's1',
              state: 'idle',
              lastHeartbeat: now.subtract(const Duration(hours: 3)),
            ),
            hasLiveBuildPid: true,
            hasOpenSession: false,
            hasActiveSessionInventory: true,
            idleMinutes: 60,
            now: now,
          ) ==
          LivenessClass.hardActive,
      'Live build PID must always be hardActive',
    );

    _expect(
      classifyLiveness(
            lease: LeaseInfo(
              sessionId: 's1',
              state: 'busy',
              lastHeartbeat: now.subtract(const Duration(minutes: 20)),
            ),
            hasLiveBuildPid: false,
            hasOpenSession: true,
            hasActiveSessionInventory: true,
            idleMinutes: 60,
            now: now,
          ) ==
          LivenessClass.hardActive,
      'Busy heartbeat within 60m must be hardActive',
    );

    _expect(
      classifyLiveness(
            lease: LeaseInfo(
              sessionId: 's1',
              state: 'released',
              lastHeartbeat: now.subtract(const Duration(minutes: 5)),
            ),
            hasLiveBuildPid: false,
            hasOpenSession: true,
            hasActiveSessionInventory: true,
            idleMinutes: 60,
            now: now,
          ) ==
          LivenessClass.released,
      'Released state must override idle window',
    );

    _expect(
      classifyLiveness(
            lease: LeaseInfo(
              sessionId: 's1',
              state: 'idle',
              lastHeartbeat: now.subtract(const Duration(minutes: 90)),
            ),
            hasLiveBuildPid: false,
            hasOpenSession: true,
            hasActiveSessionInventory: true,
            idleMinutes: 60,
            now: now,
          ) ==
          LivenessClass.softActive,
      'Open session beyond 60m must be softActive',
    );

    _expect(
      classifyLiveness(
            lease: LeaseInfo(
              sessionId: 's1',
              state: 'idle',
              lastHeartbeat: now.subtract(const Duration(minutes: 90)),
            ),
            hasLiveBuildPid: false,
            hasOpenSession: false,
            hasActiveSessionInventory: true,
            idleMinutes: 60,
            now: now,
          ) ==
          LivenessClass.inactive,
      'Closed session beyond 60m must be inactive',
    );
  });

  test('parseGclientEntries strips CIPD suffixes and skips root dot', () {
    const sample = '''
entries = {
  '.': 'https://github.com/flutter/flutter.git',
  'engine/src/flutter/prebuilts/linux-x64/dart-sdk:flutter/dart-sdk/linux-amd64': 'https://example.com',
  'engine/src/flutter/third_party/skia': 'https://skia.googlesource.com/skia.git@abc',
}
''';
    final parsed = parseGclientEntries(sample);
    _expect(!parsed.contains('.'), 'Root dot should be excluded');
    _expect(
      parsed.contains('engine/src/flutter/prebuilts/linux-x64/dart-sdk'),
      'CIPD suffix should be stripped',
    );
    _expect(
      parsed.contains('engine/src/flutter/third_party/skia'),
      'Git entry should be preserved',
    );
  });

  test('LeaseInfo round-trips sessionId and legacy conversationId', () {
    final legacy = LeaseInfo.fromJson(const <String, dynamic>{
      'conversationId': 'legacy-123',
      'branch': 'main',
      'state': 'busy',
    });
    _expect(legacy.sessionId == 'legacy-123', 'Legacy conversationId parsed');
    final encoded = legacy.toJson();
    _expect(encoded['sessionId'] == 'legacy-123', 'Serialized as sessionId');
  });

  test('atomicWriteJson writes valid JSON without leaving temp files', () {
    final tmp = Directory.systemTemp.createTempSync('atomic_json_test_');
    try {
      final target = File('${tmp.path}/agent_session.json');
      atomicWriteJson(target, const <String, dynamic>{'state': 'busy'});
      final readBack = readJsonMap(target.path);
      _expect(readBack?['state'] == 'busy', 'Read back written JSON');
      final entries = tmp.listSync();
      _expect(entries.length == 1, 'No leftover .tmp files');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  await asyncTest('session_hook.dart obeys PostToolUse, Stop, PreInvocation, PreToolUse contracts', () async {
    final tmp = Directory.systemTemp.createTempSync('session_hook_test_');
    try {
      final wt = Directory('${tmp.path}/feature-a');
      Directory('${wt.path}/engine/src/flutter').createSync(recursive: true);
      Directory('${wt.path}/.git').createSync(recursive: true);
      File('${wt.path}/.git/HEAD').writeAsStringSync('ref: refs/heads/feature-a\n');

      final scriptPath = File(
        '${File(Platform.script.toFilePath()).parent.parent.path}/session_hook.dart',
      ).resolveSymbolicLinksSync();

      Future<Map<String, dynamic>> runHook(
        String mode,
        Map<String, dynamic> payload,
      ) async {
        final proc = await Process.start(Platform.resolvedExecutable, <String>[
          scriptPath,
          mode,
        ]);
        proc.stdin.writeln(jsonEncode(payload));
        await proc.stdin.close();
        final out = await proc.stdout.transform(utf8.decoder).join();
        final code = await proc.exitCode;
        _expect(code == 0, 'Hook $mode exited with $code');
        return jsonDecode(out.trim()) as Map<String, dynamic>;
      }

      // 1. PostToolUse reads toolCall.args and stamps busy lease
      await runHook('post', <String, dynamic>{
        'conversationId': 'sess-9999',
        'workspacePaths': <String>[tmp.path],
        'toolCall': <String, dynamic>{
          'name': 'edit_file',
          'args': <String, dynamic>{
            'Path': '${wt.path}/engine/src/flutter/impeller/a.cc',
          },
        },
      });
      final lease1 = readJsonMap('${wt.path}/.git/agent_session.json');
      _expect(lease1?['state'] == 'busy', 'PostToolUse sets busy');
      _expect(lease1?['sessionId'] == 'sess-9999', 'PostToolUse sets sessionId');
      _expect(lease1?['branch'] == 'feature-a', 'PostToolUse sets branch');

      // 2. Stop returns decision: stop and flips busy -> idle
      final stopOut = await runHook('stop', <String, dynamic>{
        'conversationId': 'sess-9999',
        'workspacePaths': <String>[tmp.path],
      });
      _expect(stopOut['decision'] == 'stop', 'Stop returns decision: stop');
      final lease2 = readJsonMap('${wt.path}/.git/agent_session.json');
      _expect(lease2?['state'] == 'idle', 'Stop flips busy to idle');

      // 3. PreToolUse allows non-build commands
      final preAllow = await runHook('pre', <String, dynamic>{
        'conversationId': 'sess-9999',
        'workspacePaths': <String>[tmp.path],
        'toolCall': <String, dynamic>{
          'name': 'run_command',
          'args': <String, dynamic>{'CommandLine': 'git status'},
        },
      });
      _expect(preAllow['decision'] == 'allow', 'PreToolUse allows non-build cmd');

      // 4. With eviction_state.json, PreInvocation injects systemMessage and PreToolUse denies raw ninja
      atomicWriteJson(File('${wt.path}/.git/eviction_state.json'), const <String, dynamic>{
        'action': 'dehydrated',
        'at': '2026-11-24T19:00:00Z',
        'reclaimedHuman': '38.0G',
      });
      final preInv = await runHook('pre-invocation', <String, dynamic>{
        'conversationId': 'sess-9999',
        'workspacePaths': <String>[wt.path],
      });
      final steps = preInv['injectSteps'] as List<dynamic>?;
      _expect(
        steps != null && steps.isNotEmpty,
        'PreInvocation injects systemMessage on eviction_state.json',
      );

      final preDeny = await runHook('pre', <String, dynamic>{
        'conversationId': 'sess-9999',
        'workspacePaths': <String>[tmp.path],
        'toolCall': <String, dynamic>{
          'name': 'run_command',
          'args': <String, dynamic>{
            'CommandLine': 'ninja -C ${wt.path}/engine/src/out/host_debug_unopt',
          },
        },
      });
      _expect(preDeny['decision'] == 'deny', 'PreToolUse denies raw ninja on dehydrated wt');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  stdout.writeln('All $passed tests passed!');
}
