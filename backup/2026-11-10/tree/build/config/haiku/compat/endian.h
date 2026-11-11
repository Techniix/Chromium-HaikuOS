// Haiku compat <endian.h> (glibc/BSD style), built on compiler builtins.
#ifndef HAIKU_COMPAT_ENDIAN_H
#define HAIKU_COMPAT_ENDIAN_H
#include <stdint.h>
#ifndef __LITTLE_ENDIAN
#define __LITTLE_ENDIAN __ORDER_LITTLE_ENDIAN__
#define __BIG_ENDIAN __ORDER_BIG_ENDIAN__
#define __PDP_ENDIAN __ORDER_PDP_ENDIAN__
#define __BYTE_ORDER __BYTE_ORDER__
#endif
#ifndef LITTLE_ENDIAN
#define LITTLE_ENDIAN __LITTLE_ENDIAN
#define BIG_ENDIAN __BIG_ENDIAN
#define PDP_ENDIAN __PDP_ENDIAN
#endif
#ifndef BYTE_ORDER
#define BYTE_ORDER __BYTE_ORDER
#endif
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define HAIKU_COMPAT_LE(b, x) ((uint##b##_t)(x))
#define HAIKU_COMPAT_BE(b, x) ((uint##b##_t)__builtin_bswap##b(x))
#else
#define HAIKU_COMPAT_LE(b, x) ((uint##b##_t)__builtin_bswap##b(x))
#define HAIKU_COMPAT_BE(b, x) ((uint##b##_t)(x))
#endif
#ifndef htole16
#define htole16(x) HAIKU_COMPAT_LE(16, x)
#define htole32(x) HAIKU_COMPAT_LE(32, x)
#define htole64(x) HAIKU_COMPAT_LE(64, x)
#define le16toh(x) HAIKU_COMPAT_LE(16, x)
#define le32toh(x) HAIKU_COMPAT_LE(32, x)
#define le64toh(x) HAIKU_COMPAT_LE(64, x)
#endif
#ifndef htobe16
#define htobe16(x) HAIKU_COMPAT_BE(16, x)
#define htobe32(x) HAIKU_COMPAT_BE(32, x)
#define htobe64(x) HAIKU_COMPAT_BE(64, x)
#define be16toh(x) HAIKU_COMPAT_BE(16, x)
#define be32toh(x) HAIKU_COMPAT_BE(32, x)
#define be64toh(x) HAIKU_COMPAT_BE(64, x)
#endif
#endif
