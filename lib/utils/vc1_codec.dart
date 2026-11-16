/// VC-1 detection (issue #51).
///
/// VC-1 comes in three profiles and the distinction decides whether the
/// default engine can play it:
///
///  * **Simple / Main** - old hardware decoders, when present, handle these.
///  * **Advanced** (`WVC1`) - essentially no Android device has a hardware
///    decoder for it, yet the platform still *advertises* VC-1.
///
/// That combination is the bug. Media3 picks the advertised decoder, it
/// initialises, and it then emits black frames **without raising an error**,
/// so an error-triggered software fallback never fires. Audio and subtitles are
/// separate pipelines and keep working, which is what makes it look like a
/// rendering fault rather than a decode fault.
///
/// The ExoPlayer maintainer names the same mechanism: "not all decoders fail
/// with error in these cases. Some will 'decode' frames, but show black screen
/// or distorted image… it is decoders fault to not indicate error when
/// unsupported profile is passed for decode" (google/ExoPlayer#8393).
///
/// There is no Media3-path software decoder for VC-1 - Media3's own FFmpeg
/// extension lists audio decoders only, and nextlib's video renderer claims
/// avc/hevc alone. libmpv ships full FFmpeg and plays it, which is why "Play
/// with MPV" is the working answer rather than a fallback we can select
/// internally.
///
/// Just Player (moneytoo/Player) is pure Media3 and has the identical black
/// screen; its maintainer tells users to use mpv. Nova does support VC-1, but
/// via its own C FFmpeg core, not a library we can drop in.
library;

/// True when [value] names VC-1, in either the codec or MIME spelling.
///
/// Containers report VC-1 several ways: `wvc1` (Advanced, the FOURCC seen in
/// Matroska `V_MS/VFW/FOURCC`), `vc1`/`VC-1`, and the MIME `video/vc1`.
/// Media3 usually surfaces the MIME type and a `codecs` string like
/// `wvc1.Advanced.L3`, so both are checked.
bool isVc1Codec(String? value) {
  if (value == null || value.isEmpty) return false;
  // Normalise the hyphen so `VC-1` is read as the same codec as `vc1`.
  final v = value.toLowerCase().replaceAll('-', '');
  // Strip a MIME prefix so `video/vc1` matches on its token.
  final primary = (v.contains('/') ? v.substring(v.lastIndexOf('/') + 1) : v)
      .split(RegExp(r'[.\s]'))
      .first;
  return primary == 'vc1' || primary == 'wvc1' || v.contains('video/vc1');
}

/// True when [codecs] reports the VC-1 **Advanced** profile.
///
/// Advanced is the only profile worth warning about: Simple/Main are the ones
/// hardware may genuinely decode. The profile appears as a suffix on the codecs
/// string - `wvc1.Advanced.L3`, `vc1.Advanced` - and is absent for Simple/Main,
/// which is why the absence of it must NOT be read as "advanced".
bool isVc1AdvancedProfile(String? codecs) {
  if (codecs == null || !isVc1Codec(codecs)) return false;
  return codecs.toLowerCase().contains('advanced');
}

/// Whether the default engine should warn about this video track.
///
/// Deliberately true for **any** VC-1 signal, not only Advanced. Two reasons:
///
///  * Android has no practical VC-1 *hardware* decoder at all. VC-1 is legacy
///    - Simple and Main included - so warning on them too costs only a
///    suggestion the user can ignore.
///  * The profile is often missing from what Media3 reports. Warning only on a
///    confirmed `Advanced` would silently miss the exact file in issue #51
///    whenever the profile string is absent, which is precisely the case that
///    cannot be verified in advance.
///
/// A black screen with working audio and subtitles is the worst failure mode
/// there is, and the suggestion is cheap. See [isVc1AdvancedProfile] for the
/// precise predicate, used to word the message.
bool shouldWarnVc1({String? codecs, String? mime}) =>
    isVc1Codec(codecs) || isVc1Codec(mime);