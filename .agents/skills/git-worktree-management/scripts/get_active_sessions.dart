import 'dart:convert';
import 'dart:io';

class SessionInfo {
  final String conversationId;
  final String title;
  final String workspaceUri;
  final String workspacePath;
  final int? pid;

  SessionInfo({
    required this.conversationId,
    required this.title,
    required this.workspaceUri,
    required this.workspacePath,
    this.pid,
  });

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'title': title,
    'workspaceUri': workspaceUri,
    'workspacePath': workspacePath,
    if (pid != null) 'pid': pid,
  };

  @override
  String toString() => '$conversationId: "$title" ($workspacePath)';
}

/// Discovers active Jetski sessions by checking locked presence files
/// and querying conversation_summaries.db.
Future<Map<String, List<SessionInfo>>> getActiveJetskiSessions() async {
  final home = Platform.environment['HOME'] ?? '';
  final presenceDir = Directory('$home/.gemini/jetski/presence');
  final dbFile = File('$home/.gemini/jetski/conversation_summaries.db');

  if (!presenceDir.existsSync() || !dbFile.existsSync()) {
    return {};
  }

  // 1. Identify locked files in presence directory via lsof
  final lsofResult = await Process.run('lsof', ['+D', presenceDir.path, '-F', 'pn']);
  if (lsofResult.exitCode != 0 && (lsofResult.stdout as String).isEmpty) {
    return {};
  }

  final conversationPids = parseLsofOutput(lsofResult.stdout as String);
  if (conversationPids.isEmpty) {
    return {};
  }

  // 2. Query workspace URIs and metadata from conversation_summaries.db
  final idList = conversationPids.keys.map((id) => "'$id'").join(',');
  final sql =
      'SELECT conversation_id, title, workspace_uris FROM conversation_summaries WHERE conversation_id IN ($idList);';

  final sqliteResult = await Process.run('sqlite3', [dbFile.path, '-json', sql]);
  if (sqliteResult.exitCode != 0) {
    return {};
  }

  return parseSqliteSessions(sqliteResult.stdout as String, conversationPids);
}

/// Parses the output of `lsof -F pn` to extract locked conversation IDs and their PIDs.
Map<String, int> parseLsofOutput(String stdout) {
  final conversationPids = <String, int>{};
  int? currentPid;

  for (final rawLine in stdout.split('\n')) {
    final line = rawLine.trim();
    if (line.startsWith('p')) {
      currentPid = int.tryParse(line.substring(1));
    } else if (line.startsWith('n') && line.endsWith('.lock')) {
      final lockFileName = line.substring(1).split('/').last;
      final cid = lockFileName.replaceAll('.lock', '');
      if (currentPid != null) {
        conversationPids[cid] = currentPid;
      }
    }
  }

  return conversationPids;
}

/// Parses SQLite JSON rows and maps sessions by workspace path.
Map<String, List<SessionInfo>> parseSqliteSessions(
  String jsonStr,
  Map<String, int> conversationPids,
) {
  final mapping = <String, List<SessionInfo>>{};
  try {
    final List<dynamic> rows = jsonDecode(jsonStr) as List<dynamic>;
    for (final row in rows) {
      final map = row as Map<String, dynamic>;
      final cid = map['conversation_id'] as String;
      final title = (map['title'] as String?)?.trim() ?? '';
      final urisRaw = map['workspace_uris'] as String? ?? '[]';
      final List<dynamic> uris = jsonDecode(urisRaw) as List<dynamic>;
      final pid = conversationPids[cid];

      for (final uriStr in uris) {
        final uri = Uri.tryParse(uriStr as String);
        final path = uri != null && uri.scheme == 'file'
            ? uri.toFilePath()
            : uriStr.replaceFirst('file://', '');

        final session = SessionInfo(
          conversationId: cid,
          title: title.isNotEmpty ? title : cid.substring(0, 8),
          workspaceUri: uriStr,
          workspacePath: path,
          pid: pid,
        );

        mapping.putIfAbsent(path, () => []).add(session);
      }
    }
  } catch (_) {}

  return mapping;
}

Future<void> main(List<String> args) async {
  final asJson = args.contains('--json');
  final sessionsByPath = await getActiveJetskiSessions();

  if (asJson) {
    final allSessions = sessionsByPath.values.expand((s) => s).map((s) => s.toJson()).toList();
    print(const JsonEncoder.withIndent('  ').convert(allSessions));
    return;
  }

  if (sessionsByPath.isEmpty) {
    print('No active Jetski sessions found.');
    return;
  }

  const columns = [
    (title: 'PID', width: 8),
    (title: 'Conversation ID', width: 38),
    (title: 'Workspace', width: 40),
    (title: 'Title', width: 30),
  ];

  final header = columns.map((c) => c.title.padRight(c.width)).join(' | ');
  final divider = columns.map((c) => '-' * c.width).join(' | ');

  print(header);
  print(divider);

  for (final entry in sessionsByPath.entries) {
    for (final session in entry.value) {
      final pidStr = session.pid?.toString() ?? '-';
      final pathBase = session.workspacePath.split('/').last;
      final row = [
        pidStr.padRight(8),
        session.conversationId.padRight(38),
        pathBase.padRight(40),
        session.title,
      ].join(' | ');
      print(row);
    }
  }
}
