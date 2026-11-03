import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/crash_report_endpoint.dart';

/// One file part of the multipart body, kept pure so it is unit-testable.
class CrashReportPart {
  const CrashReportPart({required this.name, this.fileName, required this.bytes});

  final String name;
  final String? fileName;
  final List<int> bytes;
}

/// Builds a multipart/form-data body. Pure and synchronous so tests can
/// assert the exact wire shape.
List<int> buildMultipartBody(List<CrashReportPart> parts, {required String boundary}) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(utf8.encode('--$boundary\r\n'));
    final disposition = part.fileName == null
        ? 'Content-Disposition: form-data; name="${part.name}"\r\n\r\n'
        : 'Content-Disposition: form-data; name="${part.name}"; '
            'filename="${part.fileName}"\r\n'
            'Content-Type: text/plain; charset=utf-8\r\n\r\n';
    builder.add(utf8.encode(disposition));
    builder.add(part.bytes);
    builder.add(utf8.encode('\r\n'));
  }
  builder.add(utf8.encode('--$boundary--\r\n'));
  return builder.toBytes();
}

class CrashReportUpload {
  CrashReportUpload._();

  static bool get isConfigured => crashReportEndpoint.isNotEmpty;

  /// Uploads [filePaths] plus the user's [message] to the configured
  /// endpoint as multipart/form-data. Returns the HTTP status code;
  /// throws on network errors.
  static Future<int> upload({
    required List<String> filePaths,
    required String message,
  }) async {
    final boundary =
        'dreamplayer${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';
    final parts = <CrashReportPart>[
      CrashReportPart(
        name: 'message',
        bytes: utf8.encode(message),
      ),
      CrashReportPart(
        name: 'platform',
        bytes: utf8.encode(defaultTargetPlatform.name),
      ),
      CrashReportPart(
        name: 'appVersion',
        bytes: utf8.encode((await PackageInfo.fromPlatform()).version),
      ),
    ];
    for (final path in filePaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      parts.add(CrashReportPart(
        name: 'logs',
        fileName: file.path.split('/').last,
        bytes: await file.readAsBytes(),
      ));
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(Uri.parse(crashReportEndpoint));
      request.headers.contentType = ContentType(
        'multipart',
        'form-data',
        parameters: {'boundary': boundary},
      );
      request.headers.contentLength = -1; // chunked
      request.add(buildMultipartBody(parts, boundary: boundary));
      final response = await request.close();
      // Drain so the connection can be reused/closed cleanly.
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }
}
