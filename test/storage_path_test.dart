import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/utils/storage_path.dart';

/// Issue #50: a USB drive was browsable but had no route into the library.
/// Deciding "is this removable?" gates both the Download-to-device button and
/// the new Add-to-library action, so the two copies of this rule that existed
/// (a private getter on the details screen, inline logic in the file browser)
/// are now one - and these pin the answer for the shapes that actually occur.
void main() {
  group('isOnRemovableStorage', () {
    test('a USB drive on a UUID mount point is removable', () {
      // Real shape for a USB stick: /storage/<VOLUME-UUID>
      expect(isOnRemovableStorage('/storage/1A2B-3C4D/Movies'), isTrue);
    });

    test('an SD card is removable', () {
      expect(isOnRemovableStorage('/storage/1234-5678/DCIM'), isTrue);
    });

    test('internal storage is not removable', () {
      expect(isOnRemovableStorage('/storage/emulated/0/Movies'), isFalse);
      expect(isOnRemovableStorage('/storage/self/primary/Movies'), isFalse);
    });

    test('SAF paths are NOT removable', () {
      // A tree:<id> or content:// path is a bookmark, not a mount point, so it
      // cannot be proven removable and the copy/download actions must not
      // appear for it.
      expect(isOnRemovableStorage('tree:abc123/Movies'), isFalse);
      expect(isOnRemovableStorage('content://com.android.externalstorage/x'),
          isFalse);
    });

    test('unrelated paths are not removable', () {
      expect(isOnRemovableStorage('/data/media/0'), isFalse);
      expect(isOnRemovableStorage(''), isFalse);
      expect(isOnRemovableStorage(null), isFalse);
    });
  });

  group('isInternalStorage', () {
    test('covers both internal mount points', () {
      expect(isInternalStorage('/storage/emulated/0/Download'), isTrue);
      expect(isInternalStorage('/storage/self/primary/Download'), isTrue);
    });

    test('a USB drive is not internal, and is exactly the #50 case', () {
      expect(isInternalStorage('/storage/1A2B-3C4D/Movies'), isFalse);
    });

    test('the two predicates never both answer true', () {
      // Guards against a future edit making them overlap, which would make the
      // Add-to-library guard and the Download button disagree about the same
      // file rather than merely duplicating the work.
      for (final p in const [
        '/storage/emulated/0/Movies',
        '/storage/self/primary/Movies',
        '/storage/1A2B-3C4D/Movies',
        '/storage/1234-5678/DCIM',
        'tree:abc/Movies',
        '/data/media/0',
      ]) {
        expect(
          isInternalStorage(p) && isOnRemovableStorage(p),
          isFalse,
          reason: '$p cannot be both internal and removable',
        );
      }
    });
  });
}