// Haiku dev_t has no major/minor split; these only make DRM-related code
// compile (it is never used on Haiku).
#pragma once
#include <sys/types.h>
#ifndef major
#define major(d) ((unsigned int)(((d) >> 8) & 0xfff))
#define minor(d) ((unsigned int)((d) & 0xff))
#define makedev(ma, mi) ((dev_t)(((ma) << 8) | (mi)))
#endif
