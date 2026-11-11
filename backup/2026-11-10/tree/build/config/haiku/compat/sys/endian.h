// Haiku compat <sys/endian.h> (FreeBSD style).
#pragma once
#include <endian.h>
#ifndef bswap16
#define bswap16(x) __builtin_bswap16(x)
#define bswap32(x) __builtin_bswap32(x)
#define bswap64(x) __builtin_bswap64(x)
#endif
