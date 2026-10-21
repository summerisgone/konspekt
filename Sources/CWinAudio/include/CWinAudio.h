#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Sample rate of every capture stream, Float32 interleaved.
#define KW_SAMPLE_RATE 48000
#define KW_LOOPBACK_CHANNELS 2
#define KW_MIC_CHANNELS 1

typedef struct kw_session {
    uint32_t pid;
    int32_t capture;  // 1: capture endpoint (microphone), 0: render endpoint
    int32_t active;   // 1: AudioSessionStateActive
} kw_session;

/// Audio sessions of all active render and capture endpoints.
/// Returns the number written to `out` (at most `max`), or a negative HRESULT.
int32_t kw_list_sessions(kw_session *out, int32_t max);

/// Full image path of a process, UTF-8, NUL-terminated. Returns the length, 0 on failure.
int32_t kw_process_path(uint32_t pid, char *buf, int32_t len);

/// Receives `frames` interleaved frames on the capture thread.
typedef void (*kw_sink)(void *ctx, const float *samples, uint32_t frames);

typedef struct kw_capture kw_capture;

/// What the process tree of `pid` plays, KW_LOOPBACK_CHANNELS channels.
/// Gaps without packets are filled with silence, so the stream follows wall-clock time.
/// Returns an HRESULT; on success `*out` must be released with kw_stop.
int32_t kw_start_process_loopback(uint32_t pid, kw_sink sink, void *ctx, kw_capture **out);

/// The default capture device, KW_MIC_CHANNELS channels.
int32_t kw_start_mic(kw_sink sink, void *ctx, kw_capture **out);

/// Stops capture and waits for the capture thread; no sink calls after it returns.
void kw_stop(kw_capture *c);

#ifdef __cplusplus
}
#endif
