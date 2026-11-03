import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/config/crash_report_endpoint.dart';
import 'package:dream_player/services/crash_report_upload.dart';

void main() {
  group('buildMultipartBody', () {
    test('a text field part has disposition and content, no filename', () {
      final body = buildMultipartBody(
        [CrashReportPart(name: 'message', bytes: utf8.encode('crashed on open'))],
        boundary: 'BND',
      );
      final text = utf8.decode(body);
      expect(text, contains('--BND\r\n'));
      expect(text, contains('Content-Disposition: form-data; name="message"\r\n\r\n'));
      expect(text, contains('crashed on open\r\n'));
      expect(text, endsWith('--BND--\r\n'));
      expect(text, isNot(contains('filename=')));
    });

    test('a file part carries filename and content type', () {
      final body = buildMultipartBody(
        [CrashReportPart(name: 'logs', fileName: 'dreamplayer_crash.log', bytes: [1, 2, 3])],
        boundary: 'BND',
      );
      final text = latin1.decode(body);
      expect(
        text,
        contains(
          'Content-Disposition: form-data; name="logs"; filename="dreamplayer_crash.log"\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n\r\n',
        ),
      );
      // Raw file bytes survive the round trip: the part content is exactly
      // the bytes between the header's blank line and the closing boundary.
      final headerEnd = text.indexOf('\r\n\r\n') + 4;
      expect(body.sublist(headerEnd, headerEnd + 3), [1, 2, 3]);
    });

    test('multiple parts are separated by the boundary and closed once', () {
      final body = buildMultipartBody(
        [
          CrashReportPart(name: 'a', bytes: utf8.encode('1')),
          CrashReportPart(name: 'b', bytes: utf8.encode('2')),
        ],
        boundary: 'X',
      );
      final text = utf8.decode(body);
      expect(text.split('--X\r\n').length - 1, 2);
      expect(text, endsWith('--X--\r\n'));
    });
  });

  test('endpoint comes from the dart-define and defaults to empty', () {
    // In tests no define is passed, so the fallback path (share sheet) is
    // what would be taken.
    expect(crashReportEndpoint, isEmpty);
  });

  test('upload sends the shared secret as a Bearer header when configured', () {
    final src = File('lib/services/crash_report_upload.dart').readAsStringSync();
    expect(src, contains('crashReportSecret'));
    expect(src, contains("authorizationHeader, 'Bearer \$crashReportSecret'"));
    // The endpoint/secret are dart-defines, never hardcoded URLs.
    final cfg = File('lib/config/crash_report_endpoint.dart').readAsStringSync();
    expect(cfg, contains("String.fromEnvironment('CRASH_REPORT_ENDPOINT')"));
    expect(cfg, contains("String.fromEnvironment('CRASH_REPORT_SECRET')"));
    // The worker source must never contain the secret value.
    final worker = File('cloudflare/crash-report/src/index.ts').readAsStringSync();
    expect(worker, isNot(contains('Bearer cfat')));
    expect(worker, contains('env.CRASH_REPORT_SECRET'));
  });

  test('iOS signed builds forward the crash-report defines to the IPA', () {
    // Without these in signing_setup.py the TestFlight build ships with an
    // empty endpoint and silently falls back to the share sheet.
    final signing = File('ios/signing_setup.py').readAsStringSync();
    expect(signing, contains("'CRASH_REPORT_ENDPOINT'"));
    expect(signing, contains("'CRASH_REPORT_SECRET'"));
    final wf = File('.github/workflows/ios.yml').readAsStringSync();
    expect(wf, contains('secrets.CRASH_REPORT_ENDPOINT'));
    expect(wf, contains('secrets.CRASH_REPORT_SECRET'));
  });
}
