/*
 * Copyright 2026 The Chromium Authors
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * crashtrace: print a stack trace when a program crashes, without a
 * debugger. Built as a shared library and loaded into the program with
 * LD_PRELOAD by scripts/crashtrace.sh. Its constructor installs handlers for
 * SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP and SIGABRT on an alternate signal
 * stack; the handler writes, to stderr and to $CRASHTRACE_LOG if set:
 *
 *   - the signal, the faulting address and the thread,
 *   - the instruction and stack pointers from the signal context,
 *   - the frames backtrace() finds, through backtrace_symbols_fd(), which on
 *     Renga does not allocate and so is safe here,
 *
 * then restores the default action and re-raises the signal, so the program
 * still dies the way it would have. Frames print as image(symbol+0xoff) or
 * image(+0xoff); tools/symbolize-trace.py resolves them.
 *
 * crashtrace also interposes sigaction() and signal(): when the program
 * tries to install its own handler for one of these signals, crashtrace
 * reports it on stderr and keeps its own handler, unless CRASHTRACE_ALLOW=1
 * is set (then the program's handler is installed and crashtrace no longer
 * sees that signal). It prints one line when it is loaded, so a missing
 * trace can be told apart from a library that was never loaded.
 *
 * The alternate stack is set up for the main thread only; other threads run
 * the handler on their own stacks.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dlfcn.h>
#include <execinfo.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>
#if defined(__HAIKU__)
#include <OS.h>
#define CURRENT_THREAD() ((long)find_thread(NULL))
#else
#define CURRENT_THREAD() ((long)gettid())
#endif

static int g_log_fd = -1;
static int g_allow_program_handlers = 0;
static int (*g_real_sigaction)(int, const struct sigaction*,
                               struct sigaction*) = NULL;

static int real_sigaction(int sig, const struct sigaction* act,
                          struct sigaction* old);

static int is_fatal(int sig) {
  return sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGFPE ||
         sig == SIGTRAP || sig == SIGABRT;
}

static void put(int fd, const char* s) {
  if (fd < 0) return;
  size_t n = strlen(s);
  while (n > 0) {
    ssize_t w = write(fd, s, n);
    if (w <= 0) return;
    s += w;
    n -= (size_t)w;
  }
}

static void put_both(const char* s) {
  put(STDERR_FILENO, s);
  put(g_log_fd, s);
}

static void hex(char* out, uintptr_t v) {  /* "0x" + 16 digits + NUL */
  static const char digits[] = "0123456789abcdef";
  out[0] = '0';
  out[1] = 'x';
  for (int i = 0; i < 16; i++)
    out[2 + i] = digits[(v >> ((15 - i) * 4)) & 0xf];
  out[18] = '\0';
}

static void dec(char* out, long v) {
  char tmp[24];
  int i = 0, neg = v < 0;
  unsigned long u = neg ? (unsigned long)-v : (unsigned long)v;
  do { tmp[i++] = (char)('0' + u % 10); u /= 10; } while (u && i < 23);
  int o = 0;
  if (neg) out[o++] = '-';
  while (i) out[o++] = tmp[--i];
  out[o] = '\0';
}

static const char* signame(int sig) {
  switch (sig) {
    case SIGSEGV: return "SIGSEGV";
    case SIGBUS: return "SIGBUS";
    case SIGILL: return "SIGILL";
    case SIGFPE: return "SIGFPE";
    case SIGTRAP: return "SIGTRAP";
    case SIGABRT: return "SIGABRT";
    default: return "signal";
  }
}

static void handler(int sig, siginfo_t* info, void* ctx) {
  char buf[32];
  put_both("\n==== crashtrace: ");
  put_both(signame(sig));
  put_both(" (");
  dec(buf, sig);
  put_both(buf);
  put_both(") in thread ");
  dec(buf, CURRENT_THREAD());
  put_both(buf);
  put_both(", fault address ");
  hex(buf, (uintptr_t)(info ? info->si_addr : 0));
  put_both(buf);
  put_both(", si_code ");
  dec(buf, info ? info->si_code : 0);
  put_both(buf);
  put_both("\n");

  ucontext_t* uc = (ucontext_t*)ctx;
  if (uc) {
#if defined(__HAIKU__) && defined(__x86_64__)
    uintptr_t ip = (uintptr_t)uc->uc_mcontext.rip;
    uintptr_t sp = (uintptr_t)uc->uc_mcontext.rsp;
    uintptr_t bp = (uintptr_t)uc->uc_mcontext.rbp;
#elif defined(__linux__) && defined(__x86_64__)
    uintptr_t ip = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
    uintptr_t sp = (uintptr_t)uc->uc_mcontext.gregs[REG_RSP];
    uintptr_t bp = (uintptr_t)uc->uc_mcontext.gregs[REG_RBP];
#else
    uintptr_t ip = 0, sp = 0, bp = 0;
#endif
    put_both("     ip ");
    hex(buf, ip);
    put_both(buf);
    put_both("  sp ");
    hex(buf, sp);
    put_both(buf);
    put_both("  bp ");
    hex(buf, bp);
    put_both(buf);
    put_both("\n---- crashing instruction:\n");
    void* ipv = (void*)ip;
    backtrace_symbols_fd(&ipv, 1, STDERR_FILENO);
    if (g_log_fd >= 0) backtrace_symbols_fd(&ipv, 1, g_log_fd);
  }

  void* frames[128];
  int n = backtrace(frames, 128);
  put_both("---- backtrace (the first frames are crashtrace's handler and the "
           "signal trampoline):\n");
  backtrace_symbols_fd(frames, n, STDERR_FILENO);
  if (g_log_fd >= 0) backtrace_symbols_fd(frames, n, g_log_fd);
  put_both("==== end of crashtrace\n");

  struct sigaction dfl;
  memset(&dfl, 0, sizeof(dfl));
  dfl.sa_handler = SIG_DFL;
  sigemptyset(&dfl.sa_mask);
  real_sigaction(sig, &dfl, NULL);
  raise(sig);
}

static int real_sigaction(int sig, const struct sigaction* act,
                          struct sigaction* old) {
  if (!g_real_sigaction)
    g_real_sigaction = (int (*)(int, const struct sigaction*,
                                struct sigaction*))dlsym(RTLD_NEXT, "sigaction");
  if (!g_real_sigaction) {
    errno = ENOSYS;
    return -1;
  }
  return g_real_sigaction(sig, act, old);
}

static void report_handler_attempt(int sig) {
  char buf[32];
  put_both("crashtrace: the program installs its own handler for ");
  put_both(signame(sig));
  if (g_allow_program_handlers) {
    put_both("; allowed (CRASHTRACE_ALLOW=1)\n");
  } else {
    put_both("; keeping crashtrace's (set CRASHTRACE_ALLOW=1 to let it)\n");
  }
  (void)buf;
}

/* Interposed: the program's calls come here first (LD_PRELOAD). */
int sigaction(int sig, const struct sigaction* act, struct sigaction* old) {
  if (act && is_fatal(sig) && act->sa_handler != SIG_DFL) {
    report_handler_attempt(sig);
    if (!g_allow_program_handlers) {
      if (old) real_sigaction(sig, NULL, old);
      return 0;
    }
  }
  return real_sigaction(sig, act, old);
}

__sighandler_t signal(int sig, __sighandler_t handler_fn) {
  struct sigaction sa, old;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = handler_fn;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  if (sigaction(sig, &sa, &old) != 0) return SIG_ERR;
  return old.sa_handler;
}

__attribute__((constructor)) static void crashtrace_init(void) {
  const char* log = getenv("CRASHTRACE_LOG");
  if (log && *log)
    g_log_fd = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
  const char* allow = getenv("CRASHTRACE_ALLOW");
  g_allow_program_handlers = allow && *allow && *allow != '0';
  {
    char buf[32];
    put_both("crashtrace: loaded into process ");
    dec(buf, (long)getpid());
    put_both(buf);
    put_both(real_sigaction(SIGSEGV, NULL, NULL) == 0
                 ? "\n"
                 : " (dlsym(RTLD_NEXT, \"sigaction\") failed: cannot install "
                   "handlers)\n");
  }

  /* Alternate stack: the crash may be a stack overflow. Leaked on purpose. */
  stack_t ss;
  ss.ss_size = 256 * 1024;
  ss.ss_sp = malloc(ss.ss_size);
  ss.ss_flags = 0;
  if (ss.ss_sp) sigaltstack(&ss, NULL);

  /* Load the unwinder now; the first backtrace() call may allocate. */
  void* warm[2];
  backtrace(warm, 2);

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = handler;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
  sigemptyset(&sa.sa_mask);
  const int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT};
  for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++)
    real_sigaction(sigs[i], &sa, NULL);
}
