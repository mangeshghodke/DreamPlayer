import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/tv_helper.dart';
import 'tv_text_field.dart';

/// Shared visual language for the network-source dialogs (Jellyfin, WebDAV,
/// SMB): shaped AlertDialog, icon-badge title, rounded icon-prefixed fields,
/// tinted status banners, password visibility toggle. Fields render through
/// [TvTextField] on Android TV so D-pad navigation keeps working.

AlertDialog serverDialog({
  required Widget title,
  required Widget content,
  required List<Widget> actions,
}) {
  return AlertDialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
    contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
    actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    // Test button left, Cancel/Save right. NEVER put a Spacer()/Expanded()
    // inside `actions` — AlertDialog lays them out in an OverflowBar, and a
    // Flex child there throws a parent-data type error while mounting that
    // kills the whole dialog form (fields silently vanish).
    actionsAlignment: MainAxisAlignment.spaceBetween,
    title: title,
    content: content,
    actions: actions,
  );
}

/// Icon badge + title row used as the dialog [serverDialog] title.
class ServerDialogTitle extends StatelessWidget {
  const ServerDialogTitle({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 22, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Consistent rounded, icon-prefixed field style for the server dialogs.
InputDecoration serverFieldDecoration(
  BuildContext context, {
  required String label,
  String? hint,
  required IconData icon,
  bool optional = false,
  Widget? suffix,
}) {
  final theme = Theme.of(context);
  OutlineInputBorder border(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color),
      );
  return InputDecoration(
    labelText: optional
        ? '$label (${AppLocalizations.of(context).optional})'
        : label,
    hintText: hint,
    prefixIcon: Icon(icon, size: 20),
    suffixIcon: suffix,
    filled: true,
    fillColor:
        theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: border(theme.colorScheme.outline.withValues(alpha: 0.4)),
    enabledBorder: border(theme.colorScheme.outline.withValues(alpha: 0.4)),
    focusedBorder: border(theme.colorScheme.primary),
    labelStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
  );
}

/// Text field for server dialogs: styled via [serverFieldDecoration] and
/// D-pad friendly on TV ([TvTextField]).
class ServerTextField extends StatelessWidget {
  const ServerTextField({
    super.key,
    required this.controller,
    required this.decoration,
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
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && isTvMode(context)) {
      return TvTextField(
        controller: controller,
        decoration: decoration,
        obscureText: obscureText,
        keyboardType: keyboardType,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        autofocus: autofocus,
        textInputAction: textInputAction,
        autofillHints: autofillHints,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
      );
    }
    return TextField(
      controller: controller,
      decoration: decoration,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      autofocus: autofocus,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
    );
  }
}

/// Rounded banner for connection-test results and errors.
class ServerResultBanner extends StatelessWidget {
  const ServerResultBanner({
    super.key,
    required this.success,
    required this.message,
    this.margin,
  });

  final bool success;
  final String message;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        success ? const Color(0xFF4CAF50) : theme.colorScheme.error;
    return Container(
      margin: margin ?? const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            success ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: success ? const Color(0xFF81C995) : color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: success ? const Color(0xFF81C995) : color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Password field with a visibility toggle.
class ServerPasswordField extends StatefulWidget {
  const ServerPasswordField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.onSubmitted,
    this.textInputAction,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  @override
  State<ServerPasswordField> createState() => _ServerPasswordFieldState();
}

class _ServerPasswordFieldState extends State<ServerPasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return ServerTextField(
      controller: widget.controller,
      obscureText: !_visible,
      onSubmitted: widget.onSubmitted,
      textInputAction: widget.textInputAction ?? TextInputAction.next,
      autofillHints: const [AutofillHints.password],
      decoration: serverFieldDecoration(
        context,
        label: widget.label,
        hint: widget.hint,
        icon: widget.icon,
        suffix: IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(
            _visible
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            size: 20,
          ),
          onPressed: () => setState(() => _visible = !_visible),
        ),
      ),
    );
  }
}
