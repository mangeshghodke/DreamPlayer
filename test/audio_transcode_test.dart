import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/audio_transcode_store.dart';

/// Issue #70: "Transcode audio to AC3 (Dolby Digital)" for HDMI receivers that
/// only support AC3. The Android Media3 path re-encodes decoded PCM to AC3 via
/// a minimal FFmpeg AC3-encoder JNI lib (same encoder as Kodi's AEEncoderFFmpeg)
/// and writes it IEC61937-packed to an AudioTrack; AC3 bitstreams still pass
/// through untouched. Pins the whole chain.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioTranscodeStore', () {
    test('pref key, default off, persists', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await AudioTranscodeStore.load(), isFalse);
      await AudioTranscodeStore.save(true);
      expect(await AudioTranscodeStore.load(), isTrue);
      expect(AudioTranscodeStore.prefsKey, 'dreamplayer.audioTranscodeAc3');
    });
  });

  group('native wiring (source-reading)', () {
    final root = Directory.current.path;
    String read(String p) => File('$root/$p').readAsStringSync();

    test('PlayerCodecs: transcode active only with pref + HDMI (or debug force)', () {
      final kt = read('android/app/src/main/kotlin/com/dreamplayer/app/PlayerCodecs.kt');
      expect(kt, contains('flutter.dreamplayer.audioTranscodeAc3'));
      expect(kt, contains('fun transcodeAc3Active(context: Context): Boolean'));
      expect(kt, contains('hasHdmiOutput(context)'));
      expect(kt, contains('audioTranscodeAc3Force')); // test escape hatch
      // only AC3 passes through when transcoding:
      expect(kt, contains('fun passthroughFormatWithTranscode('));
      expect(kt, contains('if (transcodeActive) return mimeType == MimeTypes.AUDIO_AC3'));
      // selector uses the effective rule
      expect(kt, contains('effectivePassthroughFormat(context, mimeType)'));
    });

    test('DreamRenderersFactory wraps the audio sink when transcoding is active', () {
      final f = read('android/app/src/main/kotlin/com/dreamplayer/app/DreamRenderersFactory.kt');
      expect(f, contains('if (PlayerCodecs.transcodeAc3Active(context))'));
      expect(f, contains('Ac3TranscodeSink(context, base)'));
    });

    test('Ac3TranscodeSink: PCM -> AC3 encoder -> IEC61937 AudioTrack; bitstreams delegate', () {
      final sink = read('android/app/src/main/kotlin/com/dreamplayer/app/Ac3TranscodeSink.kt');
      expect(sink, contains('AudioFormat.ENCODING_IEC61937'));
      expect(sink, contains('Ac3Encoder.nativeEncode('));
      expect(sink, contains('packAc3Iec61937('));
      expect(sink, contains('ForwardingAudioSink')); // bitstream passthrough via delegate
    });

    test('IEC packer + JNI encoder exist and CMake links the prebuilt ac3-only ffmpeg', () {
      final enc = read('android/app/src/main/kotlin/com/dreamplayer/app/Ac3Encoder.kt');
      expect(enc, contains('fun packAc3Iec61937(frame: ByteArray): ByteArray'));
      expect(enc, contains('0xF8.toByte()'));
      expect(enc, contains('System.loadLibrary("ac3enc")'));
      expect(enc, contains('AV_CODEC_ID_AC3'));
      final c = read('android/app/src/main/cpp/ac3enc_jni.c');
      expect(c, contains('avcodec_find_encoder(AV_CODEC_ID_AC3)'));
      expect(c, contains('AV_SAMPLE_FMT_S32P')); // ac3_fixed accepts S32P, not S16P
      final cmake = read('android/app/src/main/cpp/CMakeLists.txt');
      expect(cmake, contains('add_library(ac3enc SHARED ac3enc_jni.c)'));
      expect(cmake, contains('target_link_libraries(ac3enc avcodec avutil'));
    });

    test('ffmpeg ac3 build script pins encoder-only build for both ABIs', () {
      final sh = read('tool/build_ffmpeg_ac3.sh');
      expect(sh, contains('--disable-everything --enable-encoder=ac3_fixed'));
      expect(sh, contains('arm64-v8a'));
      expect(sh, contains('armeabi-v7a'));
    });

    test('release.yml builds the ac3 ffmpeg libs before the APKs', () {
      final yml = read('.github/workflows/release.yml');
      final at = yml.indexOf('build_ffmpeg_ac3.sh');
      expect(at, greaterThan(-1));
      expect(at, lessThan(yml.indexOf('flutter build apk --release')));
    });

    test('settings exposes the toggle (Android only) in the Audio section', () {
      final s = read('lib/screens/settings_screen.dart');
      expect(s, contains("title: const Text('Transcode audio to AC3 (Dolby Digital)')"));
      expect(s, contains('AudioTranscodeStore.save(value)'));
      expect(s, contains('if (defaultTargetPlatform == TargetPlatform.android)'));
      expect(s, contains('_audioTranscodeAc3'));
    });
  });
}
