import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/stream_end_watcher.dart';

void main() {
  group('streamHasEnded', () {
    test('only an ended stream counts as ended', () {
      expect(streamHasEnded({'status': 'ended'}), isTrue);
      expect(streamHasEnded({'status': 'live'}), isFalse);
      expect(streamHasEnded({'status': 'scheduled'}), isFalse);
    });

    test('a missing row or status is not "ended" (never kick on bad data)', () {
      expect(streamHasEnded(null), isFalse);
      expect(streamHasEnded({}), isFalse);
      expect(streamHasEnded({'status': null}), isFalse);
    });

    test('an update that does not touch status (e.g. viewer count) is ignored',
        () {
      expect(streamHasEnded({'status': 'live', 'viewer_count': 12}), isFalse);
    });
  });
}
