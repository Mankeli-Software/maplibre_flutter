// Emscripten HTTP file source for mbgl, over the browser Fetch API
// (emscripten_fetch). Replaces platform/default's libcurl http_file_source.cpp.
// Requires linking with -sFETCH=1.
//
// mbgl drives this from OnlineFileSource's worker thread, whose RunLoop blocks
// between events — so that thread can't pump its JS event loop to receive ASYNC
// fetch callbacks. Each request therefore runs a **synchronous** fetch (sync fetch
// is allowed off the main thread), then delivers the Response back
// **asynchronously** via the originating RunLoop. This:
//   * satisfies mbgl's contract that the callback fires later, on the loop thread
//     (NOT re-entrantly inside request()), and
//   * lets mbgl's permitted concurrent requests actually run in parallel.
// Tile servers must send permissive CORS (demotiles / OpenFreeMap do).
//
// FETCH POOL (why this isn't thread-per-request): mbgl dispatches up to
// DEFAULT_MAXIMUM_CONCURRENT_REQUESTS (20) requests at once. A thread-per-request
// design spawns up to 20 Emscripten pthreads (Web Workers) simultaneously — and
// with mbgl's other threads (the 4-thread background pool, the file-source /
// sequenced / database threads, the main thread) that overruns the fixed
// PTHREAD_POOL_SIZE. The symptom is "Tried to spawn a new thread, but the thread
// pool is exhausted" + "Blocking on the main thread is very dangerous", and it
// bites hard when switching to a heavy style (e.g. OpenFreeMap Liberty) that fires
// many tile/glyph/sprite requests at once. So instead we run a **fixed pool of
// long-lived fetch worker threads** pulling from a queue: fetch concurrency is
// bounded to kFetchThreads regardless of mbgl's request burst (excess requests
// queue and run as workers free up), and no Worker is spawned per request.

#include <mbgl/storage/http_file_source.hpp>
#include <mbgl/storage/resource.hpp>
#include <mbgl/storage/resource_options.hpp>
#include <mbgl/storage/response.hpp>
#include <mbgl/util/async_request.hpp>
#include <mbgl/util/client_options.hpp>
#include <mbgl/util/run_loop.hpp>

#include <emscripten/fetch.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

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

// Concurrent fetch workers. Bounded so we never exhaust the Emscripten pthread pool
// (see the file header). 8 keeps tile loading parallel-enough while leaving plenty
// of headroom in PTHREAD_POOL_SIZE for mbgl's other threads.
constexpr std::size_t kFetchThreads = 8;

Response::Error::Reason reasonForStatus(uint16_t status) {
    if (status == 404) return Response::Error::Reason::NotFound;
    if (status == 429) return Response::Error::Reason::RateLimit;
    if (status >= 500 && status < 600) return Response::Error::Reason::Server;
    if (status == 0) return Response::Error::Reason::Connection;
    return Response::Error::Reason::Other;
}

// Shared between the request handle (held by mbgl) and the fetch worker. Destroying
// the handle flips `cancelled`, so a queued request is skipped and a delivered
// Response is dropped.
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

// A bounded pool of long-lived worker threads, each running synchronous fetches off
// a shared queue. Created once, on first use, and never torn down (process lifetime).
class FetchPool {
public:
    FetchPool() {
        workers.reserve(kFetchThreads);
        for (std::size_t i = 0; i < kFetchThreads; ++i) {
            workers.emplace_back([this] { workerLoop(); });
        }
    }

    void enqueue(std::shared_ptr<RequestState> state, std::string url) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            queue.push_back(Job{std::move(state), std::move(url)});
        }
        cv.notify_one();
    }

    static FetchPool& get() {
        static FetchPool pool;
        return pool;
    }

private:
    struct Job {
        std::shared_ptr<RequestState> state;
        std::string url;
    };

    void workerLoop() {
        for (;;) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(mutex);
                cv.wait(lock, [this] { return !queue.empty(); });
                job = std::move(queue.front());
                queue.pop_front();
            }
            // Skip work for an already-cancelled request (the handle was destroyed
            // while this job waited in the queue).
            if (job.state->cancelled.load(std::memory_order_acquire)) {
                continue;
            }

            emscripten_fetch_attr_t attr;
            emscripten_fetch_attr_init(&attr);
            std::strcpy(attr.requestMethod, "GET");
            attr.attributes = EMSCRIPTEN_FETCH_LOAD_TO_MEMORY | EMSCRIPTEN_FETCH_SYNCHRONOUS;

            emscripten_fetch_t* fetch = emscripten_fetch(&attr, job.url.c_str());
            Response response = buildResponse(fetch);
            if (fetch != nullptr) {
                emscripten_fetch_close(fetch);
            }

            if (job.state->cancelled.load(std::memory_order_acquire)) {
                continue; // cancelled while in flight — don't touch the (maybe-gone) loop
            }
            // Deliver on the originating RunLoop thread (async, not re-entrant).
            auto state = job.state;
            state->loop->invoke([state, response]() {
                if (!state->cancelled.load(std::memory_order_acquire) && state->callback) {
                    state->callback(response);
                }
            });
        }
    }

    std::vector<std::thread> workers;
    std::deque<Job> queue;
    std::mutex mutex;
    std::condition_variable cv;
};

} // namespace

HTTPFileSource::HTTPFileSource(const ResourceOptions& resourceOptions, const ClientOptions& clientOptions)
    : impl(std::make_unique<Impl>(resourceOptions, clientOptions)) {}

HTTPFileSource::~HTTPFileSource() = default;

std::unique_ptr<AsyncRequest> HTTPFileSource::request(const Resource& resource, Callback callback) {
    auto state = std::make_shared<RequestState>();
    state->callback = std::move(callback);
    state->loop = util::RunLoop::Get();

    FetchPool::get().enqueue(state, resource.url);

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
