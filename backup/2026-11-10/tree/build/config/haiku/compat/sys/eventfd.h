// Haiku has no eventfd(). Only DRM syncobj code uses it, and that protocol
// is never offered on Haiku; fail cleanly if it's ever called.
#ifndef HAIKU_COMPAT_SYS_EVENTFD_H
#define HAIKU_COMPAT_SYS_EVENTFD_H
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#define EFD_SEMAPHORE 1
#define EFD_CLOEXEC O_CLOEXEC
#define EFD_NONBLOCK O_NONBLOCK
typedef uint64_t eventfd_t;
static inline int eventfd(unsigned int initval, int flags) {
  (void)initval; (void)flags; errno = ENOSYS; return -1;
}
#endif
