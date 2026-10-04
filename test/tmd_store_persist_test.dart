import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The details screen used to freeze the iPad solid because every metadata
/// write re-encoded the WHOLE cache. These pin the two properties that fix it:
/// writes coalesce, and nothing is lost.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await TmdStore.clearAll();
  });

  TmdMeta meta(String title) =>
      TmdMeta(movie: TmdMovie(id: title.hashCode, title: title));

  Future<String?> blob() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('dreamplayer.tmdbMeta');
  }

  test('a burst of saves is not written immediately', () async {
    await TmdStore.save('a', meta('A'));
    await TmdStore.save('b', meta('B'));
    // Still nothing on disk: the writer is waiting for the coalescing window.
    expect(await blob(), isNull);
  });

  test('flush persists every entry in the burst', () async {
    for (var i = 0; i < 25; i++) {
      await TmdStore.save('key$i', meta('Title $i'));
    }
    await TmdStore.flush();

    final raw = await blob();
    expect(raw, isNotNull);
    final all = await TmdStore.loadAll();
    expect(all.length, 25);
    expect(all['key7']?.movie.title, 'Title 7');
  });

  test('an entry saved during a write is not dropped', () async {
    await TmdStore.save('first', meta('First'));
    final flushing = TmdStore.flush();
    // Lands while the encode/write is in flight.
    await TmdStore.save('second', meta('Second'));
    await flushing;
    await TmdStore.flush();

    final all = await TmdStore.loadAll();
    expect(all.containsKey('first'), isTrue);
    expect(all.containsKey('second'), isTrue);
  });

  test('remove deletes only that entry and persists', () async {
    await TmdStore.save('keep', meta('Keep'));
    await TmdStore.save('drop', meta('Drop'));
    await TmdStore.flush();

    await TmdStore.remove('drop');
    final all = await TmdStore.loadAll();
    expect(all.containsKey('keep'), isTrue);
    expect(all.containsKey('drop'), isFalse);
    expect(await blob(), isNotNull, reason: 'remove must not leave a stale blob');
  });

  test('clearAll empties both memory and disk', () async {
    await TmdStore.save('x', meta('X'));
    await TmdStore.flush();
    await TmdStore.clearAll();

    expect(await blob(), isNull);
    expect((await TmdStore.loadAll()).isEmpty, isTrue);
  });
}
