import 'package:flutter/material.dart';

import '../app.dart' show RootShell;
import '../services/app_debug_log.dart';
import '../services/app_lock_store.dart';

/// Stable [MaterialApp.home] that swaps between the lock gate and the real
/// shell. Keeping the widget identity stable (instead of returning
/// `AppLockScreen`/`RootShell` directly from `home:`) means the Navigator's
/// initial route never has to change - only this widget's child swaps.
class AppLockGate extends StatelessWidget {
  const AppLockGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLockStore.instance,
      builder: (context, _) {
        final locked = AppLockStore.instance.locked;
        AppDebugLog.mark('applock: gate rebuild locked=$locked');
        return locked ? const AppLockScreen() : const RootShell();
      },
    );
  }
}

/// Full-screen gate shown when [AppLockStore.locked] is true (app lock armed
/// and not yet passed this session). The only way through is the device's
/// own biometric / passcode prompt via [AppLockStore.unlockApp].
///
/// Deliberately minimal: no app content is reachable behind it, and the
/// unlock button is the single action. A wrong/cancelled prompt just leaves
/// the gate up.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await AppLockStore.instance.unlockApp();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = 'Authentication failed or was cancelled';
      });
    }
    // On success the store flips `locked` to false and the gate disappears;
    // no setState needed.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 72,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'DreamPlayer is locked',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Use Face ID / Touch ID or your device passcode to unlock.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.textTheme.bodySmall?.color,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _unlock,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fingerprint),
                    label: Text(_busy ? 'Waiting for authentication…' : 'Unlock'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
