// crash_handler.cpp
//
// Fatal-crash diagnostics (see crash_handler.h).

#include "crash_handler.h"

#include <csignal>
#include <cstdint>
#include <cstring>
#include <execinfo.h>
#include <unistd.h>

namespace {
void crashHandler(int sig, siginfo_t* info, void* /*uctx*/)
{
    int fd = 2;
    auto w = [&fd](const char* s) { ssize_t r = ::write(fd, s, std::strlen(s)); (void)r; };
    const char* name = "SIG?";
    switch (sig)
    {
        case SIGSEGV: name = "SIGSEGV (segmentation fault)"; break;
        case SIGBUS:  name = "SIGBUS (bus error)"; break;
        case SIGFPE:  name = "SIGFPE (floating-point exception)"; break;
        case SIGABRT: name = "SIGABRT (abort)"; break;
        default: break;
    }
    w("\n===== CAMERA_APP CRASH REPORT =====\n");
    w(name);
    w("\n");
    if (info && (sig == SIGSEGV || sig == SIGBUS))
    {
        w("faulting address: 0x");
        char h[18];
        uintptr_t a = (uintptr_t)info->si_addr;
        h[15] = 0; h[0] = '0'; h[1] = 'x';
        for (int i = 14; i >= 2; --i) { h[i] = "0123456789abcdef"[a & 0xF]; a >>= 4; }
        h[15] = '\n';
        ssize_t r = ::write(fd, h, 16); (void)r;
    }
    w("backtrace:\n");
    void* frames[40];
    int n = backtrace(frames, 40);
    backtrace_symbols_fd(frames, n, fd);   // async-signal-safe
    w("===== END CRASH REPORT =====\n");
    ::signal(sig, SIG_DFL);
    ::raise(sig);
}
} // namespace

void installCrashHandlers()
{
    struct sigaction sa = {};
    sa.sa_sigaction = &crashHandler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGBUS, &sa, nullptr);
    sigaction(SIGFPE, &sa, nullptr);
    sigaction(SIGABRT, &sa, nullptr);
}
