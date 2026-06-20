// Emscripten HTTP file source for mbgl, over the browser Fetch API
// (emscripten_fetch). Replaces platform/default's libcurl http_file_source.cpp.
// Requires linking with -sFETCH=1.
//
// mbgl drives this from OnlineFileSource's dedicated worker thread (a pthread /
// Web Worker), whose RunLoop blocks between events — so a worker blocked on a
// futex cannot pump its JS event loop to receive ASYNC fetch callbacks. We
// therefore use a **synchronous** fetch (allowed only off the main thread): it
// blocks the worker until the body is in memory, then delivers the Response
// inline. Tile servers must send permissive CORS (demotiles / OpenFreeMap do).

#include <mbgl/storage/http_file_source.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/storage/response.hpp>
#include <mbgl/util/async_request.hpp>
#include <mbgl/util/client_options.hpp>
#include <mbgl/util/logging.hpp>

#include <emscripten/fetch.h>

#include <cstring>
#include <memory>
#include <string>

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

// Synchronous requests complete before request() returns, so there is nothing to
// cancel; the AsyncRequest is just an already-finished token.
class HTTPRequest : public AsyncRequest {
public:
    ~HTTPRequest() override = default;
};

Response::Error::Reason reasonForStatus(uint16_t status) {
    if (status == 404) return Response::Error::Reason::NotFound;
    if (status == 429) return Response::Error::Reason::RateLimit;
    if (status >= 500 && status < 600) return Response::Error::Reason::Server;
    if (status == 0) return Response::Error::Reason::Connection;
    return Response::Error::Reason::Other;
}

} // namespace

HTTPFileSource::HTTPFileSource(const ResourceOptions& resourceOptions, const ClientOptions& clientOptions)
    : impl(std::make_unique<Impl>(resourceOptions, clientOptions)) {}

HTTPFileSource::~HTTPFileSource() = default;

std::unique_ptr<AsyncRequest> HTTPFileSource::request(const Resource& resource, Callback callback) {
    emscripten_fetch_attr_t attr;
    emscripten_fetch_attr_init(&attr);
    std::strcpy(attr.requestMethod, "GET");
    attr.attributes = EMSCRIPTEN_FETCH_LOAD_TO_MEMORY | EMSCRIPTEN_FETCH_SYNCHRONOUS;

    emscripten_fetch_t* fetch = emscripten_fetch(&attr, resource.url.c_str());

    Response response;
    if (fetch == nullptr) {
        response.error = std::make_unique<Response::Error>(Response::Error::Reason::Connection,
                                                           "emscripten_fetch returned null");
    } else {
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
        emscripten_fetch_close(fetch);
    }

    callback(response);
    return std::make_unique<HTTPRequest>();
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
