// Native half of the experimental core-on-Android path (CLAUDE.md §3).
//
// Two jobs, both bridging mbgl-core (the FFI core .so) to the Flutter Android engine:
//
//  1. PRESENT: the core renders off-screen on its own thread; we copy each RGBA frame
//     into a Flutter SurfaceProducer's Surface via the NDK ANativeWindow API (a CPU
//     readback present — the analog of iOS CVPixelBuffer / Linux FlPixelBufferTexture,
//     no EGL, no Java per frame). The core's FFI copy/callback functions are passed in
//     as integer addresses (from Dart's MapLibreCoreMap.*FunctionAddress getters) and
//     reinterpret_cast — mirrors the iOS plugin; no dlsym for these.
//
//  2. HTTP: the NDK has no curl/TLS, so the core's mbgl::HTTPFileSource bridges every
//     request out to Kotlin OkHttp. We dlsym the core's mbl_android_http_* entry
//     points (exported from the core .so), register start/cancel handlers that call
//     into the MapLibreHttp Kotlin object, and feed OkHttp results back to the core.
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <jni.h>

#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

#define LOG_TAG "maplibre_core_jni"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace {

// ---- mbgl-core C ABI shapes (must match src/maplibre_flutter_core{,_android}.h) ----
using MblFrameCallback = void (*)(void* user);
using CopyFrameFn = int (*)(void* map, uint8_t* dst, size_t dst_capacity,
                            uint32_t* out_w, uint32_t* out_h, uint32_t* out_stride);
using SetFrameCallbackFn = void (*)(void* map, MblFrameCallback cb, void* user);

using MblAndroidHttpStart = void (*)(uint64_t request_id, const char* url, void* user);
using MblAndroidHttpCancel = void (*)(uint64_t request_id, void* user);
using SetHttpHandlerFn = void (*)(MblAndroidHttpStart, MblAndroidHttpCancel, void*);
using HttpRespondFn = void (*)(uint64_t request_id, int32_t status, const uint8_t* data,
                               size_t len, const char* etag, const char* expires);

// Zero-copy present entry points (core .so, dlsym'd alongside the HTTP ones).
using SetAndroidWindowFn = int (*)(void* map, void* native_window);
using ClearAndroidWindowFn = void (*)(void* map);
using ZeroCopyActiveFn = int (*)(void* map);

JavaVM* g_vm = nullptr;

// Core entry points (resolved once in nativeSetHttpHandler).
SetHttpHandlerFn g_set_handler = nullptr;
HttpRespondFn g_respond = nullptr;
SetAndroidWindowFn g_set_window = nullptr;
ClearAndroidWindowFn g_clear_window = nullptr;
ZeroCopyActiveFn g_zero_copy_active = nullptr;
jclass g_http_class = nullptr;   // global ref to MapLibreHttp
jmethodID g_http_start = nullptr;
jmethodID g_http_cancel = nullptr;
std::once_flag g_http_once;

// =====================  PRESENT  =====================

struct Presenter {
  ANativeWindow* window = nullptr;
  void* map = nullptr;
  CopyFrameFn copyFrame = nullptr;
  uint32_t geomW = 0;
  uint32_t geomH = 0;
  std::vector<uint8_t> scratch;
  std::mutex mutex; // serializes onFrameReady vs teardown on `window`
  bool dead = false;

  void present() {
    // While the core is presenting zero-copy (its own EGL window surface on the same
    // ANativeWindow), the CPU path must NOT also write to the window. If zero-copy
    // ever falls back, the flag flips false and this resumes.
    if (g_zero_copy_active != nullptr && map != nullptr && g_zero_copy_active(map)) {
      return;
    }
    std::lock_guard<std::mutex> lk(mutex);
    if (dead || window == nullptr || copyFrame == nullptr || map == nullptr) return;
    uint32_t w = 0, h = 0, stride = 0;
    if (copyFrame(map, nullptr, 0, &w, &h, &stride) == 0 || w == 0 || h == 0) return;
    if (w != geomW || h != geomH) {
      if (ANativeWindow_setBuffersGeometry(window, static_cast<int32_t>(w),
                                           static_cast<int32_t>(h),
                                           WINDOW_FORMAT_RGBA_8888) != 0) {
        LOGE("setBuffersGeometry(%u,%u) failed", w, h);
        return;
      }
      geomW = w;
      geomH = h;
    }
    const size_t need = static_cast<size_t>(stride) * h;
    if (scratch.size() < need) scratch.resize(need);
    if (copyFrame(map, scratch.data(), scratch.size(), &w, &h, &stride) == 0) return;
    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(window, &buf, nullptr) != 0) return;
    auto* dst = static_cast<uint8_t*>(buf.bits);
    const uint32_t copyH = h < static_cast<uint32_t>(buf.height)
                               ? h
                               : static_cast<uint32_t>(buf.height);
    const size_t rowBytes = static_cast<size_t>(stride);
    const size_t dstRowBytes = static_cast<size_t>(buf.stride) * 4;
    const size_t n = rowBytes < dstRowBytes ? rowBytes : dstRowBytes;
    for (uint32_t y = 0; y < copyH; ++y) {
      std::memcpy(dst + static_cast<size_t>(y) * dstRowBytes,
                  scratch.data() + static_cast<size_t>(y) * rowBytes, n);
    }
    ANativeWindow_unlockAndPost(window);
  }
};

void onFrameReady(void* user) { static_cast<Presenter*>(user)->present(); }

jlong nativeRegister(JNIEnv* env, jobject, jobject surface, jlong mapHandle,
                     jlong copyFrameFn, jlong setFrameCallbackFn, jboolean zeroCopy) {
  auto* p = new Presenter();
  p->window = ANativeWindow_fromSurface(env, surface); // +1 ref, released in unregister
  p->map = reinterpret_cast<void*>(mapHandle);
  p->copyFrame = reinterpret_cast<CopyFrameFn>(copyFrameFn);
  // Zero-copy present (opt-in): the core renders straight into this ANativeWindow's
  // EGL window surface (no readback). Try it FIRST — it must connect the window to the
  // EGL API before any CPU present, since ANativeWindow_lock would otherwise CPU-connect
  // it and eglCreateWindowSurface would then fail ("already connected to another API").
  // Only if zero-copy is off / doesn't come up do we register the CPU frame callback.
  int zc = (zeroCopy && g_set_window != nullptr) ? g_set_window(p->map, p->window) : 0;
  if (!zc) {
    reinterpret_cast<SetFrameCallbackFn>(setFrameCallbackFn)(p->map, &onFrameReady, p);
    p->present();
  }
  LOGI("registered presenter %p (window %p, zerocopy=%d)", p, p->window, zc);
  return reinterpret_cast<jlong>(p);
}

void nativeUnregister(JNIEnv*, jobject, jlong presenterHandle, jlong mapHandle,
                      jlong setFrameCallbackFn) {
  auto* p = reinterpret_cast<Presenter*>(presenterHandle);
  if (p == nullptr) return;
  reinterpret_cast<SetFrameCallbackFn>(setFrameCallbackFn)(
      reinterpret_cast<void*>(mapHandle), nullptr, nullptr);
  // Destroy the core's EGL window surface (zero-copy) BEFORE releasing the window, so
  // the core's ref on the ANativeWindow is dropped first.
  if (g_clear_window != nullptr) {
    g_clear_window(reinterpret_cast<void*>(mapHandle));
  }
  ANativeWindow* win = nullptr;
  {
    std::lock_guard<std::mutex> lk(p->mutex);
    p->dead = true;
    win = p->window;
    p->window = nullptr;
  }
  if (win != nullptr) ANativeWindow_release(win);
  delete p;
}

// =====================  HTTP  =====================

JNIEnv* attachedEnv() {
  JNIEnv* env = nullptr;
  if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) {
    return env;
  }
  // The core's file-source thread is a native thread; daemon-attach so it needs no
  // explicit detach when it exits.
  if (g_vm->AttachCurrentThreadAsDaemon(&env, nullptr) != JNI_OK) return nullptr;
  return env;
}

// Called by the core (on its file-source thread) to start a request.
void httpStart(uint64_t requestId, const char* url, void*) {
  JNIEnv* env = attachedEnv();
  if (env == nullptr || g_http_class == nullptr || g_http_start == nullptr) return;
  jstring jurl = env->NewStringUTF(url);
  env->CallStaticVoidMethod(g_http_class, g_http_start,
                            static_cast<jlong>(requestId), jurl);
  if (env->ExceptionCheck()) env->ExceptionClear();
  env->DeleteLocalRef(jurl);
}

void httpCancel(uint64_t requestId, void*) {
  JNIEnv* env = attachedEnv();
  if (env == nullptr || g_http_class == nullptr || g_http_cancel == nullptr) return;
  env->CallStaticVoidMethod(g_http_class, g_http_cancel, static_cast<jlong>(requestId));
  if (env->ExceptionCheck()) env->ExceptionClear();
}

// Resolve the core's HTTP entry points + cache the Kotlin MapLibreHttp handles, then
// register our start/cancel handlers. Idempotent (std::call_once).
void nativeSetHttpHandler(JNIEnv* env, jobject) {
  std::call_once(g_http_once, [env] {
    void* core = dlopen("libmaplibre_flutter_core.so", RTLD_NOW | RTLD_GLOBAL);
    if (core == nullptr) {
      LOGE("dlopen core failed: %s", dlerror());
      return;
    }
    g_set_handler =
        reinterpret_cast<SetHttpHandlerFn>(dlsym(core, "mbl_android_http_set_handler"));
    g_respond =
        reinterpret_cast<HttpRespondFn>(dlsym(core, "mbl_android_http_respond"));
    if (g_set_handler == nullptr || g_respond == nullptr) {
      LOGE("dlsym http symbols failed: %s", dlerror());
      return;
    }
    // Zero-copy present entry points (optional — CPU present is the fallback).
    g_set_window =
        reinterpret_cast<SetAndroidWindowFn>(dlsym(core, "mbl_map_set_android_window"));
    g_clear_window = reinterpret_cast<ClearAndroidWindowFn>(
        dlsym(core, "mbl_map_clear_android_window"));
    g_zero_copy_active = reinterpret_cast<ZeroCopyActiveFn>(
        dlsym(core, "mbl_map_android_zero_copy_active"));
    jclass local = env->FindClass(
        "dev/maplibreflutter/maplibre_flutter_android/MapLibreHttp");
    if (local == nullptr) {
      LOGE("FindClass MapLibreHttp failed");
      return;
    }
    g_http_class = static_cast<jclass>(env->NewGlobalRef(local));
    g_http_start = env->GetStaticMethodID(g_http_class, "start", "(JLjava/lang/String;)V");
    g_http_cancel = env->GetStaticMethodID(g_http_class, "cancel", "(J)V");
    g_set_handler(&httpStart, &httpCancel, nullptr);
    LOGI("http handler registered");
  });
}

// Called by Kotlin (on an OkHttp thread) when a request completes.
void nativeHttpRespond(JNIEnv* env, jobject, jlong requestId, jint status,
                       jbyteArray body, jstring etag) {
  if (g_respond == nullptr) return;
  jbyte* bytes = nullptr;
  jsize len = 0;
  if (body != nullptr) {
    len = env->GetArrayLength(body);
    bytes = env->GetByteArrayElements(body, nullptr);
  }
  const char* etagStr = etag != nullptr ? env->GetStringUTFChars(etag, nullptr) : nullptr;
  g_respond(static_cast<uint64_t>(requestId), static_cast<int32_t>(status),
            reinterpret_cast<const uint8_t*>(bytes), static_cast<size_t>(len),
            etagStr, nullptr);
  if (etagStr != nullptr) env->ReleaseStringUTFChars(etag, etagStr);
  if (bytes != nullptr) env->ReleaseByteArrayElements(body, bytes, JNI_ABORT);
}

const JNINativeMethod kMethods[] = {
    {"nativeRegister", "(Landroid/view/Surface;JJJZ)J",
     reinterpret_cast<void*>(nativeRegister)},
    {"nativeUnregister", "(JJJ)V", reinterpret_cast<void*>(nativeUnregister)},
    {"nativeSetHttpHandler", "()V", reinterpret_cast<void*>(nativeSetHttpHandler)},
    {"nativeHttpRespond", "(JI[BLjava/lang/String;)V",
     reinterpret_cast<void*>(nativeHttpRespond)},
};

} // namespace

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
  g_vm = vm;
  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  jclass cls = env->FindClass(
      "dev/maplibreflutter/maplibre_flutter_android/MapLibreCoreBridge");
  if (cls == nullptr) return JNI_ERR;
  if (env->RegisterNatives(cls, kMethods,
                           sizeof(kMethods) / sizeof(kMethods[0])) != JNI_OK) {
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}
