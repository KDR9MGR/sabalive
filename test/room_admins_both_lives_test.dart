import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = File('lib/features/live/live_broadcast_screen.dart').readAsStringSync();

  test('the host\'s "Room admins" tool is offered in video lives as well as audio rooms', () {
    final i = host.indexOf("'Room admins'");
    expect(i, greaterThan(0));
    // the condition just before the tool must not be limited to audio rooms
    final before = host.substring(i - 220, i);
    expect(before.contains('widget.audioOnly'), isFalse, reason: before);
    expect(before.contains('_mod.serverHasModeration'), isTrue);
  });

  test('"Make room admin" is offered from a tap on someone in a video live too', () {
    expect(host.contains('allowAdmins: widget.audioOnly'), isFalse);
    expect(host.contains('allowAdmins: true'), isTrue);
  });
}
