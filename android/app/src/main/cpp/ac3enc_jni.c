/*
 * ac3enc_jni.c - JNI wrapper around a minimal static FFmpeg build that
 * contains ONLY the AC3 encoder (tool/build_ffmpeg_ac3.sh). This is the same
 * encoder Kodi's CAEEncoderFFmpeg uses for "transcode to Dolby Digital"
 * (xbmc/cores/AudioEngine/Encoders/AEEncoderFFmpeg.cpp: avcodec_find_encoder(
 * AV_CODEC_ID_AC3), S16P planar input, 1536-sample frames).
 *
 * The resulting raw AC3 frames are IEC61937-packed in Kotlin
 * (Ac3Iec61937.kt, per IEC 61937-1 / Kodi's CAEPackIEC61937::PackAC3) and
 * written to an AudioTrack created with AudioFormat.ENCODING_IEC61937.
 */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>

#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>

#define TAG "ac3enc"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define AC3_FRAME_SAMPLES 1536

typedef struct {
    AVCodecContext *ctx;
    AVFrame *frame;
    AVPacket *pkt;
    /* planar s16 FIFO: fifo[ch * fifoCap + sample] */
    int16_t *fifo;
    int fifoCap;       /* per-channel capacity in samples */
    int fifoSamples;   /* samples per channel currently buffered */
    int channels;
    int frameSize;     /* encoder frame size in samples per channel */
} Ac3Enc;

static void ac3enc_close_ctx(Ac3Enc *e) {
    if (!e) return;
    if (e->ctx) avcodec_free_context(&e->ctx);
    if (e->frame) av_frame_free(&e->frame);
    if (e->pkt) av_packet_free(&e->pkt);
    free(e->fifo);
    free(e);
}

JNIEXPORT jlong JNICALL
Java_com_dreamplayer_app_Ac3Encoder_nativeOpen(JNIEnv *env, jclass clazz,
                                                jint sampleRate, jint channels,
                                                jint bitRate) {
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_AC3);
    if (!codec) { LOGE("no AC3 encoder in this ffmpeg build"); return 0; }
    Ac3Enc *e = calloc(1, sizeof(Ac3Enc));
    if (!e) return 0;
    e->ctx = avcodec_alloc_context3(codec);
    if (!e->ctx) { ac3enc_close_ctx(e); return 0; }
    e->channels = channels;
    e->ctx->sample_rate = sampleRate;
    e->ctx->bit_rate = bitRate;
    av_channel_layout_default(&e->ctx->ch_layout, channels);
    e->ctx->sample_fmt = AV_SAMPLE_FMT_S16P; /* the fixed-point AC3 encoder's input */
    if (avcodec_open2(e->ctx, codec, NULL) < 0) {
        LOGE("avcodec_open2 failed");
        ac3enc_close_ctx(e);
        return 0;
    }
    e->frameSize = e->ctx->frame_size > 0 ? e->ctx->frame_size : AC3_FRAME_SAMPLES;
    e->frame = av_frame_alloc();
    e->pkt = av_packet_alloc();
    if (!e->frame || !e->pkt) { ac3enc_close_ctx(e); return 0; }
    e->frame->format = AV_SAMPLE_FMT_S16P;
    e->frame->nb_samples = e->frameSize;
    e->frame->sample_rate = sampleRate;
    av_channel_layout_copy(&e->frame->ch_layout, &e->ctx->ch_layout);
    if (av_frame_get_buffer(e->frame, 0) < 0) { ac3enc_close_ctx(e); return 0; }
    e->fifo = malloc((size_t)e->frameSize * channels * sizeof(int16_t));
    if (!e->fifo) { ac3enc_close_ctx(e); return 0; }
    e->fifoCap = e->frameSize;
    e->fifoSamples = 0;
    LOGI("opened: rate=%d ch=%d br=%d frameSize=%d", sampleRate, channels, bitRate, e->frameSize);
    return (jlong)(intptr_t)e;
}

/*
 * Feeds interleaved little-endian s16 PCM; returns concatenated raw AC3
 * frames (may be empty while the encoder buffers a partial frame).
 */
JNIEXPORT jbyteArray JNICALL
Java_com_dreamplayer_app_Ac3Encoder_nativeEncode(JNIEnv *env, jclass clazz,
                                                  jlong handle, jbyteArray pcm,
                                                  jint samplesPerChannel) {
    Ac3Enc *e = (Ac3Enc *)(intptr_t)handle;
    if (!e || !pcm) return NULL;
    jbyte *in = (*env)->GetByteArrayElements(env, pcm, NULL);
    if (!in) return NULL;

    /* grow the planar FIFO if needed */
    int needed = e->fifoSamples + samplesPerChannel;
    if (needed > e->fifoCap) {
        int newCap = e->fifoCap;
        while (newCap < needed) newCap *= 2;
        int16_t *nf = malloc((size_t)newCap * e->channels * sizeof(int16_t));
        if (nf) {
            for (int c = 0; c < e->channels; c++) {
                memcpy(nf + (size_t)c * newCap, e->fifo + (size_t)c * e->fifoCap,
                       (size_t)e->fifoSamples * sizeof(int16_t));
            }
            free(e->fifo);
            e->fifo = nf;
            e->fifoCap = newCap;
        }
    }
    /* de-interleave appended at the tail: fifo[ch * fifoCap + sample] */
    for (int c = 0; c < e->channels; c++) {
        int16_t *dst = e->fifo + (size_t)c * e->fifoCap + e->fifoSamples;
        const int16_t *src = (const int16_t *)(in + c * 2);
        for (int i = 0; i < samplesPerChannel; i++) {
            dst[i] = src[(size_t)i * e->channels];
        }
    }
    e->fifoSamples += samplesPerChannel;

    /* encode whole frames, shifting each channel's FIFO down */
    size_t written = 0;
    uint8_t out[8192];
    while (e->fifoSamples >= e->frameSize) {
        av_frame_make_writable(e->frame);
        for (int c = 0; c < e->channels; c++) {
            int16_t *src = e->fifo + (size_t)c * e->fifoCap;
            memcpy(e->frame->data[c], src, (size_t)e->frameSize * sizeof(int16_t));
            memmove(src, src + e->frameSize,
                    (size_t)(e->fifoSamples - e->frameSize) * sizeof(int16_t));
        }
        e->fifoSamples -= e->frameSize;
        if (avcodec_send_frame(e->ctx, e->frame) < 0) continue;
        while (avcodec_receive_packet(e->ctx, e->pkt) == 0) {
            if (written + (size_t)e->pkt->size <= sizeof(out)) {
                memcpy(out + written, e->pkt->data, e->pkt->size);
                written += e->pkt->size;
            }
            av_packet_unref(e->pkt);
        }
    }
    (*env)->ReleaseByteArrayElements(env, pcm, in, JNI_ABORT);
    if (written == 0) return NULL;
    jbyteArray result = (*env)->NewByteArray(env, (jsize)written);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)written, (const jbyte *)out);
    return result;
}

JNIEXPORT jbyteArray JNICALL
Java_com_dreamplayer_app_Ac3Encoder_nativeFlush(JNIEnv *env, jclass clazz, jlong handle) {
    Ac3Enc *e = (Ac3Enc *)(intptr_t)handle;
    if (!e) return NULL;
    uint8_t out[8192];
    size_t written = 0;
    if (avcodec_send_frame(e->ctx, NULL) == 0) {
        while (avcodec_receive_packet(e->ctx, e->pkt) == 0) {
            if (written + (size_t)e->pkt->size <= sizeof(out)) {
                memcpy(out + written, e->pkt->data, e->pkt->size);
                written += e->pkt->size;
            }
            av_packet_unref(e->pkt);
        }
    }
    e->fifoSamples = 0;
    if (written == 0) return NULL;
    jbyteArray result = (*env)->NewByteArray(env, (jsize)written);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)written, (const jbyte *)out);
    return result;
}

JNIEXPORT void JNICALL
Java_com_dreamplayer_app_Ac3Encoder_nativeClose(JNIEnv *env, jclass clazz, jlong handle) {
    ac3enc_close_ctx((Ac3Enc *)(intptr_t)handle);
}
