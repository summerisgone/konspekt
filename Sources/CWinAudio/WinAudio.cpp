#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmreg.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <audioclientactivationparams.h>
#include <wrl/client.h>

#include <algorithm>
#include <vector>

#include "CWinAudio.h"

using Microsoft::WRL::ComPtr;

namespace {

// A stream is padded with silence when it falls behind wall-clock time by more than kGap
// (no packets while the process is silent or the device stalls); padding leaves kLag behind.
constexpr uint64_t kGap = KW_SAMPLE_RATE / 5;
constexpr uint64_t kLag = KW_SAMPLE_RATE / 20;
constexpr REFERENCE_TIME kBufferDuration = 2000000;  // 200 ms

void ensureCom() {
    // S_FALSE / RPC_E_CHANGED_MODE: COM is already initialized on this thread, which is fine.
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
}

WAVEFORMATEX floatFormat(WORD channels) {
    WAVEFORMATEX f = {};
    f.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    f.nChannels = channels;
    f.nSamplesPerSec = KW_SAMPLE_RATE;
    f.wBitsPerSample = 32;
    f.nBlockAlign = static_cast<WORD>(channels * 4);
    f.nAvgBytesPerSec = KW_SAMPLE_RATE * f.nBlockAlign;
    return f;
}

class ActivationHandler final : public IActivateAudioInterfaceCompletionHandler, public IAgileObject {
public:
    ActivationHandler() : done_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
    ~ActivationHandler() { CloseHandle(done_); }

    STDMETHODIMP QueryInterface(REFIID riid, void **out) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
            *out = static_cast<IActivateAudioInterfaceCompletionHandler *>(this);
        } else if (riid == __uuidof(IAgileObject)) {
            *out = static_cast<IAgileObject *>(this);
        } else {
            *out = nullptr;
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs_); }
    STDMETHODIMP_(ULONG) Release() override {
        ULONG r = InterlockedDecrement(&refs_);
        if (r == 0) delete this;
        return r;
    }

    STDMETHODIMP ActivateCompleted(IActivateAudioInterfaceAsyncOperation *op) override {
        ComPtr<IUnknown> unk;
        HRESULT activated = E_FAIL;
        result_ = op->GetActivateResult(&activated, &unk);
        if (SUCCEEDED(result_)) result_ = activated;
        if (SUCCEEDED(result_)) result_ = unk.As(&client_);
        SetEvent(done_);
        return S_OK;
    }

    HRESULT wait(ComPtr<IAudioClient> &client) {
        if (WaitForSingleObject(done_, 10000) != WAIT_OBJECT_0) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        client = client_;
        return result_;
    }

private:
    LONG refs_ = 1;
    HANDLE done_;
    HRESULT result_ = E_FAIL;
    ComPtr<IAudioClient> client_;
};

}  // namespace

struct kw_capture {
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    HANDLE event = nullptr;
    HANDLE stop = nullptr;
    HANDLE thread = nullptr;
    uint32_t channels = 0;
    kw_sink sink = nullptr;
    void *ctx = nullptr;
};

namespace {

DWORD WINAPI captureThread(void *param) {
    auto *c = static_cast<kw_capture *>(param);
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    LARGE_INTEGER freq, t0;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    auto elapsed = [&]() -> uint64_t {
        LARGE_INTEGER now;
        QueryPerformanceCounter(&now);
        return static_cast<uint64_t>(now.QuadPart - t0.QuadPart) * KW_SAMPLE_RATE / freq.QuadPart;
    };

    uint64_t written = 0;
    std::vector<float> zeros;
    auto silence = [&](uint64_t frames) {
        while (frames > 0) {
            uint32_t n = static_cast<uint32_t>(std::min<uint64_t>(frames, KW_SAMPLE_RATE / 10));
            zeros.assign(static_cast<size_t>(n) * c->channels, 0.0f);
            c->sink(c->ctx, zeros.data(), n);
            written += n;
            frames -= n;
        }
    };

    c->client->Start();
    HANDLE waits[2] = {c->stop, c->event};
    for (;;) {
        if (WaitForMultipleObjects(2, waits, FALSE, 100) == WAIT_OBJECT_0) break;
        for (;;) {
            UINT32 packet = 0;
            if (FAILED(c->capture->GetNextPacketSize(&packet)) || packet == 0) break;
            BYTE *data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            if (FAILED(c->capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) break;
            uint64_t now = elapsed();
            if (now > written + frames + kGap) silence(now - written - frames - kLag);
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                silence(frames);
            } else {
                c->sink(c->ctx, reinterpret_cast<const float *>(data), frames);
                written += frames;
            }
            c->capture->ReleaseBuffer(frames);
        }
        uint64_t now = elapsed();
        if (now > written + kGap) silence(now - written - kLag);
    }
    c->client->Stop();
    CoUninitialize();
    return 0;
}

HRESULT startCapture(ComPtr<IAudioClient> client, DWORD flags, WORD channels, kw_sink sink, void *ctx,
                     kw_capture **out) {
    WAVEFORMATEX fmt = floatFormat(channels);
    flags |= AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
             AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    HRESULT hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, kBufferDuration, 0, &fmt, nullptr);
    if (FAILED(hr)) return hr;

    auto *c = new kw_capture();
    c->client = client;
    c->channels = channels;
    c->sink = sink;
    c->ctx = ctx;
    c->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    c->stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (SUCCEEDED(hr)) hr = client->SetEventHandle(c->event);
    if (SUCCEEDED(hr)) hr = client->GetService(IID_PPV_ARGS(&c->capture));
    if (SUCCEEDED(hr)) {
        c->thread = CreateThread(nullptr, 0, captureThread, c, 0, nullptr);
        if (!c->thread) hr = HRESULT_FROM_WIN32(GetLastError());
    }
    if (FAILED(hr)) {
        kw_stop(c);
        return hr;
    }
    *out = c;
    return S_OK;
}

}  // namespace

extern "C" {

int32_t kw_list_sessions(kw_session *out, int32_t max) {
    ensureCom();
    ComPtr<IMMDeviceEnumerator> devices;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices));
    if (FAILED(hr)) return hr;
    int32_t n = 0;
    for (EDataFlow flow : {eRender, eCapture}) {
        ComPtr<IMMDeviceCollection> endpoints;
        if (FAILED(devices->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &endpoints))) continue;
        UINT count = 0;
        endpoints->GetCount(&count);
        for (UINT i = 0; i < count; i++) {
            ComPtr<IMMDevice> device;
            ComPtr<IAudioSessionManager2> manager;
            ComPtr<IAudioSessionEnumerator> sessions;
            if (FAILED(endpoints->Item(i, &device))) continue;
            if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, &manager))) continue;
            if (FAILED(manager->GetSessionEnumerator(&sessions))) continue;
            int sessionCount = 0;
            sessions->GetCount(&sessionCount);
            for (int j = 0; j < sessionCount && n < max; j++) {
                ComPtr<IAudioSessionControl> control;
                ComPtr<IAudioSessionControl2> control2;
                if (FAILED(sessions->GetSession(j, &control)) || FAILED(control.As(&control2))) continue;
                DWORD pid = 0;
                AudioSessionState state = AudioSessionStateInactive;
                // AUDCLNT_S_NO_SINGLE_PROCESS is a success code with no usable pid; pid stays 0.
                control2->GetProcessId(&pid);
                if (pid == 0 || FAILED(control2->GetState(&state))) continue;
                out[n++] = kw_session{pid, flow == eCapture ? 1 : 0, state == AudioSessionStateActive ? 1 : 0};
            }
        }
    }
    return n;
}

int32_t kw_process_path(uint32_t pid, char *buf, int32_t len) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return 0;
    wchar_t wide[MAX_PATH * 4];
    DWORD size = static_cast<DWORD>(sizeof(wide) / sizeof(wide[0]));
    BOOL ok = QueryFullProcessImageNameW(process, 0, wide, &size);
    CloseHandle(process);
    if (!ok || len <= 0) return 0;
    int written = WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(size), buf, len - 1, nullptr, nullptr);
    buf[written > 0 ? written : 0] = 0;
    return written > 0 ? written : 0;
}

int32_t kw_start_process_loopback(uint32_t pid, kw_sink sink, void *ctx, kw_capture **out) {
    ensureCom();
    AUDIOCLIENT_ACTIVATION_PARAMS params = {};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = pid;
    params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT activation = {};
    activation.vt = VT_BLOB;
    activation.blob.cbSize = sizeof(params);
    activation.blob.pBlobData = reinterpret_cast<BYTE *>(&params);

    auto *handler = new ActivationHandler();
    ComPtr<IActivateAudioInterfaceAsyncOperation> op;
    HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
                                             &activation, handler, &op);
    ComPtr<IAudioClient> client;
    if (SUCCEEDED(hr)) hr = handler->wait(client);
    handler->Release();
    if (FAILED(hr)) return hr;
    return startCapture(client, AUDCLNT_STREAMFLAGS_LOOPBACK, KW_LOOPBACK_CHANNELS, sink, ctx, out);
}

int32_t kw_start_mic(kw_sink sink, void *ctx, kw_capture **out) {
    ensureCom();
    ComPtr<IMMDeviceEnumerator> devices;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices));
    if (SUCCEEDED(hr)) hr = devices->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
    if (SUCCEEDED(hr)) hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client);
    if (FAILED(hr)) return hr;
    return startCapture(client, 0, KW_MIC_CHANNELS, sink, ctx, out);
}

void kw_stop(kw_capture *c) {
    if (!c) return;
    if (c->thread) {
        SetEvent(c->stop);
        WaitForSingleObject(c->thread, INFINITE);
        CloseHandle(c->thread);
    }
    if (c->event) CloseHandle(c->event);
    if (c->stop) CloseHandle(c->stop);
    delete c;
}

}  // extern "C"

#endif  // _WIN32
