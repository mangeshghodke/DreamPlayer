/// Reads the `name` table out of a TrueType/OpenType file.
///
/// Needed because the native subtitle renderers want a **file**, and the only
/// copy of a Google Fonts family on disk is whatever `google_fonts` cached.
/// That cache names files `<Family>_regular_<sha256>.ttf` today, but relying on
/// that convention silently broke font application on iOS: a name that does not
/// match (a space, a different weight, a future rename) makes the lookup return
/// nothing, and the player quietly falls back to the system font.
///
/// So the file itself is asked what family it carries. Pure function over
/// bytes - unit-tested against the bundled TTFs, no file IO here.
library;

import 'dart:typed_data';

/// Family-ish names declared by the font: name IDs 1 (family), 16
/// (typographic family), 4 (full) and 6 (PostScript name). Empty on any
/// malformed input - a corrupt font must never throw.
List<String> ttfNameTableNames(Uint8List bytes) {
  try {
    return _parse(bytes);
  } catch (_) {
    return const [];
  }
}

/// Lowercase alphanumerics only, so `Open Sans`, `OpenSans` and
/// `OpenSans-Regular` are comparable.
String normaliseFontName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Style words a full/PostScript name may append to the family
/// (`Poppins Regular`, `OpenSans-Bold`). `Roboto Mono` is a DIFFERENT family
/// from `Roboto`, so only these may follow the family name.
const _styleWords = {
  'regular',
  'normal',
  'book',
  'roman',
  'italic',
  'oblique',
  'bold',
  'light',
  'thin',
  'medium',
  'semibold',
  'demibold',
  'extralight',
  'ultralight',
  'extrabold',
  'ultrabold',
  'black',
  'heavy',
  'condensed',
};

/// True when [declared] (a name from the file) can stand for [family].
///
/// Exact family match, or the family followed only by style words. A prefix
/// test alone would let `Roboto Mono` satisfy `Roboto` - and since the winner
/// is copied into `<stem>.ttf` and reused forever, one loose match would stick.
bool fontNameMatches(String declared, String family) {
  final d = normaliseFontName(declared);
  final f = normaliseFontName(family);
  if (d.isEmpty || f.isEmpty) return false;
  if (d == f) return true;
  if (!d.startsWith(f)) return false;
  var rest = d.substring(f.length);
  while (rest.isNotEmpty) {
    final word = _styleWords.firstWhere(
      (w) => rest.startsWith(w),
      orElse: () => '',
    );
    if (word.isEmpty) return false;
    rest = rest.substring(word.length);
  }
  return true;
}

List<String> _parse(Uint8List b) {
  if (b.length < 12) return const [];
  final data = ByteData.sublistView(b);
  final numTables = data.getUint16(4);
  if (numTables == 0 || numTables > 512) return const [];

  int? nameOffset;
  int? nameLength;
  for (var i = 0; i < numTables; i++) {
    final record = 12 + i * 16;
    if (record + 16 > b.length) break;
    final tag = String.fromCharCodes(b.sublist(record, record + 4));
    if (tag == 'name') {
      nameOffset = data.getUint32(record + 8);
      nameLength = data.getUint32(record + 12);
      break;
    }
  }
  final start = nameOffset;
  final length = nameLength;
  if (start == null || length == null) return const [];
  if (start + 6 > b.length) return const [];

  final count = data.getUint16(start + 2);
  final stringOffset = data.getUint16(start + 4);
  if (count > 4096) return const [];

  const wantedIds = {1, 4, 6, 16};
  final out = <String>[];
  for (var i = 0; i < count; i++) {
    final rec = start + 6 + i * 12;
    if (rec + 12 > b.length) break;
    final platform = data.getUint16(rec);
    final nameId = data.getUint16(rec + 6);
    if (!wantedIds.contains(nameId)) continue;
    final strLength = data.getUint16(rec + 8);
    final strStart = start + stringOffset + data.getUint16(rec + 10);
    if (strStart + strLength > b.length || strLength == 0) continue;

    final raw = b.sublist(strStart, strStart + strLength);
    String? decoded;
    if (platform == 3 || platform == 0) {
      // Windows / Unicode records are UTF-16 big-endian.
      final units = <int>[];
      for (var j = 0; j + 1 < raw.length; j += 2) {
        units.add((raw[j] << 8) | raw[j + 1]);
      }
      decoded = String.fromCharCodes(units);
    } else if (platform == 1 && nameId != 6) {
      // Macintosh Roman: close enough to latin1 for the ASCII family names
      // Google Fonts ships (PostScript names are platform-3 only).
      decoded = String.fromCharCodes(raw);
    }
    if (decoded == null) continue;
    final name = decoded.trim();
    if (name.isNotEmpty && !out.contains(name)) out.add(name);
  }
  return out;
}
