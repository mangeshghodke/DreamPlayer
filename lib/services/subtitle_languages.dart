// Subtitle language catalog modeled on Nova Video Player's
// `res/values/arrays.xml` (`entries_list_preference` / `entryvalues_list_preference`).
//
// Nova uses ISO 639-2/B three-letter codes (system, eng, fre, ger, … pob for
// Brazilian Portuguese, zho for Chinese) and shows full language names in the UI
// - never raw ISO codes. DreamPlayer mirrors that: the UI shows `displayName`,
// prefs store `novaCode`, and the OpenSubtitles download path maps to the REST
// API's expected code via [openSubsCode].
//
// References:
// - aos-Video `res/values/arrays.xml` (code-list + codepage lists above)
// - nova issues #1137 / #1228: Chinese variants need zh-cn / zh-tw distinct from
//   generic zh.
library;

import 'package:flutter/foundation.dart' show PlatformDispatcher;

class SubtitleLanguage {
  const SubtitleLanguage({
    required this.displayName,
    required this.novaCode,
    required this.iso639_1,
    required this.openSubsCode,
  });

  final String displayName;
  final String novaCode; // Nova's 3-letter value (system, eng, fre, …)
  final String iso639_1; // ISO 639-1 2-letter (for Media3/AVPlayer track matching)
  final String openSubsCode; // REST api.opensubtitles.com `languages` param

  @override
  String toString() => '$displayName ($novaCode)';
}

/// Full catalog. `system` stays first (Nova puts "locale" at top), the rest
/// alphabetical by [displayName] like Nova's UI.
const List<SubtitleLanguage> subtitleLanguages = [
  SubtitleLanguage(displayName: 'System default', novaCode: 'system', iso639_1: '', openSubsCode: ''),
  SubtitleLanguage(displayName: 'Arabic', novaCode: 'ara', iso639_1: 'ar', openSubsCode: 'ar'),
  SubtitleLanguage(displayName: 'Bulgarian', novaCode: 'bul', iso639_1: 'bg', openSubsCode: 'bg'),
  SubtitleLanguage(displayName: 'Catalan', novaCode: 'cat', iso639_1: 'ca', openSubsCode: 'ca'),
  SubtitleLanguage(displayName: 'Chinese (Simplified)', novaCode: 'zho', iso639_1: 'zh', openSubsCode: 'zh-CN'),
  SubtitleLanguage(displayName: 'Chinese (Traditional)', novaCode: 'zht', iso639_1: 'zh', openSubsCode: 'zh-TW'),
  SubtitleLanguage(displayName: 'Croatian', novaCode: 'hrv', iso639_1: 'hr', openSubsCode: 'hr'),
  SubtitleLanguage(displayName: 'Czech', novaCode: 'ces', iso639_1: 'cs', openSubsCode: 'cs'),
  SubtitleLanguage(displayName: 'Danish', novaCode: 'dan', iso639_1: 'da', openSubsCode: 'da'),
  SubtitleLanguage(displayName: 'Dutch', novaCode: 'nld', iso639_1: 'nl', openSubsCode: 'nl'),
  SubtitleLanguage(displayName: 'English', novaCode: 'eng', iso639_1: 'en', openSubsCode: 'en'),
  SubtitleLanguage(displayName: 'Finnish', novaCode: 'fin', iso639_1: 'fi', openSubsCode: 'fi'),
  SubtitleLanguage(displayName: 'French', novaCode: 'fre', iso639_1: 'fr', openSubsCode: 'fr'),
  SubtitleLanguage(displayName: 'German', novaCode: 'ger', iso639_1: 'de', openSubsCode: 'de'),
  SubtitleLanguage(displayName: 'Greek', novaCode: 'ell', iso639_1: 'el', openSubsCode: 'el'),
  SubtitleLanguage(displayName: 'Hebrew', novaCode: 'heb', iso639_1: 'he', openSubsCode: 'he'),
  SubtitleLanguage(displayName: 'Hindi', novaCode: 'hin', iso639_1: 'hi', openSubsCode: 'hi'),
  SubtitleLanguage(displayName: 'Hungarian', novaCode: 'hun', iso639_1: 'hu', openSubsCode: 'hu'),
  SubtitleLanguage(displayName: 'Indonesian', novaCode: 'ind', iso639_1: 'id', openSubsCode: 'id'),
  SubtitleLanguage(displayName: 'Italian', novaCode: 'ita', iso639_1: 'it', openSubsCode: 'it'),
  SubtitleLanguage(displayName: 'Japanese', novaCode: 'jpn', iso639_1: 'ja', openSubsCode: 'ja'),
  SubtitleLanguage(displayName: 'Korean', novaCode: 'kor', iso639_1: 'ko', openSubsCode: 'ko'),
  SubtitleLanguage(displayName: 'Norwegian', novaCode: 'nor', iso639_1: 'no', openSubsCode: 'no'),
  SubtitleLanguage(displayName: 'Polish', novaCode: 'pol', iso639_1: 'pl', openSubsCode: 'pl'),
  SubtitleLanguage(displayName: 'Portuguese', novaCode: 'por', iso639_1: 'pt', openSubsCode: 'pt'),
  SubtitleLanguage(displayName: 'Portuguese (Brazil)', novaCode: 'pob', iso639_1: 'pt', openSubsCode: 'pt-BR'),
  SubtitleLanguage(displayName: 'Romanian', novaCode: 'ron', iso639_1: 'ro', openSubsCode: 'ro'),
  SubtitleLanguage(displayName: 'Russian', novaCode: 'rus', iso639_1: 'ru', openSubsCode: 'ru'),
  SubtitleLanguage(displayName: 'Serbian', novaCode: 'srp', iso639_1: 'sr', openSubsCode: 'sr'),
  SubtitleLanguage(displayName: 'Slovenian', novaCode: 'slv', iso639_1: 'sl', openSubsCode: 'sl'),
  SubtitleLanguage(displayName: 'Spanish', novaCode: 'spa', iso639_1: 'es', openSubsCode: 'es'),
  SubtitleLanguage(displayName: 'Swedish', novaCode: 'swe', iso639_1: 'sv', openSubsCode: 'sv'),
  SubtitleLanguage(displayName: 'Thai', novaCode: 'tha', iso639_1: 'th', openSubsCode: 'th'),
  SubtitleLanguage(displayName: 'Turkish', novaCode: 'tur', iso639_1: 'tr', openSubsCode: 'tr'),
  SubtitleLanguage(displayName: 'Ukrainian', novaCode: 'ukr', iso639_1: 'uk', openSubsCode: 'uk'),
  SubtitleLanguage(displayName: 'Vietnamese', novaCode: 'vie', iso639_1: 'vi', openSubsCode: 'vi'),
];

final Map<String, SubtitleLanguage> _byNova = {
  for (final l in subtitleLanguages) l.novaCode: l,
};

SubtitleLanguage languageForNovaCode(String code) {
  final key = code.trim().toLowerCase();
  return _byNova[key] ?? _byNova['eng']!;
}

String displayNameForNovaCode(String code) => languageForNovaCode(code).displayName;

/// Map a stored [novaCode] to the OpenSubtitles `languages` query value.
/// `system` resolves to the device locale's ISO 639-1, falling back to `en`.
String openSubsCodeForNovaCode(String novaCode) {
  final key = novaCode.trim().toLowerCase();
  if (key == 'system' || key.isEmpty) {
    try {
      final loc = PlatformDispatcher.instance.locale;
      final lc = loc.languageCode.trim().toLowerCase();
      if (lc.isNotEmpty) {
        // Direct match for region-aware codes (pt-BR).
        for (final l in subtitleLanguages) {
          if (l.iso639_1 == lc) return l.openSubsCode.isEmpty ? 'en' : l.openSubsCode;
        }
        return lc;
      }
    } catch (_) {}
    return 'en';
  }
  final entry = _byNova[key];
  if (entry == null) return 'en';
  return entry.openSubsCode.isEmpty ? 'en' : entry.openSubsCode;
}

/// Nova's track languages are ISO 639-2 (eng, fre, …) while some containers
/// use ISO 639-1 (en, fr). Accept both when matching a reading preference.
bool trackMatchesNovaCode(String? trackLang, String novaCode) {
  if (trackLang == null || trackLang.isEmpty) return false;
  final t = trackLang.trim().toLowerCase();
  final pref = languageForNovaCode(novaCode);
  if (t == pref.novaCode.toLowerCase()) return true;
  if (pref.iso639_1.isNotEmpty && t == pref.iso639_1.toLowerCase()) return true;
  // Brazilian Portuguese special: track may be por vs pob, or pt-br vs pt.
  if (pref.novaCode == 'pob' && (t == 'pob' || t == 'por' || t == 'pt-br' || t == 'pt')) return true;
  if (pref.novaCode == 'por' && (t == 'por' || t == 'pt')) return true;
  // Chinese family: zho/zht vs zh / zh-cn / zh-tw.
  if ((pref.novaCode == 'zho' || pref.novaCode == 'zht') && t.startsWith('zh')) return true;
  return false;
}

/// Legacy migration: old DreamPlayer stored ISO 639-1 `en` under
/// `dreamplayer.prefSubLang`. Map it forward to Nova's code.
String migrateLegacyLangCode(String raw) {
  final v = raw.trim().toLowerCase();
  if (v.isEmpty) return 'eng';
  if (_byNova.containsKey(v)) return v; // already Nova
  // ISO 639-1 → Nova
  for (final l in subtitleLanguages) {
    if (l.iso639_1 == v) return l.novaCode;
  }
  // Region-aware: pt-br → pob, zh-cn → zho
  if (v == 'pt-br' || v == 'pb') return 'pob';
  if (v == 'zh-cn') return 'zho';
  if (v == 'zh-tw') return 'zht';
  return 'eng';
}
