// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef UI_GFX_LINUX_DMABUF_UAPI_H_
#define UI_GFX_LINUX_DMABUF_UAPI_H_

#include <sys/types.h>

#if defined(__HAIKU__)  // HAIKU_DMABUF_IOC_V2
// Linux _IOC encoding, only used to build ioctl numbers (never issued).
#undef _IOC
#undef _IO
#undef _IOR
#undef _IOW
#undef _IOWR
#define _IOC(dir, type, nr, size) \
  ((unsigned long)(((dir) << 30) | ((size) << 16) | ((type) << 8) | (nr)))
#define _IO(type, nr) _IOC(0U, (type), (nr), 0)
#define _IOW(type, nr, t) _IOC(1U, (type), (nr), sizeof(t))
#define _IOR(type, nr, t) _IOC(2U, (type), (nr), sizeof(t))
#define _IOWR(type, nr, t) _IOC(3U, (type), (nr), sizeof(t))
#endif

typedef int32_t  __s32;
typedef uint32_t __u32;
typedef uint64_t __u64;

struct dma_buf_sync {
  __u64 flags;
};

constexpr __u64 DMA_BUF_SYNC_READ = 1 << 0;
constexpr __u64 DMA_BUF_SYNC_WRITE = 2 << 0;
constexpr __u64 DMA_BUF_SYNC_RW = DMA_BUF_SYNC_READ | DMA_BUF_SYNC_WRITE;

constexpr __u64 DMA_BUF_SYNC_START = 0 << 2;
constexpr __u64 DMA_BUF_SYNC_END = 1 << 2;

constexpr char DMA_BUF_BASE = 'b';
constexpr unsigned long DMA_BUF_IOCTL_SYNC =
    _IOW(DMA_BUF_BASE, 0, struct dma_buf_sync);

struct dma_buf_export_sync_file {
  __u32 flags;
  __s32 fd;
};

struct dma_buf_import_sync_file {
  __u32 flags;
  __s32 fd;
};

constexpr unsigned long DMA_BUF_IOCTL_EXPORT_SYNC_FILE =
    _IOWR(DMA_BUF_BASE, 2, struct dma_buf_export_sync_file);
constexpr unsigned long DMA_BUF_IOCTL_IMPORT_SYNC_FILE =
    _IOW(DMA_BUF_BASE, 3, struct dma_buf_import_sync_file);

#endif  // UI_GFX_LINUX_DMABUF_UAPI_H_
