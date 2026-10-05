import 'dart:async';

/// Bounded, deferrable queue for the *speculative* TMDB lookups a file browser
/// fires when a folder listing arrives.
///
/// ## Why this exists
///
/// Every network browser (SMB / WebDAV / FTP / UPnP) used to loop over the
/// freshly listed entries and start one `TmdService.resolve()` (or
/// `resolveFolder()`) per entry, **immediately and unbounded**. Folder entries
/// additionally ran `ImageCacheService.prefetchImages()`, so opening a share
/// root with a few hundred rows could kick off hundreds of TMDB searches and
/// artwork downloads at once — each artwork write is `flush: true`, i.e. an
/// fsync. That burst starved the raster pipeline badly enough on iOS that the
/// *next* screen's first frame was delayed by up to 60 s: the user taps a file,
/// the details screen has its metadata ready in 2 ms, and yet the spinner keeps
/// turning for a minute before the page appears. Reopening the same file is
/// then 24 ms, because by then every lookup and every poster is cached.
///
/// Metadata prefetch is genuinely worth keeping — it is what makes a tap a
/// cache hit instead of a spinner. It just must never run ahead of the frame
/// the user is waiting for, and it must never run unbounded.
///
/// ## Contract
///
/// * At most [maxConcurrent] lookups are in flight; the rest wait their turn.
/// * The first kick is delayed by [startDelay] so the frame that is already on
///   screen wins. Later drains are immediate (we are already off the frame).
/// * [reset] cancels everything queued and invalidates in-flight work by
///   bumping [generation]; call it when the folder changes or the screen is
///   disposed. A task whose captured generation is stale never runs.
///
/// Callers capture `generation` when they enqueue and bail if it changed by the
/// time the task would start, so a stale folder's results can't repaint the
/// screen after the user has navigated away.
class TmdbPrefetchQueue {
  TmdbPrefetchQueue({
    this.maxConcurrent = 3,
    this.startDelay = const Duration(milliseconds: 250),
  });

  /// Lookups allowed in flight at once. Matches the episode-still prefetch
  /// throttle (`maxStillsInFlight`) for the same reason: enough to feel
  /// instant, few enough not to saturate the network and the disk.
  final int maxConcurrent;

  /// Grace period before the speculative work starts. Speculative by
  /// definition — it must never delay the frame the user is looking at.
  final Duration startDelay;

  final List<_PrefetchTask> _pending = [];
  int _active = 0;
  int _generation = 0;
  Timer? _kick;

  int get generation => _generation;

  /// Queued + running tasks. Exposed for diagnostics.
  int get pendingCount => _pending.length + _active;

  /// Invalidates everything queued so far and orphans in-flight results.
  void reset() {
    _generation++;
    _pending.clear();
    _kick?.cancel();
    _kick = null;
  }

  void dispose() => reset();

  /// Queues [task] behind at most [maxConcurrent] siblings.
  ///
  /// [generation] must be the queue's [generation] at enqueue time; a mismatch
  /// means the folder changed and the task is dropped.
  void add(int generation, Future<void> Function() task) {
    if (generation != _generation) return;
    _pending.add(_PrefetchTask(generation, task));
    _scheduleDrain(deferred: _active == 0);
  }

  void _scheduleDrain({bool deferred = false}) {
    if (_active >= maxConcurrent || _pending.isEmpty) return;
    if (deferred) {
      _kick?.cancel();
      _kick = Timer(startDelay, () {
        _kick = null;
        _drain();
      });
      return;
    }
    _drain();
  }

  void _drain() {
    while (_active < maxConcurrent && _pending.isNotEmpty) {
      final task = _pending.removeAt(0);
      if (task.generation != _generation) continue;
      _active++;
      // `try/finally` rather than `whenComplete`: a task that throws
      // synchronously would otherwise leak the in-flight slot and permanently
      // shrink the concurrency budget.
      Future<void>(() async {
        try {
          await task.task();
        } catch (_) {
          // Speculative work — a failed lookup must never surface.
        } finally {
          _active--;
          _scheduleDrain();
        }
      });
    }
  }
}

class _PrefetchTask {
  _PrefetchTask(this.generation, this.task);

  final int generation;
  final Future<void> Function() task;
}