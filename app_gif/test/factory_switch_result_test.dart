import 'package:app_gif/transcode_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('installed factory switch accepts acknowledged pending transition', () {
    expect(switchResultAccepted(true), isTrue);
    expect(switchResultAccepted({'pending': true, 'id': 'F024'}), isTrue);
    expect(switchResultAccepted({'needsUpload': true, 'id': 'F024'}), isFalse);
    expect(switchResultAccepted({'superseded': true}), isFalse);
    expect(switchResultAccepted(null), isFalse);
    expect(switchResultAccepted(false), isFalse);
  });
}
