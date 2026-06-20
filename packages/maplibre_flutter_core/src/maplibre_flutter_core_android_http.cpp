// Android HTTP file source for the NDK core (experimental core-on-Android, CLAUDE.md
// §3). Replaces the default-platform curl http_file_source.cpp: curl on the NDK needs
// a bundled TLS stack + CA store and hits the async-DNS pitfalls Windows did, so we
// implement mbgl::HTTPFileSource here and bridge HTTP out to the host app's OkHttp
// over the C API in maplibre_flutter_core_android.h (system trust store + TLS for
// free, the way the real MapLibre Android SDK does it, but decoupled from mbgl's JNI
// framework). The plugin's JNI layer provides the start/cancel handlers and feeds
// results back via mbl_android_http_respond.
//
// Threading: request() runs on the OnlineFileSource's thread (which owns a RunLoop);
// we capture that RunLoop so a response delivered from an arbitrary OkHttp thread is
// marshaled back onto it before invoking mbgl's callback (mbgl is thread-affine).
#include "maplibre_flutter_core_android.h"

#include <mbgl/storage/http_file_source.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/storage/response.hpp>
#include <mbgl/util/async_request.hpp>
#include <mbgl/util/chrono.hpp>
#include <mbgl/util/client_options.hpp>
#include <mbgl/util/run_loop.hpp>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace mbgl {

namespace {

class HTTPAndroidRequest; // fwd

struct HostHandler {
  MblAndroidHttpStart start = nullptr;
  MblAndroidHttpCancel cancel = nullptr;
  void *user = nullptr;
};

struct Registry {
  std::mutex mutex;
  HostHandler handler;
  std::atomic<uint64_t> nextId{1};
  // request_id -> {request, the run loop request() was issued on}.
  std::unordered_map<uint64_t, std::pair<HTTPAndroidRequest *, util::RunLoop *>> live;
};

Registry &registry() {
  static Registry r;
  return r;
}

class HTTPAndroidRequest : public AsyncRequest {
public:
  HTTPAndroidRequest(uint64_t id_, FileSource::Callback &&cb)
      : id(id_), callback(std::move(cb)) {}

  ~HTTPAndroidRequest() override {
    MblAndroidHttpCancel cancel = nullptr;
    void *user = nullptr;
    {
      std::lock_guard<std::mutex> lk(registry().mutex);
      registry().live.erase(id);
      cancel = registry().handler.cancel;
      user = registry().handler.user;
    }
    if (cancel != nullptr) cancel(id, user);
  }

  // Called on the file-source run loop (the thread that created this request).
  void deliver(const Response &response) { callback(response); }

  const uint64_t id;

private:
  FileSource::Callback callback;
};

} // namespace

class HTTPFileSource::Impl {
public:
  Impl(const ResourceOptions &ro, const ClientOptions &co)
      : resourceOptions(ro.clone()), clientOptions(co.clone()) {}
  ResourceOptions resourceOptions;
  ClientOptions clientOptions;
};

HTTPFileSource::HTTPFileSource(const ResourceOptions &resourceOptions,
                               const ClientOptions &clientOptions)
    : impl(std::make_unique<Impl>(resourceOptions, clientOptions)) {}

HTTPFileSource::~HTTPFileSource() = default;

std::unique_ptr<AsyncRequest> HTTPFileSource::request(const Resource &resource,
                                                      Callback callback) {
  auto &reg = registry();
  const uint64_t id = reg.nextId.fetch_add(1);
  auto request = std::make_unique<HTTPAndroidRequest>(id, std::move(callback));

  MblAndroidHttpStart start = nullptr;
  void *user = nullptr;
  util::RunLoop *loop = util::RunLoop::Get();
  {
    std::lock_guard<std::mutex> lk(reg.mutex);
    reg.live[id] = {request.get(), loop};
    start = reg.handler.start;
    user = reg.handler.user;
  }

  if (start != nullptr) {
    start(id, resource.url.c_str(), user);
  } else {
    // No host handler registered — fail asynchronously on the next loop turn so we
    // never invoke the callback inline from request().
    if (auto *l = util::RunLoop::Get()) {
      l->invoke([id] {
        Response response;
        response.error = std::make_unique<Response::Error>(
            Response::Error::Reason::Other,
            "maplibre_flutter_core: no Android HTTP handler registered");
        auto &r = registry();
        HTTPAndroidRequest *req = nullptr;
        {
          std::lock_guard<std::mutex> lk(r.mutex);
          auto it = r.live.find(id);
          if (it == r.live.end()) return;
          req = it->second.first;
        }
        req->deliver(response); // lock released — callback may delete req
      });
    }
  }
  return request;
}

void HTTPFileSource::setResourceOptions(ResourceOptions options) {
  impl->resourceOptions = options.clone();
}
ResourceOptions HTTPFileSource::getResourceOptions() {
  return impl->resourceOptions.clone();
}
void HTTPFileSource::setClientOptions(ClientOptions options) {
  impl->clientOptions = options.clone();
}
ClientOptions HTTPFileSource::getClientOptions() {
  return impl->clientOptions.clone();
}

} // namespace mbgl

// ---- C ABI (maplibre_flutter_core_android.h) ----

extern "C" void mbl_android_http_set_handler(MblAndroidHttpStart start,
                                             MblAndroidHttpCancel cancel,
                                             void *user) {
  auto &reg = mbgl::registry();
  std::lock_guard<std::mutex> lk(reg.mutex);
  reg.handler = {start, cancel, user};
}

extern "C" void mbl_android_http_respond(uint64_t request_id, int32_t status,
                                         const uint8_t *data, size_t len,
                                         const char *etag, const char *expires) {
  using namespace mbgl;
  auto &reg = registry();

  // Build the Response off any thread (copy the body now).
  Response response;
  if (status == 200 || status == 0) {
    response.data = std::make_shared<std::string>(
        reinterpret_cast<const char *>(data), data != nullptr ? len : 0);
    if (etag != nullptr && etag[0] != '\0') response.etag = std::string(etag);
    // Give every successful response a short TTL so a session doesn't re-fetch the
    // same tile every frame (the host may also pass a real Expires; we keep it
    // simple for the POC). Caching beyond the session isn't wired.
    (void)expires;
    response.expires = util::now() + Seconds(300);
  } else if (status == 404) {
    response.error = std::make_unique<Response::Error>(
        Response::Error::Reason::NotFound, "Not Found");
  } else if (status >= 500) {
    response.error = std::make_unique<Response::Error>(
        Response::Error::Reason::Server, "Server error");
  } else {
    response.error = std::make_unique<Response::Error>(
        Response::Error::Reason::Connection, "HTTP request failed");
  }

  // Find the request's run loop and marshal delivery onto it. Re-check liveness
  // inside the invoke (it runs on the file-source thread, serialized with the
  // request's destructor) so we never touch a destroyed request.
  util::RunLoop *loop = nullptr;
  {
    std::lock_guard<std::mutex> lk(reg.mutex);
    auto it = reg.live.find(request_id);
    if (it == reg.live.end()) return; // cancelled
    loop = it->second.second;
  }
  if (loop == nullptr) return;
  loop->invoke([request_id, response] {
    auto &r = registry();
    HTTPAndroidRequest *req = nullptr;
    {
      std::lock_guard<std::mutex> lk(r.mutex);
      auto it = r.live.find(request_id);
      if (it == r.live.end()) return;
      req = it->second.first;
    }
    // Deliver WITHOUT holding r.mutex: the callback may synchronously delete the
    // request, whose destructor locks r.mutex — holding it here would deadlock the
    // file-source thread (the bug that left the style un-applied). Everything for
    // this request runs on this one thread, so `req` can't be freed before deliver.
    req->deliver(response);
  });
}
