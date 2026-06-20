// Emscripten HTTP file source for mbgl, over the browser Fetch API
// (emscripten_fetch). Replaces platform/default's libcurl http_file_source.cpp.
// Requires linking with -sFETCH=1.
//
// mbgl drives this from OnlineFileSource's worker thread, whose RunLoop blocks
// between events — so that thread can't pump its JS event loop to receive ASYNC
// fetch callbacks. Each request therefore runs a **synchronous** fetch on its own
// short-lived worker thread (sync fetch is allowed off the main thread), then
// delivers the Response back **asynchronously** via the originating RunLoop. This:
//   * satisfies mbgl's contract that the callback fires later, on the loop thread
//     (NOT re-entrantly inside request()), and
//   * lets mbgl's permitted concurrent requests actually run in parallel.
// Tile servers must send permissive CORS (demotiles / OpenFreeMap do).

#include <mbgl/storage/http_file_source.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/storage/response.hpp>
#include <mbgl/util/async_request.hpp>
#include <mbgl/util/client_options.hpp>
#include <mbgl/util/run_loop.hpp>

#include <emscripten/fetch.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <string>
#include <thread>

namespace mbgl {

class HTTPFileSource::Impl {
public:
    Impl(const ResourceOptions& resourceOptions_, const ClientOptions& clientOptions_)
        : resourceOptions(resourceOptions_.clone()),
          clientOptions(clientOptions_.clone()) {}

    ResourceOptions resourceOptions;
    ClientOptions clientOptions;
};

namespace {

Response::Error::Reason reasonForStatus(uint16_t status) {
    if (status == 404) return Response::Error::Reason::NotFound;
    if (status == 429) return Response::Error::Reason::RateLimit;
    if (status >= 500 && status < 600) return Response::Error::Reason::Server;
    if (status == 0) return Response::Error::Reason::Connection;
    return Response::Error::Reason::Other;
}

// Shared between the request handle (held by mbgl) and the fetch thread. Destroying
// the handle flips `cancelled`, so the delivered Response is dropped.
struct RequestState {
    std::atomic<bool> cancelled{false};
    FileSource::Callback callback;
    util::RunLoop* loop = nullptr;
};

class HTTPRequest : public AsyncRequest {
public:
    explicit HTTPRequest(std::shared_ptr<RequestState> s) : state(std::move(s)) {}
    ~HTTPRequest() override { state->cancelled.store(true, std::memory_order_release); }
    std::shared_ptr<RequestState> state;
};

Response buildResponse(emscripten_fetch_t* fetch) {
    Response response;
    if (fetch == nullptr) {
        response.error = std::make_unique<Response::Error>(Response::Error::Reason::Connection,
                                                           "emscripten_fetch returned null");
        return response;
    }
    const uint16_t status = fetch->status;
    if (status == 200 || status == 206) {
        response.data = std::make_shared<std::string>(fetch->data, static_cast<size_t>(fetch->numBytes));
    } else if (status == 204 || status == 404) {
        response.noContent = true;
    } else if (status == 304) {
        response.notModified = true;
    } else {
        response.error = std::make_unique<Response::Error>(
            reasonForStatus(status), std::string("HTTP status ") + std::to_string(status));
    }
    return response;
}

} // namespace

HTTPFileSource::HTTPFileSource(const ResourceOptions& resourceOptions, const ClientOptions& clientOptions)
    : impl(std::make_unique<Impl>(resourceOptions, clientOptions)) {}

HTTPFileSource::~HTTPFileSource() = default;

std::unique_ptr<AsyncRequest> HTTPFileSource::request(const Resource& resource, Callback callback) {
    auto state = std::make_shared<RequestState>();
    state->callback = std::move(callback);
    state->loop = util::RunLoop::Get();

    const std::string url = resource.url;
    std::thread([state, url]() {
        emscripten_fetch_attr_t attr;
        emscripten_fetch_attr_init(&attr);
        std::strcpy(attr.requestMethod, "GET");
        attr.attributes = EMSCRIPTEN_FETCH_LOAD_TO_MEMORY | EMSCRIPTEN_FETCH_SYNCHRONOUS;

        emscripten_fetch_t* fetch = emscripten_fetch(&attr, url.c_str());
        Response response = buildResponse(fetch);
        if (fetch != nullptr) {
            emscripten_fetch_close(fetch);
        }

        if (state->cancelled.load(std::memory_order_acquire)) {
            return; // request cancelled while in flight — don't touch the (maybe-gone) loop
        }
        // Deliver on the originating RunLoop thread (async, not re-entrant).
        state->loop->invoke([state, response]() {
            if (!state->cancelled.load(std::memory_order_acquire) && state->callback) {
                state->callback(response);
            }
        });
    }).detach();

    return std::make_unique<HTTPRequest>(state);
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
