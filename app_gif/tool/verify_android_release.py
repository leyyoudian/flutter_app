"""Check final APK metadata against both App version sources before publishing.

Usage: python tool/verify_android_release.py --aapt "D:/Android Sdk/build-tools/35.0.0/aapt.exe"
Run after changing the version and building, not before the version bump.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--aapt', required=True)
    parser.add_argument('--apk', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    apk = args.apk or root / 'build/app/outputs/flutter-apk/app-release.apk'
    pubspec = (root / 'pubspec.yaml').read_text(encoding='utf8')
    source = (root / 'lib/main.dart').read_text(encoding='utf8')
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', pubspec, re.M)
    internal = re.search(r"static const _appVersion = '(\d+\.\d+\.\d+)';", source)
    assert version and internal, 'Missing App version declaration'
    assert version[1] == internal[1], 'App display/update version differs from pubspec'
    badging = subprocess.check_output([args.aapt, 'dump', 'badging', str(apk)], encoding='utf8')
    metadata = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    assert metadata, 'APK package metadata not found'
    assert metadata[1] == 'com.example.app_gif'
    assert (metadata[3], metadata[2]) == (version[1], version[2]), 'Built APK is stale or has overridden version metadata'
    print(json.dumps({'version': version[1], 'build': int(version[2]), 'appVersionMatchesPackage': True,
                      'apk': str(apk), 'size': apk.stat().st_size,
                      'sha256': hashlib.sha256(apk.read_bytes()).hexdigest()}, indent=2))


if __name__ == '__main__':
    main()
