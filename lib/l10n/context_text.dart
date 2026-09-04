import 'package:flutter/widgets.dart';

/// Localizes feature-specific copy that has not yet moved into the generated
/// ARB catalogue. Keeping the locale lookup on [BuildContext] makes these
/// strings update immediately when the app language changes.
extension ContextText on BuildContext {
  String tr(String english, String chinese) =>
      Localizations.localeOf(this).languageCode == 'zh' ? chinese : english;
}
