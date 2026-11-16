import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/browser_view_store.dart';
import 'tv_tile.dart';

/// The localized strings, or English when the delegates are not installed.
///
/// The menu is mounted by five browser screens, and a browser must never
/// crash because a widget test (or an embedder) left the localization
/// delegates out - `AppLocalizations.of` force-unwraps, so the lookup is done
/// through [Localizations.of] instead.
AppLocalizations? _l10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations);

/// The three-dot overflow in the network browsers' app bars.
///
/// Windows 11 hides the view switch behind "View and more" (the ⋮ at the top
/// right); this is the same shape. Tapping **View** opens the List / Grid
/// chooser, and the choice applies to every network browser at once.
class BrowserViewMenu extends StatelessWidget {
  const BrowserViewMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return PopupMenuButton<String>(
      key: const ValueKey('browserViewMenu'),
      icon: const Icon(Icons.more_vert),
      tooltip: l10n?.browserViewMoreOptions ?? 'More options',
      onSelected: (value) {
        if (value == _kView) showBrowserViewPicker(context);
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _kView,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.view_agenda_outlined),
            title: Text(l10n?.browserView ?? 'View'),
          ),
        ),
      ],
    );
  }
}

const String _kView = 'view';

/// The List / Grid chooser.
///
/// A bottom sheet rather than a second popup: the rows are radio items, and a
/// sheet gives them room to explain themselves (and works with a D-pad on TV,
/// where nested popup menus are awkward).
Future<void> showBrowserViewPicker(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      final l10n = _l10n(sheetContext);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                l10n?.browserView ?? 'View',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            ListenableBuilder(
              listenable: BrowserViewStore.instance,
              builder: (context, _) {
                final mode = BrowserViewStore.instance.mode;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TvTile(
                      leading: const Icon(Icons.view_list),
                      title: Text(l10n?.browserViewList ?? 'List'),
                      trailing: mode == BrowserViewMode.list
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        BrowserViewStore.instance.setMode(BrowserViewMode.list);
                      },
                    ),
                    TvTile(
                      leading: const Icon(Icons.grid_view),
                      title: Text(l10n?.browserViewGrid ?? 'Grid'),
                      trailing: mode == BrowserViewMode.grid
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        BrowserViewStore.instance.setMode(BrowserViewMode.grid);
                      },
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}
