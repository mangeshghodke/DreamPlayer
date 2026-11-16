import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_helper.dart';

/// A text field that on Android TV / Fire TV shows the app's blue focus glow
/// when the D-pad selects it and only opens the platform on-screen keyboard
/// (Leanback IME) when the user presses OK on the focused field. This keeps
/// D-pad navigation between fields working - the keyboard window doesn't
/// swallow the arrow keys, so focus never gets stuck on an empty field. On
/// phones and tablets it is a plain [TextField].
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.controller,
    this.decoration = const InputDecoration(),
    this.obscureText = false,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.textInputAction,
    this.autofillHints,
    this.autocorrect = true,
    this.enableSuggestions = true,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final bool obscureText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final bool autocorrect;
  final bool enableSuggestions;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  /// Outer node: the D-pad focusable "glow" target.
  late final FocusNode _outerNode = FocusNode();

  /// Inner node: the real [TextField]'s focus node. `skipTraversal` keeps it
  /// out of D-pad traversal so the keyboard window never steals the arrow
  /// keys; it is only focused programmatically on OK to summon the IME.
  late final FocusNode _innerNode = FocusNode(skipTraversal: true);

  @override
  void initState() {
    super.initState();
    _outerNode.addListener(_onOuterFocusChange);
    _innerNode.addListener(_onInnerFocusChange);
  }

  @override
  void dispose() {
    _outerNode.removeListener(_onOuterFocusChange);
    _innerNode.removeListener(_onInnerFocusChange);
    _outerNode.dispose();
    _innerNode.dispose();
    super.dispose();
  }

  void _onOuterFocusChange() {
    if (mounted) setState(() {});
  }

  void _onInnerFocusChange() {
    // When the IME closes (back/Done), hand focus back to the outer glow node
    // so D-pad navigation continues from this field.
    if (!_innerNode.hasFocus && !_outerNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_innerNode.hasFocus && !_outerNode.hasFocus) {
          _outerNode.requestFocus();
        }
      });
    }
    if (mounted) setState(() {});
  }

  bool get _focused => _outerNode.hasFocus || _innerNode.hasFocus;

  void _openKeyboard() {
    _innerNode.requestFocus();
    if (mounted) setState(() {});
  }

  KeyEventResult _onOuterKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.gameButtonA) {
        _openKeyboard();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      focusNode: _innerNode,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      autofocus: widget.autofocus,
      textInputAction: widget.textInputAction,
      autofillHints: widget.autofillHints,
      autocorrect: widget.autocorrect,
      enableSuggestions: widget.enableSuggestions,
      decoration: widget.decoration,
    );

    if (!isTvMode(context)) return field;

    final focused = _focused;
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      focusNode: _outerNode,
      onKeyEvent: _onOuterKey,
      child: AnimatedScale(
        scale: focused ? 1.03 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: focused
                ? scheme.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            border: Border.all(
              color: focused ? scheme.primary : Colors.transparent,
              width: 3,
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.4),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: field,
        ),
      ),
    );
  }
}