import 'dart:io';

// App-only releases still build in the historical repository layout. Require
// the real contract source in either layout rather than skipping these checks.
File repositoryFirmwareFile(String relativePath) {
  for (final root in ['../firmware/p4-rev3x', '../ESP32-S3-LCD-2.8C-Test']) {
    final file = File('$root/$relativePath');
    if (file.existsSync()) return file;
  }
  throw FileSystemException(
    'Firmware contract source is missing',
    relativePath,
  );
}
