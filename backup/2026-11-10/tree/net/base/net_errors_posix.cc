// Copyright 2011 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "net/base/net_errors.h"

#include <errno.h>
#include <stdlib.h>
#include <string>
#include <unistd.h>

#include "base/logging.h"
#include "base/posix/safe_strerror.h"
#include "build/build_config.h"

namespace net {

Error MapSystemError(logging::SystemErrorCode os_error) {
  if (os_error != 0)
    DVLOG(2) << "Error " << os_error << ": "
             << logging::SystemErrorCodeToString(os_error);

  // There are numerous posix error codes, but these are the ones we thus far
  // find interesting.
  switch (os_error) {
#ifdef EAGAIN
    case EAGAIN:
#endif
#if EWOULDBLOCK != EAGAIN
#ifdef EWOULDBLOCK
    case EWOULDBLOCK:
#endif
#endif
      return ERR_IO_PENDING;
#ifdef EACCES
    case EACCES:
#endif
      return ERR_ACCESS_DENIED;
#ifdef ENETDOWN
    case ENETDOWN:
#endif
      return ERR_INTERNET_DISCONNECTED;
#ifdef ETIMEDOUT
    case ETIMEDOUT:
#endif
      return ERR_TIMED_OUT;
#ifdef ECONNRESET
    case ECONNRESET:
#endif
#ifdef ENETRESET
    case ENETRESET:  // Related to keep-alive.
#endif
#ifdef EPIPE
    case EPIPE:
#endif
      return ERR_CONNECTION_RESET;
#ifdef ECONNABORTED
    case ECONNABORTED:
#endif
      return ERR_CONNECTION_ABORTED;
#ifdef ECONNREFUSED
    case ECONNREFUSED:
#endif
      return ERR_CONNECTION_REFUSED;
#ifdef EHOSTUNREACH
    case EHOSTUNREACH:
#endif
#ifdef EHOSTDOWN
    case EHOSTDOWN:
#endif
#ifdef ENETUNREACH
    case ENETUNREACH:
#endif
#ifdef EAFNOSUPPORT
    case EAFNOSUPPORT:
#endif
      return ERR_ADDRESS_UNREACHABLE;
#ifdef EADDRNOTAVAIL
    case EADDRNOTAVAIL:
#endif
      return ERR_ADDRESS_INVALID;
#ifdef EMSGSIZE
    case EMSGSIZE:
#endif
      return ERR_MSG_TOO_BIG;
#ifdef ENOTCONN
    case ENOTCONN:
#endif
      return ERR_SOCKET_NOT_CONNECTED;
#ifdef EISCONN
    case EISCONN:
#endif
      return ERR_SOCKET_IS_CONNECTED;
#ifdef EINVAL
    case EINVAL:
#endif
      return ERR_INVALID_ARGUMENT;
#ifdef EADDRINUSE
    case EADDRINUSE:
#endif
      return ERR_ADDRESS_IN_USE;
#ifdef E2BIG
    case E2BIG:  // Argument list too long.
#endif
      return ERR_INVALID_ARGUMENT;
#ifdef EBADF
    case EBADF:  // Bad file descriptor.
#endif
      return ERR_INVALID_HANDLE;
#ifdef EBUSY
    case EBUSY:  // Device or resource busy.
#endif
      return ERR_INSUFFICIENT_RESOURCES;
#ifdef ECANCELED
    case ECANCELED:  // Operation canceled.
#endif
      return ERR_ABORTED;
#ifdef EDEADLK
    case EDEADLK:  // Resource deadlock avoided.
#endif
      return ERR_INSUFFICIENT_RESOURCES;
#ifdef EDQUOT
    case EDQUOT:  // Disk quota exceeded.
#endif
      return ERR_FILE_NO_SPACE;
#ifdef EEXIST
    case EEXIST:  // File exists.
#endif
      return ERR_FILE_EXISTS;
#ifdef EFAULT
    case EFAULT:  // Bad address.
#endif
      return ERR_INVALID_ARGUMENT;
#ifdef EFBIG
    case EFBIG:  // File too large.
#endif
      return ERR_FILE_TOO_BIG;
#ifdef EISDIR
    case EISDIR:  // Operation not allowed for a directory.
#endif
      return ERR_ACCESS_DENIED;
#ifdef ENAMETOOLONG
    case ENAMETOOLONG:  // Filename too long.
#endif
      return ERR_FILE_PATH_TOO_LONG;
#ifdef ENFILE
    case ENFILE:  // Too many open files in system.
#endif
      return ERR_INSUFFICIENT_RESOURCES;
#ifdef ENOBUFS
    case ENOBUFS:  // No buffer space available.
#endif
      return ERR_NO_BUFFER_SPACE;
#ifdef ENODEV
    case ENODEV:  // No such device.
#endif
      return ERR_INVALID_ARGUMENT;
#ifdef ENOENT
    case ENOENT:  // No such file or directory.
#endif
      return ERR_FILE_NOT_FOUND;
#ifdef ENOLCK
    case ENOLCK:  // No locks available.
#endif
      return ERR_INSUFFICIENT_RESOURCES;
#ifdef ENOMEM
    case ENOMEM:  // Not enough space.
#endif
      return ERR_OUT_OF_MEMORY;
#ifdef ENOSPC
    case ENOSPC:  // No space left on device.
#endif
      return ERR_FILE_NO_SPACE;
#ifdef ENOSYS
    case ENOSYS:  // Function not implemented.
#endif
      return ERR_NOT_IMPLEMENTED;
#ifdef ENOTDIR
    case ENOTDIR:  // Not a directory.
#endif
      return ERR_FILE_NOT_FOUND;
#ifdef ENOTSUP
    case ENOTSUP:  // Operation not supported.
#endif
      return ERR_NOT_IMPLEMENTED;
#ifdef EPERM
    case EPERM:  // Operation not permitted.
#endif
      return ERR_ACCESS_DENIED;
#ifdef EROFS
    case EROFS:  // Read-only file system.
#endif
      return ERR_ACCESS_DENIED;
#ifdef ETXTBSY
    case ETXTBSY:  // Text file busy.
#endif
      return ERR_ACCESS_DENIED;
#ifdef EUSERS
    case EUSERS:  // Too many users.
#endif
      return ERR_INSUFFICIENT_RESOURCES;
#ifdef EMFILE
    case EMFILE:  // Too many open files.
#endif
      return ERR_INSUFFICIENT_RESOURCES;
#ifdef ENOPROTOOPT
    case ENOPROTOOPT:  // Protocol option not supported.
#endif
      return ERR_NOT_IMPLEMENTED;
#if BUILDFLAG(IS_FUCHSIA)
#ifdef EIO
    case EIO:
#endif
      // FDIO maps all unrecognized errors to EIO. If you see this message then
      // consider adding custom error in FDIO for the corresponding error.
      DLOG(FATAL) << "EIO was returned by FDIO.";
      return ERR_FAILED;
#endif  // BUILDFLAG(IS_FUCHSIA)

    case 0:
      return OK;
    default:
      LOG(WARNING) << "Unknown error " << base::safe_strerror(os_error) << " ("
                   << os_error << ") mapped to net::ERR_FAILED";
      return ERR_FAILED;
  }
}

}  // namespace net
