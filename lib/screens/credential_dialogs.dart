import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../services/opensubtitles_client.dart';
import '../services/tmdb_client.dart';

/// Credential dialogs used by [SettingsScreen].
///
/// Extracted from `settings_screen.dart` so they can be pumped directly in
/// widget tests (the OpenSubtitles one is unreachable in a test build — the
/// tile is disabled without a compile-time `OPENSUBTITLES_API_KEY`).
///
/// Every dialog here wraps its `content` in a [SingleChildScrollView]. A
/// bare `Column(mainAxisSize: MainAxisSize.min)` in `AlertDialog.content`
/// overflows the bottom of the dialog on short viewports (landscape phone)
/// and at large text scales, because the dialog caps its own content height
/// below the child's natural height.

/// OpenSubtitles sign-in box.
///
/// Returns `true` when the user signed in successfully, `false` on cancel.
Future<bool?> showOpensubtitlesSignInDialog(BuildContext context) async {
  final uCtrl = TextEditingController();
  final pCtrl = TextEditingController();
  String? err;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
      title: Text(AppLocalizations.of(context).settingsOpenSubtitlesSignIn),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: uCtrl,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          TextField(
            controller: pCtrl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(err!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).settingsOpensubAccountHint,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(context).commonCancel)),
        TextButton(
          onPressed: () async {
            try {
              await OpensubtitlesClient.instance.login(
                  username: uCtrl.text.trim(), password: pCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              setDlg(() => err = e.toString());
            }
          },
          child: Text(AppLocalizations.of(context).settingsSignIn),
        ),
      ],
    )),
  );
  // `showDialog`'s future completes when the route is POPPED — the START of the
  // exit animation, not the end. The dialog's TextField keeps rebuilding for a
  // few more frames, so disposing immediately made that rebuild hit "A
  // TextEditingController was used after being disposed", which corrupts the
  // element tree and makes the subsequent teardown assert
  // `_dependents.isEmpty` in InheritedElement.debugDeactivated — the red screen
  // on saving a TMDB key. Same fix as the TheTVDB dialog in settings_screen.
  // Regression test: test/tvdb_dialog_save_test.dart (and its TMDB sibling).
  await Future<void>.delayed(const Duration(milliseconds: 400));
  uCtrl.dispose();
  pCtrl.dispose();
  return ok;
}

/// TMDB API-key editor.
///
/// Returns `true` when the stored key changed, `false` on cancel.
Future<bool?> showTmdbApiKeyDialog(BuildContext context, String currentKey) async {
  final ctrl = TextEditingController(text: currentKey);
  String? err;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
      title: Text(AppLocalizations.of(context).settingsTmdbKey),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Get a free key at themoviedb.org/settings/api',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).settingsApiKeyHint,
              hintText: '32-character hex string',
            ),
          ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(err!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(context).commonCancel)),
        if (currentKey.isNotEmpty)
          TextButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove(TmdApi.prefsKey);
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: Text(AppLocalizations.of(context).settingsRemove),
          ),
        TextButton(
          onPressed: () async {
            final entered = ctrl.text.trim();
            if (entered.isNotEmpty && entered.length != 32) {
              setDlg(() => err = 'Key must be 32 characters');
              return;
            }
            final prefs = await SharedPreferences.getInstance();
            if (entered.isEmpty) {
              await prefs.remove(TmdApi.prefsKey);
            } else {
              await prefs.setString(TmdApi.prefsKey, entered);
            }
            if (ctx.mounted) Navigator.pop(ctx, true);
          },
          child: Text(AppLocalizations.of(context).commonSave),
        ),
      ],
    )),
  );
  // `showDialog`'s future completes when the route is POPPED — the START of the
  // exit animation, not the end. The dialog's TextField keeps rebuilding for a
  // few more frames, so disposing immediately made that rebuild hit "A
  // TextEditingController was used after being disposed", which corrupts the
  // element tree and makes the subsequent teardown assert
  // `_dependents.isEmpty` in InheritedElement.debugDeactivated — the red screen
  // on saving a TMDB key. Same fix as the TheTVDB dialog in settings_screen.
  // Regression test: test/tvdb_dialog_save_test.dart (and its TMDB sibling).
  await Future<void>.delayed(const Duration(milliseconds: 400));
  ctrl.dispose();
  return ok;
}
