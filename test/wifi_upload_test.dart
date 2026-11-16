import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/download_manager.dart';
import 'package:dream_player/services/wifi_upload.dart';

/// The WiFi file transfer page: the short URL shape, the per-transfer progress
/// model, and the fact that an uploaded file joins the SAME download history
/// that fills the home "Downloaded" grid.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('applyUploadEvent', () {
    WifiUploadItem receiving(String id) => WifiUploadItem(
          id: id,
          name: 'Movie.mkv',
          total: 1000,
          received: 0,
          status: WifiUploadStatus.receiving,
        );

    test('start puts the transfer at the top', () {
      final list = applyUploadEvent([receiving('a')], {
        'type': 'start',
        'id': 'b',
        'name': 'Other.mkv',
        'total': 500,
      });
      expect(list.length, 2);
      expect(list.first.id, 'b');
      expect(list.first.name, 'Other.mkv');
      expect(list.first.total, 500);
      expect(list.first.status, WifiUploadStatus.receiving);
    });

    test('start re-binds an existing id instead of duplicating it', () {
      final list = applyUploadEvent([receiving('a')], {
        'type': 'start',
        'id': 'a',
        'name': 'Movie.mkv',
        'total': 2000,
      });
      expect(list.length, 1);
      expect(list.single.total, 2000);
      expect(list.single.received, 0);
    });

    test('progress moves the received bytes', () {
      final list = applyUploadEvent([receiving('a')], {
        'type': 'progress',
        'id': 'a',
        'received': 400,
      });
      expect(list.single.received, 400);
      expect(list.single.progress, 0.4);
      expect(list.single.status, WifiUploadStatus.receiving);
    });

    test('progress for an unknown id is ignored', () {
      final list = applyUploadEvent([receiving('a')], {
        'type': 'progress',
        'id': 'zzz',
        'received': 400,
      });
      expect(list.single.received, 0);
    });

    test('done marks the row complete and keeps the bytes', () {
      final list = applyUploadEvent([receiving('a')], {
        'type': 'done',
        'id': 'a',
        'received': 1000,
      });
      expect(list.single.status, WifiUploadStatus.done);
      expect(list.single.received, 1000);
      expect(list.single.progress, 1.0);
    });

    test('failed marks the row with the error text', () {
      final list = applyUploadEvent([receiving('a')], {
        'type': 'failed',
        'id': 'a',
        'error': 'client closed early',
      });
      expect(list.single.status, WifiUploadStatus.failed);
      expect(list.single.error, 'client closed early');
    });

    test('stopped clears the list', () {
      final list = applyUploadEvent([receiving('a'), receiving('b')], {
        'type': 'stopped',
      });
      expect(list, isEmpty);
    });

    test('cancelled fails every in-flight row', () {
      // The page's (or the notification's) Cancel button: in-flight rows all
      // flip to failed; finished rows stay finished.
      final receivingA = WifiUploadItem(
        id: 'a',
        name: 'A.mkv',
        total: 100,
        received: 50,
        status: WifiUploadStatus.receiving,
      );
      final doneB = WifiUploadItem(
        id: 'b',
        name: 'B.mkv',
        total: 100,
        received: 100,
        status: WifiUploadStatus.done,
      );
      final list = applyUploadEvent([receivingA, doneB], {'type': 'cancelled'});
      expect(list[0].status, WifiUploadStatus.failed);
      expect(list[0].error, 'Cancelled');
      expect(list[1].status, WifiUploadStatus.done);
    });

    test('an unknown event type leaves the list untouched', () {
      final list = applyUploadEvent([receiving('a')], {'type': 'nonsense'});
      expect(list.single.id, 'a');
    });
  });

  group('WifiUploadItem.progress', () {
    test('clamps above 1', () {
      final item = WifiUploadItem(
        id: 'a',
        name: 'x.mkv',
        total: 100,
        received: 150,
        status: WifiUploadStatus.receiving,
      );
      expect(item.progress, 1.0);
    });

    test('an unknown total reports no fraction rather than a wrong one', () {
      final item = WifiUploadItem(
        id: 'a',
        name: 'x.mkv',
        total: 0,
        received: 900,
        status: WifiUploadStatus.receiving,
      );
      expect(item.progress, 0.0);
    });
  });

  group('clearing the transfer list', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('the clear button empties the list and the summary counters', () {
      // A finished upload: the row arrives, completes, and the file does
      // not exist, so only the Dart-side counters and the row update.
      final service = WifiUploadService.instance;
      service.applyEventForTest({
        'type': 'start',
        'id': 'a',
        'name': 'Movie.mkv',
        'total': 1000,
      });
      service.applyEventForTest({
        'type': 'progress',
        'id': 'a',
        'received': 1000,
      });
      service.applyEventForTest({
        'type': 'done',
        'id': 'a',
        'received': 1000,
        'path': '/definitely/not/here.mkv',
      });
      expect(service.uploads.length, 1);
      expect(service.receivedCount, 1);
      expect(service.receivedBytes, 1000);

      service.clearUploads();
      expect(service.uploads, isEmpty);
      expect(service.receivedCount, 0);
      expect(service.receivedBytes, 0);
    });
  });

  group('registerUploadedFile', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('adds a completed job so the file joins the Downloaded grid', () async {
      final dir = await Directory.systemTemp.createTemp('wifi-upload-test');
      final file = File('${dir.path}/Movie (2026).mkv');
      await file.writeAsBytes(List<int>.filled(2048, 0));

      await DownloadManager.instance.registerUploadedFile(
        path: file.path,
        bytes: 2048,
      );

      final jobs = DownloadManager.instance.downloads
          .where((j) => j.destPath == file.path)
          .toList();
      expect(jobs.length, 1);
      expect(jobs.single.title, 'Movie (2026).mkv');
      expect(jobs.single.status, DownloadStatus.completed);
      expect(jobs.single.totalBytes, 2048);
      expect(jobs.single.sourceType, 'upload');

      await dir.delete(recursive: true);
    });

    test('a re-upload of a deleted entry reuses it, no duplicate', () async {
      final dir = await Directory.systemTemp.createTemp('wifi-upload-test');
      final file = File('${dir.path}/Show.S01E01.mkv');
      await file.writeAsBytes(List<int>.filled(1024, 0));

      await DownloadManager.instance.registerUploadedFile(
        path: file.path,
        bytes: 1024,
      );
      await DownloadManager.instance.registerUploadedFile(
        path: file.path,
        bytes: 1024,
      );

      expect(
        DownloadManager.instance.downloads
            .where((j) => j.destPath == file.path)
            .length,
        1,
      );

      await dir.delete(recursive: true);
    });

    test('a missing file is not registered', () async {
      await DownloadManager.instance.registerUploadedFile(
        path: '/definitely/not/here.mkv',
        bytes: 10,
      );
      expect(
        DownloadManager.instance.downloads
            .where((j) => j.destPath == '/definitely/not/here.mkv'),
        isEmpty,
      );
    });
  });
}