import 'package:dream_player/services/subtitle_fonts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubtitleFonts', () {
    test('every bundled family is declared as an asset', () async {
      expect(SubtitleFonts.bundled, isNotEmpty);
      for (final entry in SubtitleFonts.bundled.entries) {
        expect(entry.value, startsWith('assets/fonts/'));
        // google_fonts recognises an asset as this family's Regular file only
        // when the path minus its extension ends with "<Family>-Regular" -
        // the family name VERBATIM, spaces and case included ("Playfair
        // Display-Regular.ttf"). A tidied-up filename silently downloads
        // instead of using the bundled copy.
        final base = entry.value.split('/').last.replaceAll('.ttf', '');
        expect(
          base,
          '${entry.key}-Regular',
          reason: '${entry.key} must follow the google_fonts asset convention',
        );
        final data = await rootBundle.load(entry.value);
        expect(data.lengthInBytes, greaterThan(1000));
      }
    });

    test('bundled names are usable as Google Fonts display names', () {
      expect(SubtitleFonts.bundledNames, contains('Poppins'));
      expect(SubtitleFonts.bundledNames, contains('Fira Code'));
      expect(SubtitleFonts.onlineFamilies, contains('Poppins'));
      expect(SubtitleFonts.onlineFamilies, contains('Roboto'));
      // Sorted, because the picker renders the list as-is.
      final families = SubtitleFonts.onlineFamilies;
      expect(families, orderedEquals([...families]..sort()));
    });

    test('no file IO under flutter_test', () async {
      // Resolving needs path_provider, which has no implementation in tests;
      // the guard keeps unit tests (and the build) quiet.
      expect(await SubtitleFonts.resolvePath('Poppins'), isNull);
      expect(await SubtitleFonts.resolvePath(null), isNull);
      expect(await SubtitleFonts.resolvePath(''), isNull);
      expect(await SubtitleFonts.directoryPath(), isNull);
    });
  });
}
