import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/hide_spoilers_store.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HideSpoilersStore.instance.setEnabled(false);
    await HideSpoilersStore.instance.load();
  });

  test('off by default', () {
    expect(HideSpoilersStore.instance.enabled, isFalse);
    expect(HideSpoilersStore.instance.spoils(watched: false), isFalse);
    expect(HideSpoilersStore.instance.spoils(watched: true), isFalse);
  });

  test('blurs unwatched, never watched', () async {
    await HideSpoilersStore.instance.setEnabled(true);
    expect(HideSpoilersStore.instance.enabled, isTrue);
    expect(HideSpoilersStore.instance.spoils(watched: false), isTrue);
    expect(HideSpoilersStore.instance.spoils(watched: true), isFalse);
  });

  test('unknown state counts as unwatched', () async {
    await HideSpoilersStore.instance.setEnabled(true);
    expect(HideSpoilersStore.instance.spoils(watched: false), isTrue);
  });

  test('toggle persists across reload', () async {
    await HideSpoilersStore.instance.setEnabled(true);
    final reloaded = HideSpoilersStore.instance;
    await reloaded.load();
    expect(reloaded.enabled, isTrue);
    expect(reloaded.spoils(watched: false), isTrue);
  });
}
