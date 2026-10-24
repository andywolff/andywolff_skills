// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Standalone visual differential comparator for screenshots and goldens.
///
/// Usage via flutter test:
/// ```sh
/// flutter test \
///   --dart-define=BASELINE_PNG=/path/to/baseline.png \
///   --dart-define=CANDIDATE_PNG=/path/to/candidate.png \
///   --dart-define=DIFF_PNG=/path/to/diff_output.png \
///   --dart-define=CROP_LTRB=0,0,100,100 \
///   .agents/skills/personal-pixel-diff-images/scripts/compare_images.dart
/// ```
void main() {
  test('Visual differential comparison', () async {
    const baselinePath = String.fromEnvironment('BASELINE_PNG');
    const candidatePath = String.fromEnvironment('CANDIDATE_PNG');
    const diffOutputPath = String.fromEnvironment('DIFF_PNG');
    const cropLTRB = String.fromEnvironment('CROP_LTRB');

    if (baselinePath.isEmpty || candidatePath.isEmpty) {
      fail(
        'Missing required dart-defines: BASELINE_PNG and CANDIDATE_PNG must be provided.',
      );
    }

    final baselineFile = File(baselinePath);
    final candidateFile = File(candidatePath);

    if (!baselineFile.existsSync()) {
      fail('Baseline file does not exist: $baselinePath');
    }
    if (!candidateFile.existsSync()) {
      fail('Candidate file does not exist: $candidatePath');
    }

    final ui.Image baselineImage = await _loadImage(baselineFile);
    final ui.Image candidateImage = await _loadImage(candidateFile);

    var cropL = 0;
    var cropT = 0;
    var cropR = baselineImage.width;
    var cropB = baselineImage.height;

    if (cropLTRB.isNotEmpty) {
      final List<int> coords = cropLTRB
          .split(',')
          .map((String s) => int.parse(s.trim()))
          .toList();
      if (coords.length == 4) {
        cropL = coords[0].clamp(0, baselineImage.width);
        cropT = coords[1].clamp(0, baselineImage.height);
        cropR = coords[2].clamp(cropL, baselineImage.width);
        cropB = coords[3].clamp(cropT, baselineImage.height);
      }
    }

    final int regionWidth = cropR - cropL;
    final int regionHeight = cropB - cropT;

    if (regionWidth <= 0 || regionHeight <= 0) {
      fail('Invalid crop region: ${regionWidth}x$regionHeight');
    }

    final ByteData? data1 = await baselineImage.toByteData();
    final ByteData? data2 = await candidateImage.toByteData();

    final Uint8List pixels1 = data1!.buffer.asUint8List();
    final Uint8List pixels2 = data2!.buffer.asUint8List();

    final diffPixels = Uint8List(regionWidth * regionHeight * 4);
    final baselineCropPixels = Uint8List(regionWidth * regionHeight * 4);
    final candidateCropPixels = Uint8List(regionWidth * regionHeight * 4);

    var totalDiffCount = 0;
    var minX = 999999;
    var maxX = -1;
    var minY = 999999;
    var maxY = -1;
    var maxDelta = 0;

    for (var y = 0; y < regionHeight; y++) {
      for (var x = 0; x < regionWidth; x++) {
        final int srcX = cropL + x;
        final int srcY = cropT + y;

        final int srcIdx = (srcY * baselineImage.width + srcX) * 4;
        final int dstIdx = (y * regionWidth + x) * 4;

        final int r1 = pixels1[srcIdx];
        final int g1 = pixels1[srcIdx + 1];
        final int b1 = pixels1[srcIdx + 2];
        final int a1 = pixels1[srcIdx + 3];

        final int r2 = pixels2[srcIdx];
        final int g2 = pixels2[srcIdx + 1];
        final int b2 = pixels2[srcIdx + 2];
        final int a2 = pixels2[srcIdx + 3];

        baselineCropPixels[dstIdx] = r1;
        baselineCropPixels[dstIdx + 1] = g1;
        baselineCropPixels[dstIdx + 2] = b1;
        baselineCropPixels[dstIdx + 3] = a1;

        candidateCropPixels[dstIdx] = r2;
        candidateCropPixels[dstIdx + 1] = g2;
        candidateCropPixels[dstIdx + 2] = b2;
        candidateCropPixels[dstIdx + 3] = a2;

        final int dr = (r1 - r2).abs();
        final int dg = (g1 - g2).abs();
        final int db = (b1 - b2).abs();
        final int da = (a1 - a2).abs();
        final dMax1 = dr > dg ? dr : dg;
        final dMax2 = db > da ? db : da;
        final delta = dMax1 > dMax2 ? dMax1 : dMax2;
        if (delta > maxDelta) {
          maxDelta = delta;
        }

        final bool isDiff = r1 != r2 || g1 != g2 || b1 != b2 || a1 != a2;

        if (isDiff) {
          totalDiffCount++;
          if (x < minX) {
            minX = x;
          }
          if (x > maxX) {
            maxX = x;
          }
          if (y < minY) {
            minY = y;
          }
          if (y > maxY) {
            maxY = y;
          }

          // Highlight difference in vibrant magenta
          diffPixels[dstIdx] = 255;
          diffPixels[dstIdx + 1] = 0;
          diffPixels[dstIdx + 2] = 128;
          diffPixels[dstIdx + 3] = 255;
        } else {
          // Grayscale dimmed background for matching pixels
          final int gray = ((r1 + g1 + b1) / 3).round();
          diffPixels[dstIdx] = gray;
          diffPixels[dstIdx + 1] = gray;
          diffPixels[dstIdx + 2] = gray;
          diffPixels[dstIdx + 3] = 60;
        }
      }
    }

    final int totalPixels = regionWidth * regionHeight;
    final double diffPct = (totalDiffCount / totalPixels) * 100.0;

    // ignore: avoid_print
    print('------------------------------------------------------------');
    // ignore: avoid_print
    print('Visual Diff Results:');
    // ignore: avoid_print
    print(
      '  Region Size:       ${regionWidth}x$regionHeight ($totalPixels px)',
    );
    // ignore: avoid_print
    print(
      '  Mismatched Pixels: $totalDiffCount / $totalPixels (${diffPct.toStringAsFixed(2)}%)',
    );
    // ignore: avoid_print
    print('  Max Channel Delta: $maxDelta');
    if (totalDiffCount > 0) {
      // ignore: avoid_print
      print('  Diff Bounding Box: x=[$minX..$maxX], y=[$minY..$maxY]');
    }
    // ignore: avoid_print
    print('------------------------------------------------------------');

    if (diffOutputPath.isNotEmpty) {
      final String basePath = diffOutputPath.endsWith('.png')
          ? diffOutputPath.substring(0, diffOutputPath.length - 4)
          : diffOutputPath;
      final String baselineCropPath = '${basePath}_baseline_crop.png';
      final String candidateCropPath = '${basePath}_candidate_crop.png';

      await _saveRgbaImage(
        diffPixels,
        regionWidth,
        regionHeight,
        diffOutputPath,
      );
      // ignore: avoid_print
      print('Diff heatmap saved to: $diffOutputPath');

      if (cropLTRB.isNotEmpty) {
        await _saveRgbaImage(
          baselineCropPixels,
          regionWidth,
          regionHeight,
          baselineCropPath,
        );
        await _saveRgbaImage(
          candidateCropPixels,
          regionWidth,
          regionHeight,
          candidateCropPath,
        );
        // ignore: avoid_print
        print('Cropped baseline saved to: $baselineCropPath');
        // ignore: avoid_print
        print('Cropped candidate saved to: $candidateCropPath');
      }
    }

    expect(
      totalDiffCount,
      0,
      reason:
          'Visual differential mismatch: $totalDiffCount / $totalPixels pixels differed (max delta: $maxDelta).',
    );
  });
}

Future<void> _saveRgbaImage(
  Uint8List pixels,
  int width,
  int height,
  String filePath,
) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    (ui.Image img) => completer.complete(img),
  );

  final diffImage = await completer.future;
  final byteData = await diffImage.toByteData(format: ui.ImageByteFormat.png);
  if (byteData != null) {
    final outFile = File(filePath);
    await outFile.parent.create(recursive: true);
    await outFile.writeAsBytes(byteData.buffer.asUint8List());
  }
}

Future<ui.Image> _loadImage(File file) async {
  final bytes = await file.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}
