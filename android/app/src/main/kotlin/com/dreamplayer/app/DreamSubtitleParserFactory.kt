package com.dreamplayer.app

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.text.Cue
import androidx.media3.common.util.Consumer
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import androidx.media3.extractor.text.vobsub.VobsubParser
import com.google.common.collect.ImmutableList
import java.util.regex.Pattern

/// Global subtitle timing offset (µs). Set from `ExoPlayerView.applySubtitleStyle`
/// via the `delayMs` channel arg. Applied at parse time so every cue's
/// `startTimeUs` is shifted — positive = show later, negative = earlier.
/// Applied to every format (both our custom parsers and the delegate's) so
/// embedded + sideloaded subtitles share the same delay. Takes effect on the
/// next `open()` (re-open the video to see a live-changed delay).
@UnstableApi
object SubtitleTiming {
    @Volatile var delayUs: Long = 0L
}

/// Carries the VobSub `.idx` descriptor from `open()` to
/// [DreamSubtitleParserFactory.create].
///
/// Media3's `VobsubParser` is built as `new VobsubParser(format.initializationData)`,
/// and in-container VobSub (MKV `S_VOBSUB`) gets that data from the container's
/// `CodecPrivate`. A *sidecar* pair has no CodecPrivate, and
/// `MediaItem.SubtitleConfiguration` in 1.10.x has no `initializationData` field
/// to hand it over through (verified against `media3-common-1.10.1`). There is
/// also no VobSub `SubtitleExtractor`, so nothing else can supply it either.
///
/// So we pass it out-of-band: `open()` reads the `.idx` (a ~120 KB text file)
/// and stashes it here before `setMediaItem`, and `create()` builds the stock
/// `VobsubParser` from it. That keeps Media3's own well-tested bitmap decoder
/// instead of reimplementing DVD subtitle RLE/CLUT decoding here.
///
/// Reset on every `open()` so a stale index from a previous file can never be
/// paired with the next one.
@UnstableApi
object VobSubInitializationData {
    @Volatile
    var sections: List<ByteArray>? = null

    fun set(idx: ByteArray?) {
        sections = idx?.let { ImmutableList.of(it) }
    }

    fun clear() {
        sections = null
    }
}

/// Placeholder for a sidecar VobSub track on the Media3 engine.
///
/// **Deliberately renders nothing.** What is proven, and what is not:
///
/// * Media3's `VobsubParser` is a good decoder. Muxing this exact VobSub into
///   an MKV and playing it produces a correct cue.
/// * It only accepts Matroska `S_VOBSUB` framing -- a bare run of DVD subtitle
///   packets. A sidecar `.sub` is a whole MPEG-Program-Stream with each cue
///   fragmented across several PES frames, so the raw bytes decode to nothing.
/// * [VobSubPayloadExtractor] performs that demux correctly: byte-identical to
///   ffmpeg's own vobsub demuxer on the reporter's file (2736 of 2737 cues).
///
/// Two integrations of that demux were attempted and both are recorded here so
/// neither is retried blind:
///
///  1. Emitting every cue inside the single `parse()` call Media3 makes for a
///     sidecar. All 2737 packets recovered, but >16k `Unrecognized command`
///     warnings and the video stopped playing while the track was selected.
///  2. Decoding lazily from the player position tick. `SubtitleParser` is a
///     *pull* contract: Media3 calls `parse()` and we emit through the `output`
///     consumer, which is only valid for the duration of that call. Cues decoded
///     later, outside it, have no route to Media3's renderer, so this can never
///     display anything.
///
/// Doing this properly needs a different integration than a `SubtitleParser` --
/// feeding Media3's subtitle sample queue directly, or rendering cues ourselves.
/// That is a real piece of work, not a patch, and a half-wired version is worse
/// than none: a dead player or a runaway decoder is exactly what issue #44 was
/// filed about.
///
/// Users with a sidecar VobSub can play it on the libmpv engine, which renders
/// it (positioned per the file's own `align:` directive).
@UnstableApi
private class UnsupportedVobSubSidecarParser(
    private val idxBytes: Int,
) : SubtitleParser {

    override fun getCueReplacementBehavior(): Int =
        Format.CUE_REPLACEMENT_BEHAVIOR_MERGE

    override fun parse(
        data: ByteArray,
        offset: Int,
        length: Int,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
    ) {
        android.util.Log.w(
            "DreamSub",
            "sidecar VobSub not decoded on Media3 (idx=$idxBytes bytes, " +
                "payload=$length bytes); use the MPV engine for this track",
        )
    }
}

/// Emits nothing.
///
/// Used when a `application/vobsub` track arrives without its `.idx`. The
/// alternative — letting the parser fail on a missing descriptor, or letting a
/// text parser chew the binary `.sub` — is what crashed the player on issue
/// #44. A blank subtitle track is the safe degradation.
@UnstableApi
private class EmptySubtitleParser : SubtitleParser {
    override fun getCueReplacementBehavior(): Int =
        Format.CUE_REPLACEMENT_BEHAVIOR_MERGE

    override fun parse(
        data: ByteArray,
        offset: Int,
        length: Int,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
    ) {
        android.util.Log.w(
            "DreamSub",
            "vobsub track had no .idx descriptor; dropping ${length} bytes " +
                "(a blank subtitle track beats a crash)",
        )
    }
}

/// Media3's stock [DefaultSubtitleParserFactory] handles SubRip, SSA/ASS,
/// WebVTT, TTML, TX3G, PGS, VobSub and DVB — but not the classic text formats
/// SAMI (`.smi`), MicroDVD (`.sub`), MPL2 (`.mpl2`) or SubViewer (time-based
/// `.sub`). This factory adds those and delegates everything else to the
/// default one, so sideloaded subtitle configs carrying
/// [SubtitleFormats.MIME_SAMI] / [SubtitleFormats.MIME_MICRODVD] /
/// [SubtitleFormats.MIME_MPL2] resolve to our parsers.
///
/// VobSub is the one format the stock factory *does* support but cannot be
/// reached with: see [VobSubInitializationData].
///
/// Wire it via `DefaultMediaSourceFactory(context, extractorsFactory,
/// DreamSubtitleParserFactory())` (and on `DefaultExtractorsFactory`) so the
/// `SubtitleExtractor` used for sideloaded subtitles picks it up.
@UnstableApi
class DreamSubtitleParserFactory(
    private val delegate: SubtitleParser.Factory = DefaultSubtitleParserFactory(),
) : SubtitleParser.Factory {

    override fun supportsFormat(format: Format): Boolean {
        return when (format.sampleMimeType) {
            SubtitleFormats.MIME_SAMI,
            SubtitleFormats.MIME_MICRODVD,
            SubtitleFormats.MIME_MPL2,
            SubtitleFormats.MIME_VOBSUB,
            -> true
            else -> delegate.supportsFormat(format)
        }
    }

    override fun getCueReplacementBehavior(format: Format): Int {
        return when (format.sampleMimeType) {
            SubtitleFormats.MIME_SAMI -> SamiParser.CUE_REPLACEMENT_BEHAVIOR
            SubtitleFormats.MIME_MICRODVD, SubtitleFormats.MIME_MPL2 ->
                FrameSubParser.CUE_REPLACEMENT_BEHAVIOR
            SubtitleFormats.MIME_VOBSUB -> VobsubParser.CUE_REPLACEMENT_BEHAVIOR
            else -> delegate.getCueReplacementBehavior(format)
        }
    }

    override fun create(format: Format): SubtitleParser {
        val base: SubtitleParser = when (format.sampleMimeType) {
            SubtitleFormats.MIME_SAMI -> SamiParser()
            SubtitleFormats.MIME_MICRODVD -> FrameSubParser(FrameSubParser.Mode.MICRODVD)
            SubtitleFormats.MIME_MPL2 -> FrameSubParser(FrameSubParser.Mode.MPL2)
            SubtitleFormats.MIME_VOBSUB -> {
                val idx = VobSubInitializationData.sections
                android.util.Log.i(
                    "DreamSub",
                    "create vobsub: idxSections=${idx?.size ?: -1} " +
                        "bytes=${idx?.firstOrNull()?.size ?: -1}",
                )
                if (idx.isNullOrEmpty()) EmptySubtitleParser()
                else UnsupportedVobSubSidecarParser(idx.first().size)
            }
            else -> delegate.create(format)
        }
        return if (SubtitleTiming.delayUs == 0L) base else DelayingParser(base)
    }
}

/// Wraps any [SubtitleParser] and shifts every emitted cue's `startTimeUs` by
/// [SubtitleTiming.delayUs]. Positive = subtitles appear later.
@UnstableApi
private class DelayingParser(
    private val delegate: SubtitleParser,
) : SubtitleParser {
    override fun getCueReplacementBehavior(): Int = delegate.getCueReplacementBehavior()
    override fun reset() = delegate.reset()
    override fun parse(
        data: ByteArray,
        offset: Int,
        length: Int,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
    ) {
        val delay = SubtitleTiming.delayUs
        if (delay == 0L) {
            delegate.parse(data, offset, length, outputOptions, output)
            return
        }
        delegate.parse(data, offset, length, outputOptions, Consumer { cwt ->
            // Shift the cue's presentation time; duration stays the same.
            val shifted = CuesWithTiming(cwt.cues, cwt.startTimeUs + delay, cwt.durationUs)
            output.accept(shifted)
        })
    }
}

/// Base class for our text parsers. Media3's `SubtitleExtractor` buffers the
/// whole file and calls `parse` once with all bytes, so each parser reads the
/// full buffer into lines and emits one [CuesWithTiming] per cue.
@UnstableApi
abstract class LineSubtitleParser : SubtitleParser {

    override fun reset() {}

    /// Emits [cue] at [startTimeUs] for [durationUs], honoring the same
    /// `OutputOptions` filtering `SubripParser` applies: cues that start at or
    /// after the requested seek point go out immediately; when seeking with
    /// `outputAllCues` set, earlier cues are deferred and flushed at the end so
    /// `SubtitleExtractor` can still build its seek map.
    protected fun emit(
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
        startTimeUs: Long,
        durationUs: Long,
        cue: Cue,
        deferred: MutableList<CuesWithTiming>,
    ) {
        val endTimeUs = if (durationUs == 0L) startTimeUs else startTimeUs + durationUs
        if (outputOptions.startTimeUs == C.TIME_UNSET || endTimeUs >= outputOptions.startTimeUs) {
            output.accept(CuesWithTiming(ImmutableList.of(cue), startTimeUs, durationUs))
        } else if (outputOptions.outputAllCues) {
            deferred.add(CuesWithTiming(ImmutableList.of(cue), startTimeUs, durationUs))
        }
    }

    /// Builds a plain-text cue. `\N` (SSA convention) and `\n` become line
    /// breaks in the rendered subtitle.
    protected fun cue(text: String): Cue = Cue.Builder().setText(text).build()
}

/// Parses SAMI (`.smi`) files: `<SYNC Start=ms><P ...>text` blocks with HTML
/// tags in the text. A cue spans from its `<SYNC>` start until the next
/// `<SYNC>` (SAMI has no explicit end times), so durations are computed from
/// the following block.
@UnstableApi
class SamiParser : LineSubtitleParser() {

    companion object {
        const val CUE_REPLACEMENT_BEHAVIOR: Int = Format.CUE_REPLACEMENT_BEHAVIOR_MERGE
        private val SYNC_START =
            Pattern.compile("<SYNC\\s+Start\\s*=\\s*(\\d+)", Pattern.CASE_INSENSITIVE)
        private val TAG_STRIP = Pattern.compile("<[^>]+>")
        private val ENTITIES = mapOf(
            "&nbsp;" to " ",
            "&amp;" to "&",
            "&lt;" to "<",
            "&gt;" to ">",
            "&quot;" to "\"",
        )
    }

    override fun getCueReplacementBehavior(): Int = CUE_REPLACEMENT_BEHAVIOR

    override fun parse(
        data: ByteArray,
        offset: Int,
        length: Int,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
    ) {
        val text = SubtitleFormats.decodeToString(data, offset, length)
        val deferred = ArrayList<CuesWithTiming>()

        // Collect (startUs, body) pairs.
        data class Block(val startUs: Long, val body: String)

        val blocks = ArrayList<Block>()
        var pendingStart: Long? = null
        val pending = StringBuilder()

        fun flushBlock() {
            val start = pendingStart ?: return
            val body = pending.toString().trim()
            pendingStart = null
            pending.setLength(0)
            if (body.isEmpty()) return
            blocks.add(Block(start, clean(body)))
        }

        for (line in text.split("\r\n", "\n")) {
            val m = SYNC_START.matcher(line)
            if (m.find()) {
                flushBlock()
                pendingStart = m.group(1).toLongOrNull()?.times(1000)
            } else if (pendingStart != null) {
                pending.append(line).append("\n")
            }
        }
        flushBlock()

        for ((i, block) in blocks.withIndex()) {
            val durationUs = if (i + 1 < blocks.size) {
                blocks[i + 1].startUs - block.startUs
            } else {
                // Last block: show it for 5 s, or let it persist until the end
                // of the media (SubtitleExtractor will just keep it selected).
                5_000_000L
            }
            if (block.body.isNotEmpty()) {
                emit(outputOptions, output, block.startUs, durationUs, cue(block.body), deferred)
            }
        }
        deferred.forEach { output.accept(it) }
    }

    private fun clean(body: String): String {
        var s = TAG_STRIP.matcher(body).replaceAll("")
        for ((entity, replacement) in ENTITIES) {
            s = s.replace(entity, replacement)
        }
        return s.trim()
    }
}

/// Parses frame-timed text subtitles: MicroDVD (`.sub`, `{start}{end}text`,
/// FPS from the `{1}{1}25.000` header line, default 25) and MPL2 (`.mpl2`,
/// `[start][end]text`, default 25). A few `.sub` files are actually SubViewer
/// (time-based `HH:MM:SS.cc,HH:MM:SS.cc` lines); when no frame line is found
/// that format is used instead.
@UnstableApi
class FrameSubParser(
    private val mode: Mode,
) : LineSubtitleParser() {

    enum class Mode { MICRODVD, MPL2 }

    companion object {
        const val CUE_REPLACEMENT_BEHAVIOR: Int = Format.CUE_REPLACEMENT_BEHAVIOR_MERGE
        private const val DEFAULT_FPS = 25.0
        private val MICRODVD_LINE = Pattern.compile("^\\{\\s*(\\d+)\\s*\\}\\{\\s*(\\d+)\\s*\\}\\s*(.*)$")
        private val MPL2_LINE = Pattern.compile("^\\[\\s*(\\d+)\\s*\\]\\[\\s*(\\d+)\\s*\\]\\s*(.*)$")
        private val MICRODVD_FPS =
            Pattern.compile("^\\{\\s*1\\s*\\}\\{\\s*1\\s*\\}\\s*([0-9]*\\.?[0-9]+)\\s*$")
        private val SUBVIEWER_TIME = Pattern.compile(
            "^(\\d{1,2}):(\\d{2}):(\\d{2})[.,](\\d{1,3})\\s*,\\s*(\\d{1,2}):(\\d{2}):(\\d{2})[.,](\\d{1,3})\\s*$",
        )
        private val TAG_STRIP = Pattern.compile("\\{[^}]*}")
    }

    override fun getCueReplacementBehavior(): Int = CUE_REPLACEMENT_BEHAVIOR

    override fun parse(
        data: ByteArray,
        offset: Int,
        length: Int,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
    ) {
        val text = SubtitleFormats.decodeToString(data, offset, length)
        val lines = text.split("\r\n", "\n")
        val deferred = ArrayList<CuesWithTiming>()

        // MicroDVD may declare FPS in a `{1}{1}25.000` header line.
        var fps = DEFAULT_FPS
        if (mode == Mode.MICRODVD) {
            for (line in lines.take(10)) {
                val m = MICRODVD_FPS.matcher(line.trim())
                if (m.matches()) {
                    // A header of exactly "0" (or unparseable) must not reach
                    // parseFrames — dividing by it there produces Infinity,
                    // which .toLong() turns into Long.MAX_VALUE and corrupts
                    // the whole track's cue timing.
                    fps = m.group(1).toDoubleOrNull()?.takeIf { it > 0.0 } ?: DEFAULT_FPS
                    break
                }
            }
        }

        val firstContent = lines.firstOrNull { it.isNotBlank() } ?: ""
        val isSubViewer = mode == Mode.MICRODVD &&
            !MICRODVD_LINE.matcher(firstContent).matches() &&
            SUBVIEWER_TIME.matcher(firstContent).matches()

        if (isSubViewer) {
            parseSubViewer(lines, outputOptions, output, deferred)
        } else {
            parseFrames(lines, fps, outputOptions, output, deferred)
        }
        deferred.forEach { output.accept(it) }
    }

    private fun parseFrames(
        lines: List<String>,
        fps: Double,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
        deferred: MutableList<CuesWithTiming>,
    ) {
        val pattern = if (mode == Mode.MICRODVD) MICRODVD_LINE else MPL2_LINE
        for (line in lines) {
            val m = pattern.matcher(line.trim())
            if (!m.matches()) continue
            val startFrame = m.group(1).toLongOrNull() ?: continue
            val endFrame = m.group(2).toLongOrNull() ?: continue
            if (endFrame <= startFrame) continue
            // MPL2's `[N]` is a fixed unit — tenths of a second — not a frame
            // number, so it must NOT go through the fps-based conversion
            // (that formula is MicroDVD-only and made every .mpl2 file run
            // 2.5x too fast at the default 25 fps).
            val startUs: Long
            val endUs: Long
            if (mode == Mode.MPL2) {
                startUs = startFrame * 100_000L
                endUs = endFrame * 100_000L
            } else {
                startUs = (startFrame * 1_000_000.0 / fps).toLong()
                endUs = (endFrame * 1_000_000.0 / fps).toLong()
            }
            val body = TAG_STRIP.matcher(m.group(3)).replaceAll("").trim()
            if (body.isEmpty()) continue
            emit(outputOptions, output, startUs, endUs - startUs, cue(body), deferred)
        }
    }

    private fun parseSubViewer(
        lines: List<String>,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
        deferred: MutableList<CuesWithTiming>,
    ) {
        var i = 0
        while (i < lines.size) {
            val m = SUBVIEWER_TIME.matcher(lines[i].trim())
            if (!m.matches()) {
                i++
                continue
            }
            val startUs = timeToUs(m, 1)
            val endUs = timeToUs(m, 5)
            i++
            val body = StringBuilder()
            while (i < lines.size && lines[i].isNotBlank()) {
                if (body.isNotEmpty()) body.append("\n")
                body.append(lines[i].trim())
                i++
            }
            if (body.isNotEmpty() && endUs > startUs) {
                emit(outputOptions, output, startUs, endUs - startUs, cue(body.toString()), deferred)
            }
            i++
        }
    }

    private fun timeToUs(m: java.util.regex.Matcher, groupOffset: Int): Long {
        val h = m.group(groupOffset).toLong()
        val min = m.group(groupOffset + 1).toLong()
        val s = m.group(groupOffset + 2).toLong()
        val frac = m.group(groupOffset + 3).padEnd(3, '0').toLong()
        return ((h * 3600 + min * 60 + s) * 1000 + frac) * 1000
    }
}
