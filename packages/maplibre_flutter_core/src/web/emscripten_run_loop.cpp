// Emscripten run-loop layer for mbgl: libuv-free RunLoop + AsyncTask + Timer.
//
// Replaces platform/default's libuv implementations (run_loop.cpp / async_task.cpp
// / timer.cpp), which cannot run in the browser. The three classes share one loop
// registry, so they live in a single translation unit.
//
// Two kinds of thread run a RunLoop, and run() behaves differently on each:
//
//   * The MAIN (browser) thread, where the map lives. It must NOT block — the web
//     shim ticks RunLoop::runOnce() once per animation frame (emscripten_set_main_
//     loop). run() there just marks the loop running and returns.
//
//   * mbgl WORKER threads (util::Thread<> objects such as OnlineFileSource) are real
//     pthreads (Web Workers) and CAN block. mbgl constructs them and calls run(),
//     expecting it to process the thread's event queue until stop(). So on a worker
//     run() loops: tick(), then wait on a condition variable until woken (by a
//     posted task / AsyncTask::send / a due Timer). Without this, the file source's
//     thread would exit immediately and never service fetch requests.
//
// runOnce()/tick() fire due Timers and poll AsyncTask pending flags (one of which is
// the RunLoop's own process() task that drains the WorkTask queue). AsyncTask::send()
// and Timer::start() notify the loop's condition variable so a blocked worker wakes.
// Background tile work uses the core's std::thread scheduler (Emscripten pthreads).

#include <mbgl/util/async_task.hpp>
#include <mbgl/util/run_loop.hpp>
#include <mbgl/util/timer.hpp>

#include <emscripten/threading.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <optional>
#include <vector>

namespace mbgl {
namespace util {

namespace {
using steady = std::chrono::steady_clock;
steady::time_point nowTime() {
    return steady::now();
}
} // namespace

struct AsyncReg {
    std::function<void()> task;
    std::atomic<bool> pending{false};
};

struct TimerReg {
    std::function<void()> cb;
    steady::time_point due;
    std::chrono::milliseconds repeat{0};
    bool active = false;
};

class RunLoop::Impl {
public:
    void registerAsync(AsyncReg* a) {
        std::scoped_lock lock(mutex);
        asyncs.push_back(a);
    }
    void unregisterAsync(AsyncReg* a) {
        std::scoped_lock lock(mutex);
        asyncs.erase(std::remove(asyncs.begin(), asyncs.end(), a), asyncs.end());
    }
    void registerTimer(TimerReg* t) {
        std::scoped_lock lock(mutex);
        timers.push_back(t);
    }
    void unregisterTimer(TimerReg* t) {
        std::scoped_lock lock(mutex);
        timers.erase(std::remove(timers.begin(), timers.end(), t), timers.end());
    }

    // Wake a worker blocked in waitForWork(). Safe to call from any thread.
    void notify() {
        {
            std::scoped_lock lock(mutex);
            woken = true;
        }
        cv.notify_all();
    }

    // Fire due timers + pending asyncs. Callbacks may register/unregister/destroy
    // timers, so we copy the std::functions to run UNDER the lock, then invoke them
    // after releasing it.
    void tick() {
        const auto now = nowTime();
        std::vector<std::function<void()>> toFire;
        {
            std::scoped_lock lock(mutex);
            for (auto* t : timers) {
                if (t->active && now >= t->due) {
                    if (t->repeat.count() > 0) {
                        t->due = now + t->repeat;
                    } else {
                        t->active = false;
                    }
                    if (t->cb) toFire.push_back(t->cb);
                }
            }
            for (auto* a : asyncs) {
                if (a->pending.exchange(false, std::memory_order_acq_rel)) {
                    if (a->task) toFire.push_back(a->task);
                }
            }
        }
        for (auto& fn : toFire) {
            fn();
        }
    }

    // Block until woken or the earliest active timer is due (worker threads only).
    void waitForWork() {
        std::unique_lock<std::mutex> lock(mutex);
        if (woken) {
            woken = false;
            return;
        }
        std::optional<steady::time_point> earliest;
        for (auto* t : timers) {
            if (t->active && (!earliest || t->due < *earliest)) {
                earliest = t->due;
            }
        }
        if (earliest) {
            cv.wait_until(lock, *earliest, [this] { return woken; });
        } else {
            cv.wait(lock, [this] { return woken; });
        }
        woken = false;
    }

    std::mutex mutex;
    std::condition_variable cv;
    bool woken = false;
    std::vector<AsyncReg*> asyncs;
    std::vector<TimerReg*> timers;
    bool running = false;
    // The async whose task drains the RunLoop WorkTask queue. Declared last so it is
    // destroyed first (its dtor unregisters via the still-live mutex/vectors above).
    std::unique_ptr<AsyncTask> async;
};

// ---------------------------------------------------------------------------
// RunLoop
// ---------------------------------------------------------------------------

RunLoop* RunLoop::Get() {
    assert(static_cast<RunLoop*>(Scheduler::GetCurrent()));
    return static_cast<RunLoop*>(Scheduler::GetCurrent());
}

LOOP_HANDLE RunLoop::getLoopHandle() {
    return static_cast<LOOP_HANDLE>(Get()->impl.get());
}

RunLoop::RunLoop(Type)
    : impl(std::make_unique<Impl>()) {
    Scheduler::SetCurrent(this);
    impl->running = true;
    impl->async = std::make_unique<AsyncTask>(std::bind(&RunLoop::process, this));
}

RunLoop::~RunLoop() {
    Scheduler::SetCurrent(nullptr);
}

void RunLoop::wake() {
    if (impl->async) impl->async->send();
}

void RunLoop::run() {
    MBGL_VERIFY_THREAD(tid);
    impl->running = true;
    // The browser main thread must not block; the shim drives runOnce() per frame.
    if (emscripten_is_main_runtime_thread()) {
        return;
    }
    // Worker thread (e.g. OnlineFileSource): block-and-process until stop().
    while (impl->running) {
        impl->tick();
        if (!impl->running) {
            break;
        }
        impl->waitForWork();
    }
}

void RunLoop::runOnce() {
    MBGL_VERIFY_THREAD(tid);
    impl->tick();
}

void RunLoop::stop() {
    invoke([this] { impl->running = false; });
    impl->notify();
}

void RunLoop::updateTime() {
    // No cached clock to update; runOnce() reads the clock directly.
}

void RunLoop::waitForEmpty(const mbgl::util::SimpleIdentity) {
    while (true) {
        std::size_t remaining;
        {
            std::scoped_lock lock(mutex);
            remaining = defaultQueue.size() + highPriorityQueue.size();
        }
        if (remaining == 0) {
            return;
        }
        runOnce();
    }
}

// libcurl-only fd watching; unused with the fetch-based HTTP source.
void RunLoop::addWatch(int, Event, std::function<void(int, Event)>&&) {}
void RunLoop::removeWatch(int) {}

// ---------------------------------------------------------------------------
// AsyncTask
// ---------------------------------------------------------------------------

class AsyncTask::Impl {
public:
    explicit Impl(std::function<void()>&& fn) {
        reg.task = std::move(fn);
        loop = static_cast<RunLoop::Impl*>(RunLoop::getLoopHandle());
        loop->registerAsync(&reg);
    }
    ~Impl() { loop->unregisterAsync(&reg); }

    void send() {
        reg.pending.store(true, std::memory_order_release);
        loop->notify();
    }

private:
    RunLoop::Impl* loop = nullptr;
    AsyncReg reg;
};

AsyncTask::AsyncTask(std::function<void()>&& fn)
    : impl(std::make_unique<Impl>(std::move(fn))) {}

AsyncTask::~AsyncTask() = default;

void AsyncTask::send() {
    impl->send();
}

// ---------------------------------------------------------------------------
// Timer
// ---------------------------------------------------------------------------

class Timer::Impl {
public:
    Impl() {
        loop = static_cast<RunLoop::Impl*>(RunLoop::getLoopHandle());
        loop->registerTimer(&reg);
    }
    ~Impl() { loop->unregisterTimer(&reg); }

    void start(uint64_t timeout, uint64_t repeat, std::function<void()>&& cb) {
        reg.cb = std::move(cb);
        reg.due = nowTime() + std::chrono::milliseconds(timeout);
        reg.repeat = std::chrono::milliseconds(repeat);
        reg.active = true;
        loop->notify();
    }

    void stop() {
        reg.active = false;
        reg.cb = nullptr;
    }

private:
    RunLoop::Impl* loop = nullptr;
    TimerReg reg;
};

Timer::Timer()
    : impl(std::make_unique<Impl>()) {}

Timer::~Timer() = default;

void Timer::start(Duration timeout, Duration repeat, std::function<void()>&& cb) {
    impl->start(static_cast<uint64_t>(std::chrono::duration_cast<Milliseconds>(timeout).count()),
                static_cast<uint64_t>(std::chrono::duration_cast<Milliseconds>(repeat).count()),
                std::move(cb));
}

void Timer::stop() {
    impl->stop();
}

} // namespace util
} // namespace mbgl
