import 'dart:io';

Future<void> runDeviceDiagnostics() async {
  final ProcessResult modelResult = await Process.run('adb', <String>[
    'shell',
    'getprop',
    'ro.product.model',
  ]);
  final ProcessResult vulkanResult = await Process.run('adb', <String>[
    'shell',
    'getprop',
    'ro.hardware.vulkan',
  ]);
  final ProcessResult glesResult = await Process.run('adb', <String>[
    'shell',
    'getprop',
    'ro.opengles.version',
  ]);

  final String model = modelResult.stdout.toString().trim();
  final String vulkanDriver = vulkanResult.stdout.toString().trim();
  final String glesVersionRaw = glesResult.stdout.toString().trim();

  var glesVersion = 'Unknown';
  if (glesVersionRaw.isNotEmpty) {
    final int? parsed = int.tryParse(glesVersionRaw);
    if (parsed != null) {
      final int major = parsed >> 16;
      final int minor = (parsed >> 8) & 0xFF;
      glesVersion = '$major.$minor';
    }
  }

  print('\n📱 Connected Device Diagnostics:');
  print('   - Model: $model');
  print(
    '   - Vulkan Driver: ${vulkanDriver.isEmpty ? "None detected" : vulkanDriver}',
  );
  print('   - OpenGL ES: $glesVersion');

  if (vulkanDriver == 'ranchu' || model.toLowerCase().contains('emulator')) {
    print('   - Environment: Android Emulator');
    print(
      '   ⚠️  Warning: Vulkan graphics context initialization frequently fails on emulators.',
    );
    print(
      '      If the test run fails or hangs, run again with: --android-impeller-backend opengles\n',
    );
  } else {
    print('   - Environment: Physical Android Hardware\n');
  }
}

void main() async {
  try {
    await runDeviceDiagnostics();
  } catch (e) {
    print('Error executing device diagnostics: $e');
    exit(1);
  }
}
