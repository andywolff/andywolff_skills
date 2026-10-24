import 'dart:io';

import 'dart:io';

String? _getOption(List<String> args, String shortFlag, String longFlag) {
  for (var i = 0; i < args.length; i++) {
    if ((args[i] == shortFlag || args[i] == longFlag) && i + 1 < args.length) {
      return args[i + 1];
    }
  }
  return null;
}

Future<List<String>> _getConnectedDevices() async {
  final ProcessResult result = await Process.run('adb', <String>['devices']);
  if (result.exitCode != 0) {
    throw 'Failed to run "adb devices": ${result.stderr}';
  }
  final List<String> devices = <String>[];
  final lines = result.stdout.toString().split('\n');
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('List of devices attached')) {
      continue;
    }
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1] == 'device') {
      devices.add(parts[0]);
    }
  }
  return devices;
}

Future<String> _getProp(String prop, {String? serial}) async {
  final args = <String>[];
  if (serial != null && serial.isNotEmpty) {
    args.addAll(<String>['-s', serial]);
  }
  args.addAll(<String>['shell', 'getprop', prop]);
  final ProcessResult result = await Process.run('adb', args);
  return result.stdout.toString().trim();
}

Future<void> runDeviceDiagnostics(List<String> args) async {
  String? targetSerial = _getOption(args, '-s', '--serial');

  final List<String> connectedDevices = await _getConnectedDevices();
  if (connectedDevices.isEmpty) {
    print('❌ No connected Android devices or emulators detected via adb.');
    print('   Connect a device or launch an emulator and try again.');
    exit(1);
  }

  if (targetSerial == null) {
    if (connectedDevices.length == 1) {
      targetSerial = connectedDevices.first;
    } else {
      print('⚠️ Multiple Android devices detected:');
      for (final device in connectedDevices) {
        print('   - $device');
      }
      print('\nPlease specify the target device using: -s <serial>');
      exit(1);
    }
  } else if (!connectedDevices.contains(targetSerial)) {
    print('❌ Specified device "$targetSerial" is not in connected devices list:');
    for (final device in connectedDevices) {
      print('   - $device');
    }
    exit(1);
  }

  final String model = await _getProp('ro.product.model', serial: targetSerial);
  final String vulkanDriver = await _getProp('ro.hardware.vulkan', serial: targetSerial);
  final String glesVersionRaw = await _getProp('ro.opengles.version', serial: targetSerial);
  final String cpuAbi = await _getProp('ro.product.cpu.abi', serial: targetSerial);
  final String sdkVersion = await _getProp('ro.build.version.sdk', serial: targetSerial);
  final String osRelease = await _getProp('ro.build.version.release', serial: targetSerial);

  var glesVersion = 'Unknown';
  if (glesVersionRaw.isNotEmpty) {
    final int? parsed = int.tryParse(glesVersionRaw);
    if (parsed != null) {
      final int major = parsed >> 16;
      final int minor = (parsed >> 8) & 0xFF;
      glesVersion = '$major.$minor';
    }
  }

  print('\n📱 Connected Device Diagnostics (Device: $targetSerial):');
  print('   - Model: ${model.isEmpty ? "Unknown" : model}');
  if (osRelease.isNotEmpty || sdkVersion.isNotEmpty) {
    print('   - Android OS: ${osRelease.isNotEmpty ? osRelease : "Unknown"} (API ${sdkVersion.isNotEmpty ? sdkVersion : "?"})');
  }
  print('   - CPU Architecture: ${cpuAbi.isEmpty ? "Unknown" : cpuAbi}');
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

void main(List<String> args) async {
  try {
    await runDeviceDiagnostics(args);
  } catch (e) {
    print('Error executing device diagnostics: $e');
    exit(1);
  }
}
