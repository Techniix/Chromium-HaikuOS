#!/bin/sh
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Probe the Haiku C library for the BSD/GNU/Linux interfaces that the
# converted Chromium tree (and the Haiku patches) may use. Run this on the
# Haiku build machine before the first build; paste the output into an issue
# or into docs/STATUS.md.
#
# For each symbol it reports:
#   yes            available in libroot with the default feature macros
#   yes (-lbsd)    available when linking libbsd
#   yes (-lnetwork) available when linking libnetwork
#   no             missing: the code path needs a Haiku branch or a shim
#
# Usage: tools/probe-haiku-libc.sh [compiler]   (default: clang, then cc)

CC=${1:-}
if [ -z "$CC" ]; then
  for c in clang cc gcc; do
    if command -v "$c" >/dev/null 2>&1; then CC=$c; break; fi
  done
fi
[ -n "$CC" ] || { echo "No C compiler found." >&2; exit 1; }

TMP=${TMPDIR:-/tmp}/probe-haiku-libc.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

CFLAGS="-D_DEFAULT_SOURCE -D_GNU_SOURCE -w"

# name | headers (comma separated) | expression that must compile and link
probe() {
  name=$1; headers=$2; expr=$3
  {
    old_ifs=$IFS; IFS=,
    for h in $headers; do echo "#include <$h>"; done
    IFS=$old_ifs
    echo "int main(void) { $expr; return 0; }"
  } > "$TMP/t.c"
  for libs in "" "-lbsd" "-lnetwork" "-lbsd -lnetwork"; do
    if $CC $CFLAGS "$TMP/t.c" -o "$TMP/t" $libs >/dev/null 2>&1; then
      if [ -z "$libs" ]; then printf '%-24s yes\n' "$name"
      else printf '%-24s yes (%s)\n' "$name" "$libs"; fi
      return
    fi
  done
  printf '%-24s no\n' "$name"
}

echo "Compiler: $($CC --version 2>/dev/null | head -1)"
echo "System:   $(uname -a)"
for l in ld.lld ld; do
  if command -v "$l" >/dev/null 2>&1; then
    echo "Linker:   $($l --version 2>/dev/null | head -1)"; break
  fi
done
echo

# Converted guards that select BSD-libc code (docs/haikuify-report.md).
probe getentropy        unistd.h          'char b[8]; (void)getentropy(b, sizeof b)'
probe arc4random_buf    stdlib.h          'char b[8]; arc4random_buf(b, sizeof b)'
probe getdents          dirent.h,unistd.h 'char b[64]; (void)getdents(0, (void*)b, sizeof b)'
probe memfd_create      sys/mman.h        '(void)memfd_create("x", 0)'
probe MADV_FREE         sys/mman.h        'int x = MADV_FREE; (void)x'
probe MADV_DONTNEED     sys/mman.h        'int x = MADV_DONTNEED; (void)x'
probe posix_madvise     sys/mman.h        '(void)posix_madvise(0, 0, POSIX_MADV_DONTNEED)'
probe MAP_NORESERVE     sys/mman.h        'int x = MAP_NORESERVE; (void)x'
probe MAP_ANONYMOUS     sys/mman.h        'int x = MAP_ANONYMOUS; (void)x'
probe malloc_usable_size malloc.h         '(void)malloc_usable_size(0)'

# Threads and stacks (generic POSIX paths Haiku now takes).
probe pthread_getattr_np pthread.h        'pthread_attr_t a; (void)pthread_getattr_np(pthread_self(), &a)'
probe pthread_attr_getstack pthread.h     'pthread_attr_t a; void* s; size_t n; (void)pthread_attr_getstack(&a, &s, &n)'
probe sched_getaffinity sched.h           'cpu_set_t s; (void)sched_getaffinity(0, sizeof s, &s)'
probe _SC_PHYS_PAGES    unistd.h          '(void)sysconf(_SC_PHYS_PAGES)'
probe _SC_NPROCESSORS_ONLN unistd.h       '(void)sysconf(_SC_NPROCESSORS_ONLN)'

# Sockets and file descriptors.
probe pipe2             unistd.h,fcntl.h  'int p[2]; (void)pipe2(p, O_CLOEXEC)'
probe accept4           sys/socket.h      '(void)accept4(0, 0, 0, 0)'
probe SOCK_CLOEXEC      sys/socket.h      'int x = SOCK_CLOEXEC; (void)x'
probe MSG_NOSIGNAL      sys/socket.h      'int x = MSG_NOSIGNAL; (void)x'
probe SO_PEERCRED       sys/socket.h      'int x = SO_PEERCRED; (void)x'
probe getpeereid        unistd.h          'uid_t u; gid_t g; (void)getpeereid(0, &u, &g)'
probe ppoll             poll.h            '(void)ppoll(0, 0, 0, 0)'
probe POLLRDHUP         poll.h            'int x = POLLRDHUP; (void)x'
probe posix_fallocate   fcntl.h           '(void)posix_fallocate(0, 0, 0)'
probe O_DIRECTORY       fcntl.h           'int x = O_DIRECTORY; (void)x'
probe getdtablesize     unistd.h          '(void)getdtablesize()'
probe getpgid           unistd.h          '(void)getpgid(0)'

# Misc libc.
probe strlcpy           string.h          'char d[4]; (void)strlcpy(d, "x", sizeof d)'
probe explicit_bzero    string.h          'char d[4]; explicit_bzero(d, sizeof d)'
probe reallocarray      stdlib.h          '(void)reallocarray(0, 1, 1)'
probe backtrace         execinfo.h        'void* f[4]; (void)backtrace(f, 4)'
probe dl_iterate_phdr   link.h            '(void)dl_iterate_phdr(0, 0)'
probe utimensat         sys/stat.h,fcntl.h '(void)utimensat(0, "x", 0, 0)'
probe mkostemp          stdlib.h,fcntl.h  'char t[] = "/tmp/xXXXXXX"; (void)mkostemp(t, O_CLOEXEC)'

# Not expected on Haiku (the patches avoid them); listed to confirm.
probe epoll_create1     sys/epoll.h       '(void)epoll_create1(0)'
probe eventfd           sys/eventfd.h     '(void)eventfd(0, 0)'
probe inotify_init1     sys/inotify.h     '(void)inotify_init1(0)'
