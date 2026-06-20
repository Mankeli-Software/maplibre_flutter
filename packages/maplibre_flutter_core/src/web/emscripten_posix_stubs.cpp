// POSIX stubs missing from the Emscripten sysroot.
//
// Emscripten declares but does not implement sched_setscheduler. mbgl's
// platform/default/util/thread.cpp calls it (guarded by SCHED_IDLE / SCHED_OTHER,
// which Emscripten does define) only to drop a background thread's scheduling
// priority — advisory, so a no-op is correct in the browser.
#include <sched.h>

extern "C" int sched_setscheduler(pid_t, int, const struct sched_param*) {
    return 0;
}
