import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/tmdb_prefetch_queue.dart';

void main() {
  test('bounds concurrency and defers the first kick', () async {
    final q = TmdbPrefetchQueue(
      maxConcurrent: 3,
      startDelay: const Duration(milliseconds: 10),
    );
    var active = 0;
    var peak = 0;
    final started = <int>[];
    final gate = Completer<void>();

    for (var i = 0; i < 20; i++) {
      q.add(q.generation, () async {
        active++;
        peak = active > peak ? active : peak;
        started.add(i);
        await gate.future;
        active--;
      });
    }

    // Nothing runs before startDelay — the frame the user is waiting for wins.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(started, isEmpty, reason: 'must not start synchronously');

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(peak, 3, reason: 'never more than maxConcurrent in flight');
    expect(started.length, 3, reason: 'exactly the window is released');

    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(started.length, 20, reason: 'queue drains fully');
    expect(q.pendingCount, 0);
  });

  test('reset drops queued work and orphans in-flight results', () async {
    final q = TmdbPrefetchQueue(
      maxConcurrent: 1,
      startDelay: const Duration(milliseconds: 5),
    );
    final ran = <int>[];
    final gate = Completer<void>();

    q.add(q.generation, () async {
      ran.add(0);
      await gate.future;
    });
    for (var i = 1; i < 10; i++) {
      q.add(q.generation, () async => ran.add(i));
    }

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(ran, [0], reason: 'only the window is running');

    // User navigated to another folder.
    q.reset();
    expect(q.generation, isNot(0));
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(ran, [0], reason: 'stale queued work must never run');
  });

  test('a task enqueued with a stale generation is dropped', () async {
    final q = TmdbPrefetchQueue(
      maxConcurrent: 2,
      startDelay: const Duration(milliseconds: 5),
    );
    final stale = q.generation;
    q.reset();
    var ran = false;
    q.add(stale, () async => ran = true);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(ran, isFalse);
  });

  test('a throwing task does not leak its in-flight slot', () async {
    final q = TmdbPrefetchQueue(
      maxConcurrent: 1,
      startDelay: const Duration(milliseconds: 5),
    );
    final ran = <int>[];
    for (var i = 0; i < 4; i++) {
      q.add(q.generation, () async {
        ran.add(i);
        throw StateError('boom');
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(ran.length, 4, reason: 'a throw must not shrink the budget');
  });
}