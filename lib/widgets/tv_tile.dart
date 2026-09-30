import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_helper.dart';

/// A [ListTile] with the app's TV focus treatment: blue border + primary glow
/// + slight scale when focused, and select/enter/space/gameButtonA activation
/// via [Focus.onKeyEvent] (media-center keys don't activate an InkWell).
///
/// On phones/tablets (`isTvMode == false`) this renders a plain [ListTile] so
/// touch behaviour is unchanged.
class TvTile extends StatelessWidget {
  const TvTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.dense,
    this.enabled = true,
    this.onTap,
    this.onLongPress,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final bool? dense;
  final bool enabled;
  final VoidCallback? onTap;

  /// Long-press (touch) or a held select key (TV). Used for destructive
  /// secondary actions such as delete, which must never be the primary tap.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    if (!isTvMode(context)) {
      return ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        dense: dense,
        enabled: enabled,
        onTap: enabled ? onTap : null,
        onLongPress: enabled ? onLongPress : null,
      );
    }
    return _TvFocusTile(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      child: ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        dense: dense,
        enabled: enabled,
        onTap: enabled ? onTap : null,
        onLongPress: enabled ? onLongPress : null,
      ),
    );
  }
}

/// TV focus treatment with held-key long-press.
///
/// [TvTile] itself is stateless, so the hold timer lives here. Mirrors the
/// proven 500 ms hold used by `FolderCard`: a short press activates, a hold
/// fires the secondary action, and key auto-repeat is swallowed so
/// `ActivateIntent` cannot fire the primary action mid-hold.
class _TvFocusTile extends StatefulWidget {
  const _TvFocusTile({
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<_TvFocusTile> createState() => _TvFocusTileState();
}

class _TvFocusTileState extends State<_TvFocusTile> {
  Timer? _holdTimer;
  bool _longPressFired = false;

  static bool _isSelectKey(KeyEvent event) {
    final key = event.logicalKey;
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!isTvMode(context)) return KeyEventResult.ignored;
    if (!_isSelectKey(event)) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      // A tile with no destructive secondary action keeps the original
      // press-to-activate timing. The held-key path is opt-in so that adding
      // delete to one row cannot change activation latency everywhere else.
      if (widget.onLongPress == null) {
        widget.onTap?.call();
        return KeyEventResult.handled;
      }
      _longPressFired = false;
      _holdTimer?.cancel();
      _holdTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted || widget.onLongPress == null) return;
        _longPressFired = true;
        widget.onLongPress!();
      });
      return KeyEventResult.handled;
    }

    // Swallow auto-repeat so a held key cannot re-fire the primary action.
    if (event is KeyRepeatEvent) return KeyEventResult.handled;

    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      // Only tiles WITH a long-press defer activation to key release. Calling
      // the tap here for a tile that already activated on key-down would fire
      // the action twice per remote press.
      if (widget.onLongPress != null && !_longPressFired) {
        widget.onTap?.call();
      }
      _longPressFired = false;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          final primary = Theme.of(context).colorScheme.primary;
          return AnimatedScale(
            scale: focused ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: focused
                    ? primary.withValues(alpha: 0.3)
                    : Colors.transparent,
                border: Border.all(
                  color: focused ? primary : Colors.transparent,
                  width: 3,
                ),
                boxShadow: focused
                    ? [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.4),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: widget.child,
            ),
          );
        },
      ),
    );
  }
}
