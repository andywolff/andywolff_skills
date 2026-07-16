import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const String _goldUrl = 'https://flutter-gold.skia.org';

const List<String> _testCases = [
  'blueRectangleTest',
  'trianglePathTest',
  'textTest',
  'imageTest',
  'advancedBlendTest',
  'backdropFilterBlurTest',
  'platformViewTextureLayerTest',
  'platformViewHybridCompositionTest',
  'platformViewHybridCompositionPlusPlusTest',
];

const List<String> _backends = ['vulkan', 'opengles'];

void main(List<String> args) async {
  String? outputDirPath;

  // Simple hand-parsing of arguments
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--output' && i + 1 < args.length) {
      outputDirPath = args[i + 1];
    }
  }

  if (outputDirPath == null) {
    print('Usage: dart download_goldens.dart --output <output_directory>');
    exit(1);
  }

  final Directory outputDir = Directory(outputDirPath);
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  print('🚀 Initializing Skia Gold image downloader...');
  print('📂 Output Directory: ${outputDir.absolute.path}');

  final HttpClient client = HttpClient();

  try {
    final List<Future<void>> downloads = [];

    for (final String backend in _backends) {
      for (final String testCase in _testCases) {
        final String testName =
            'android_hardware_smoke_test.$backend.goldens/$testCase.$backend';
        downloads.add(
          _downloadGolden(client, testName, testCase, backend, outputDir),
        );
      }
    }

    await Future.wait(downloads);
    print('✨ All reference goldens successfully downloaded!');
    exit(0);
  } catch (e, stackTrace) {
    stderr.writeln('❌ FATAL: Downloader failed with error: $e');
    stderr.writeln(stackTrace);
    exit(1);
  } finally {
    client.close();
  }
}

Future<void> _downloadGolden(
  HttpClient client,
  String testName,
  String testCase,
  String backend,
  Directory outputDir,
) async {
  final String traceID = _computeTraceID(testName);
  final String? digest = await _getLatestDigest(client, traceID, testName);

  if (digest == null || digest.isEmpty) {
    print(
      '  ⚠️ Warning: No approved digest found on master for $testCase.$backend (traceID: $traceID). Skipping...',
    );
    return;
  }

  final List<int> bytes = await _downloadImage(client, digest);
  final File file = File('${outputDir.path}/$testCase.$backend.png');
  await file.writeAsBytes(bytes);
  print(
    '  ✅ Downloaded: $testCase.$backend.png (digest: ${digest.substring(0, 8)}...)',
  );
}

String _computeTraceID(String testName) {
  final Map<String, String> parameters = {
    'CI': 'luci',
    'Platform': 'linux',
    'name': testName,
    'source_type': 'flutter',
  };

  final Map<String, String> sorted = {};
  for (final String key in parameters.keys.toList()..sort()) {
    sorted[key] = parameters[key]!;
  }

  final String jsonTrace = json.encode(sorted);
  return md5.convert(utf8.encode(jsonTrace)).toString();
}

Future<String?> _getLatestDigest(
  HttpClient client,
  String traceID,
  String testName,
) async {
  final Uri url = Uri.parse('$_goldUrl/json/v2/latestpositivedigest/$traceID');

  final HttpClientRequest request = await client.getUrl(url);
  final HttpClientResponse response = await request.close();

  if (response.statusCode != 200) {
    throw HttpException(
      'Failed to fetch positive digest for traceID $traceID ($testName). '
      'Status code: ${response.statusCode}',
      uri: url,
    );
  }

  final String body = await utf8.decodeStream(response);
  final dynamic jsonResponse = json.decode(body);

  if (jsonResponse is! Map<String, dynamic>) {
    throw FormatException(
      'Unexpected JSON payload for traceID $traceID ($testName): $body',
    );
  }

  return jsonResponse['digest'] as String?;
}

Future<List<int>> _downloadImage(HttpClient client, String digest) async {
  final Uri url = Uri.parse('$_goldUrl/img/images/$digest.png');

  final HttpClientRequest request = await client.getUrl(url);
  final HttpClientResponse response = await request.close();

  if (response.statusCode != 200) {
    throw HttpException(
      'Failed to download image bytes for digest $digest. Status code: ${response.statusCode}',
      uri: url,
    );
  }

  final List<int> bytes = [];
  await response.forEach(bytes.addAll);
  return bytes;
}
