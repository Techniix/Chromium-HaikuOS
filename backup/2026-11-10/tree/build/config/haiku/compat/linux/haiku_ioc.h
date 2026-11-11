// Linux-style _IO/_IOR/_IOW/_IOWR encoding for code that only builds ioctl
// numbers (they're never issued on Haiku).
#ifndef HAIKU_COMPAT_IOC_H
#define HAIKU_COMPAT_IOC_H
#ifndef _IOC
#define _IOC(dir, type, nr, size) \
  ((unsigned long)(((dir) << 30) | ((size) << 16) | ((type) << 8) | (nr)))
#endif
#ifndef _IO
#define _IO(type, nr) _IOC(0U, (type), (nr), 0)
#endif
#ifndef _IOW
#define _IOW(type, nr, t) _IOC(1U, (type), (nr), sizeof(t))
#endif
#ifndef _IOR
#define _IOR(type, nr, t) _IOC(2U, (type), (nr), sizeof(t))
#endif
#ifndef _IOWR
#define _IOWR(type, nr, t) _IOC(3U, (type), (nr), sizeof(t))
#endif
#endif
