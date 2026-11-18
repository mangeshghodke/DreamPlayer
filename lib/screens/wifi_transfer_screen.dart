import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_browser.dart';
import '../services/wifi_upload.dart';
import '../utils/upload_url.dart';

/// WiFi file transfer (competitor-gap #1): the page behind the home "+" ->
/// "WiFi file transfer" row. Fill in a username and password, optionally a
/// port, and press Start service; the screen then shows the short address to
/// type in a PC browser, and every file that browser pushes over the LAN is
/// listed with a live progress bar.
///
/// CX-File-Explorer shape, deliberately NOT a toggle:
///   - the fields ARE the settings - typing saves them immediately (there is
///     no separate Save button),
///   - the username and password are REQUIRED, so the browser always shows
///     its own HTTP Basic-auth prompt before the page loads,
///   - the port is OPTIONAL - an empty field means the default port.
///
/// The URL is deliberately short and token-free: `http://ip:port/wifi-transfer/`,
/// the shape a user can type from across the room.
class WifiTransferScreen extends StatefulWidget {
  const WifiTransferScreen({super.key});

  @override
  State<WifiTransferScreen> createState() => _WifiTransferScreenState();
}

class _WifiTransferScreenState extends State<WifiTransferScreen> {
  final WifiUploadService _service = WifiUploadService.instance;
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _portController = TextEditingController();

  /// Restarts the live server after the user stops typing in a field, so a
  /// credential/port edit does not tear the server down per keystroke (and
  /// does not kill an in-flight upload either).
  Timer? _restartDebounce;
  bool _obscurePassword = true;
  bool _picking = false;

  /// Progress coming from the native picker (iOS photos): copying the picked
  /// items to stable temp files is the slow part, and while it runs every
  /// Send button is greyed out. This lets the UI show a determinate bar
  /// (done/total) so the user can see it's working instead of force-closing.
  StreamSubscription<Map<String, int>>? _pickProgressSub;
  int _pickDone = 0;
  int _pickTotal = 0;

  /// Wraps every Send action with a progress subscription. The subscription
  /// listens for `{done, total}` events emitted by the native picker (only
  /// the iOS photos picker emits them; on Android the stream stays empty and
  /// the bar shows indeterminate while `_picking` is true).
  Future<void> _runPick(Future<void> Function() action) async {
    if (_picking || !_service.running) return;
    _picking = true;
    _pickDone = 0;
    _pickTotal = 0;
    if (mounted) setState(() {});
    final sub = FileBrowserService.instance.pickProgressStream().listen((p) {
      if (!mounted) return;
      setState(() {
        _pickDone = p['done'] ?? 0;
        _pickTotal = p['total'] ?? 0;
      });
    });
    _pickProgressSub = sub;
    try {
      await action();
    } finally {
      await sub.cancel();
      _pickProgressSub = null;
      _picking = false;
      if (mounted) setState(() {});
    }
  }

  /// Opens the system multi-file picker and registers the picked files with
  /// the native server as a new send BATCH. The transfer page on the other
  /// device polls for a batch it has not received yet and starts saving the
  /// moment it sees one - no link is shown or clicked there. NO file copying
  /// happens here: the server streams the picked URIs directly, so large
  /// videos never block the UI.
  Future<void> _sendFilesToComputer() async {
    await _runPick(() async {
      final files = await FileBrowserService.instance.pickFiles();
      if (files.isEmpty || !mounted) return;
      await _service.shareFiles(files);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              files.length == 1
                  ? 'Sending 1 file'
                  : 'Sending ${files.length} files',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
  }

  /// Opens the system FOLDER picker, walks every file inside (recursively),
  /// and registers them with the native server. Same zero-copy flow as
  /// [_sendFilesToComputer] - the server streams the URIs directly. The
  /// folder structure travels in the names ("Folder/sub/file"), so the
  /// receiving page re-creates it in the folder the user picked there.
  Future<void> _sendFolderToComputer() async {
    await _runPick(() async {
      final files = await FileBrowserService.instance.pickFolderContents();
      if (files.isEmpty || !mounted) return;
      await _service.shareFiles(files);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              files.length == 1
                  ? 'Sending 1 file'
                  : 'Sending ${files.length} files',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
  }

  /// iOS only: opens the system Photos picker and sends the picked images
  /// through the same push flow. The native side copies each photo to a
  /// stable temp file (PHPicker URLs are temporary) and names it
  /// `Photos/<name>`, so the receiving page groups them into a folder.
  Future<void> _sendPhotosToComputer() async {
    await _runPick(() async {
      final photos = await FileBrowserService.instance.pickPhotos();
      if (photos.isEmpty || !mounted) return;
      await _service.shareFiles(photos);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              photos.length == 1
                  ? 'Sending 1 photo'
                  : 'Sending ${photos.length} photos',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _service.subscribeEvents();
    unawaited(_service.refresh());
    _userController.text = _service.username;
    _passController.text = _service.password;
    final savedPort = _service.port;
    final isDefault = savedPort == kWifiUploadDefaultPort;
    _portController.text = isDefault ? '' : '$savedPort';
  }

  @override
  void dispose() {
    _restartDebounce?.cancel();
    _pickProgressSub?.cancel();
    _service.unsubscribeEvents();
    _userController.dispose();
    _passController.dispose();
    _portController.dispose();
    super.dispose();
  }

  /// The port to start on. The field is optional: blank, or an out-of-range
  /// value, resolves to the default port.
  int get _resolvedPort => int.tryParse(_portController.text.trim()) ??
      kWifiUploadDefaultPort;

  bool get _portFieldValid {
    final raw = _portController.text.trim();
    if (raw.isEmpty) return true;
    final port = int.tryParse(raw);
    return port != null && port > 0 && port < 65536;
  }

  /// Both credentials are mandatory - they are the only thing standing
  /// between the open LAN and the device's storage.
  bool get _canStart =>
      _userController.text.trim().isNotEmpty &&
      _passController.text.isNotEmpty &&
      _portFieldValid;

  Future<void> _toggleServer() async {
    _restartDebounce?.cancel();
    if (_service.running) {
      await _service.stop();
      if (mounted) setState(() {});
      return;
    }
    await _service.start(port: _resolvedPort);
    if (mounted) setState(() {});
    if (!mounted) return;
    if (!_service.running && _service.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(_service.error!)),
            ],
          ),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  /// Every keystroke persists. A running server picks the new value up on a
  /// debounced restart (the native side reads credentials once at start).
  void _onFieldChanged() {
    setState(() {});
    unawaited(_saveFields());
    if (_service.running) {
      _restartDebounce?.cancel();
      _restartDebounce = Timer(
        const Duration(milliseconds: 700),
        () async {
          if (!_service.running || !mounted) return;
          await _service.stop();
          await _service.start(port: _resolvedPort);
          if (mounted) setState(() {});
        },
      );
    }
  }

  Future<void> _saveFields() async {
    await _service.setCredentials(
      _userController.text,
      _passController.text,
    );
    final raw = _portController.text.trim();
    if (raw.isNotEmpty) {
      final port = int.tryParse(raw);
      if (port != null && port > 0 && port < 65535) {
        await _service.setPort(port);
      }
    }
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Address copied')),
    );
  }

  /// Short form of the secondary address: `10.122.153.160` rather than a
  /// second full URL.
  String get _secondaryAddress {
    final urls = _service.urls;
    if (urls.length < 2) return '';
    final uri = Uri.tryParse(urls[1]);
    return uri?.authority ?? urls[1];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final running = _service.running;
    return Scaffold(
      appBar: AppBar(title: const Text('WiFi file transfer')),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final url = _service.urls.isNotEmpty ? _service.urls.first : null;
          final secondary = _secondaryAddress;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (running && url != null) ...[
                _RunningCard(
                  theme: theme,
                  colorScheme: colorScheme,
                  url: url,
                  secondary: secondary,
                  port: _service.port,
                  onCopy: () => _copyUrl(url),
                ),
              ],
              const SizedBox(height: 16),
              if (!running) ...[
                _LoginCard(
                  theme: theme,
                  colorScheme: colorScheme,
                  userController: _userController,
                  passController: _passController,
                  portController: _portController,
                  onChanged: _onFieldChanged,
                  canStart: _canStart,
                  portFieldValid: _portFieldValid,
                  obscurePassword: _obscurePassword,
                  onTogglePassword: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
                if (!running && !_canStart)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                    child: Text(
                      'Enter a username and password to start - the page is '
                      'password protected.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ),
              ],
              if (_service.error != null && !running)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                  child: Text(
                    _service.error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: running || _canStart ? () => _toggleServer() : null,
                  icon: Icon(
                    running ? Icons.stop : Icons.play_arrow,
                    color: colorScheme.onPrimary,
                  ),
                  label: Text(
                    running ? 'Stop service' : 'Start service',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // ---- Send files from this device to a computer ----
              // Two ways: pick individual files, or pick a whole folder.
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: running && !_picking ? _sendFilesToComputer : null,
                        icon: const Icon(Icons.send, size: 20),
                        label: const Text(
                          'Send files',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colorScheme.primary,
                          side: BorderSide(
                            color: colorScheme.primary.withValues(alpha: 0.5),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: running && !_picking ? _sendFolderToComputer : null,
                        icon: const Icon(Icons.folder_outlined, size: 20),
                        label: const Text(
                          'Send folder',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colorScheme.primary,
                          side: BorderSide(
                            color: colorScheme.primary.withValues(alpha: 0.5),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Photos-app picker exists on iOS only (PHPicker); Android
                  // users pick images through "Send files" instead.
                  if (Platform.isIOS) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: OutlinedButton.icon(
                          onPressed: running && !_picking ? _sendPhotosToComputer : null,
                          icon: const Icon(Icons.photo_library_outlined, size: 20),
                          label: const Text(
                            'Send photos',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colorScheme.primary,
                            side: BorderSide(
                              color: colorScheme.primary.withValues(alpha: 0.5),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              // Progress of the CURRENT send action. The pickers grey out
              // every Send button while they run, and the iOS photos picker
              // copies large videos one by one - so show how far along it is
              // instead of leaving the user staring at dead buttons and
              // force-closing the app. Determinate when the native picker
              // reports progress (iOS photos), indeterminate otherwise.
              if (_picking) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(
                            value: _pickTotal > 0 ? _pickDone / _pickTotal : null,
                            minHeight: 6,
                            backgroundColor:
                                colorScheme.surfaceContainerHighest,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _pickTotal > 0
                                ? 'Preparing $_pickDone of $_pickTotal...'
                                : 'Preparing...',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
              // Files registered as the current send batch: the transfer
              // page on the other device picks these up automatically.
              if (_service.sharedFiles.isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      'Sending to computer',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.clear_all, color: colorScheme.error),
                      tooltip: 'Clear shared files',
                      onPressed: _service.clearSharedFiles,
                      style: IconButton.styleFrom(
                        backgroundColor:
                            colorScheme.errorContainer.withValues(alpha: 0.3),
                        foregroundColor: colorScheme.error,
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final f in _service.sharedFiles)
                  _SharedFileRow(file: f),
              ],
              const SizedBox(height: 24),
              _TransfersHeader(service: _service),
              const SizedBox(height: 12),
              if (_service.uploads.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _EmptyTransfers(
                    theme: theme,
                    running: running,
                  ),
                )
              else
                for (final item in _service.uploads) _UploadRow(item: item),
            ],
          );
        },
      ),
    );
  }
}

/// Beautiful card shown while the server is running: address, copy action, and
/// status text, all in the app's accent colour.
class _RunningCard extends StatelessWidget {
  const _RunningCard({
    required this.theme,
    required this.colorScheme,
    required this.url,
    required this.secondary,
    required this.port,
    required this.onCopy,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;
  final String url;
  final String secondary;
  final int port;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Service running',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.content_copy,
                    color: colorScheme.primary,
                  ),
                  tooltip: 'Copy address',
                  padding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                  onPressed: onCopy,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SelectableText(
              url,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
            if (secondary.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Also on $secondary',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Open this address in a PC browser on the same Wi-Fi. The browser '
              'asks for your username and password each time. Uploaded videos '
              'appear in DreamPlayer automatically. The server keeps running '
              'while the screen is locked.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.lan,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Port $port · LAN only',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Beautiful login card shown while the server is stopped.
class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.theme,
    required this.colorScheme,
    required this.userController,
    required this.passController,
    required this.portController,
    required this.onChanged,
    required this.canStart,
    required this.portFieldValid,
    required this.obscurePassword,
    required this.onTogglePassword,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;
  final TextEditingController userController;
  final TextEditingController passController;
  final TextEditingController portController;
  final VoidCallback onChanged;
  final bool canStart;
  final bool portFieldValid;
  final bool obscurePassword;
  final VoidCallback onTogglePassword;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lock_outline,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text(
                  'Login',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'The browser asks for these before it shows the page. '
              'They are saved as you type.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            _StyledTextField(
              theme: theme,
              colorScheme: colorScheme,
              controller: userController,
              label: 'Username *',
              hint: 'e.g. admin',
              icon: Icons.person_outline,
              textInputAction: TextInputAction.next,
              onChanged: onChanged,
            ),
            const SizedBox(height: 12),
            _StyledTextField(
              theme: theme,
              colorScheme: colorScheme,
              controller: passController,
              label: 'Password *',
              hint: '••••••••',
              icon: Icons.lock_outline,
              obscureText: obscurePassword,
              textInputAction: TextInputAction.next,
              onChanged: onChanged,
              suffix: IconButton(
                icon: Icon(
                  obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: colorScheme.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: onTogglePassword,
                tooltip: obscurePassword ? 'Show password' : 'Hide password',
              ),
            ),
            const SizedBox(height: 12),
            _StyledTextField(
              theme: theme,
              colorScheme: colorScheme,
              controller: portController,
              label: 'Port (optional)',
              hint: '$kWifiUploadDefaultPort (default)',
              icon: Icons.numbers,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              errorText: portFieldValid ? null : '1 - 65535',
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _StyledTextField extends StatelessWidget {
  const _StyledTextField({
    required this.theme,
    required this.colorScheme,
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.textInputAction,
    this.keyboardType,
    this.inputFormatters,
    this.errorText,
    this.onChanged,
    this.suffix,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final TextInputAction? textInputAction;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? errorText;
  final VoidCallback? onChanged;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      textInputAction: textInputAction,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      onChanged: (_) => onChanged?.call(),
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
        prefixIcon: Icon(icon, color: colorScheme.primary),
        suffixIcon: suffix,
        errorText: errorText,
        errorStyle: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.error,
          fontSize: 11,
        ),
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: colorScheme.primary,
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: colorScheme.error,
          ),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: colorScheme.error,
            width: 1.5,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }
}

class _EmptyTransfers extends StatelessWidget {
  const _EmptyTransfers({
    required this.theme,
    required this.running,
  });

  final ThemeData theme;
  final bool running;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(
          running ? Icons.cloud_upload : Icons.file_present,
          size: 48,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 12),
        Text(
          running
              ? 'Nothing yet. Open the address above on a PC and pick videos to send.'
              : 'Fill in the login and press Start service.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _TransfersHeader extends StatelessWidget {
  const _TransfersHeader({required this.service});

  final WifiUploadService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final received = service.receivedBytes;
    return Row(
      children: [
        Text(
          'Transfers',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        if (received > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${service.receivedCount} files  ·  ${formatUploadBytes(received)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        if (service.uploads.isNotEmpty)
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              color: colorScheme.error,
            ),
            tooltip: 'Clear list',
            onPressed: service.clearUploads,
            style: IconButton.styleFrom(
              backgroundColor: colorScheme.errorContainer.withValues(alpha: 0.3),
              foregroundColor: colorScheme.error,
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
            ),
          ),
      ],
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.item});

  final WifiUploadItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final done = item.status == WifiUploadStatus.done;
    final failed = item.status == WifiUploadStatus.failed;
    final total = item.total;
    final active = item.status.isActive;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                done
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: Icon(
                          Icons.check_circle,
                          size: 18,
                          color: Colors.green.shade400,
                        ),
                      )
                    : Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: failed ? colorScheme.error : colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: failed ? colorScheme.error : null,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${formatUploadBytes(item.received)}'
                  '${total > 0 ? " / ${formatUploadBytes(total)}" : ""}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: failed
                    ? 1
                    : active
                        ? (item.progress > 0 ? item.progress : null)
                        : 1,
                minHeight: 6,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                  failed
                      ? colorScheme.error
                      : done
                          ? Colors.green.shade400
                          : colorScheme.primary,
                ),
              ),
            ),
            if (failed && item.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        item.error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One shared-file row: a file the user picked in-app to send to a PC.
/// Shows name + size; the PC downloads it from the transfer page.
class _SharedFileRow extends StatelessWidget {
  const _SharedFileRow({required this.file});

  final SharedFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.upload_file, size: 18, color: colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatUploadBytes(file.size),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
