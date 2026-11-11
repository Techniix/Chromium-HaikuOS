// Copyright (C) 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "protostore/file-storage.h"

#include <cstdint>
#include <sys/stat.h>

#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"

namespace protostore {
namespace {
absl::Status IOError(absl::string_view context) {
  std::string message = absl::StrCat(context, ": ", strerror(errno));
  switch (errno) {
    case 0:
      return absl::OkStatus();
      break;
#ifdef EINVAL
    case EINVAL:        // Invalid argument
#endif
#ifdef ENAMETOOLONG
    case ENAMETOOLONG:  // Filename too long
#endif
#ifdef E2BIG
    case E2BIG:         // Argument list too long
#endif
#ifdef EDESTADDRREQ
    case EDESTADDRREQ:  // Destination address required
#endif
#ifdef EDOM
    case EDOM:          // Mathematics argument out of domain of function
#endif
#ifdef EFAULT
    case EFAULT:        // Bad address
#endif
#ifdef EILSEQ
    case EILSEQ:        // Illegal byte sequence
#endif
#ifdef ENOPROTOOPT
    case ENOPROTOOPT:   // Protocol not available
#endif
#ifdef ENOSTR
    case ENOSTR:        // Not a STREAM
#endif
#ifdef ENOTSOCK
    case ENOTSOCK:      // Not a socket
#endif
#ifdef ENOTTY
    case ENOTTY:        // Inappropriate I/O control operation
#endif
#ifdef EPROTOTYPE
    case EPROTOTYPE:    // Protocol wrong type for socket
#endif
#ifdef ESPIPE
    case ESPIPE:        // Invalid seek
#endif
      return absl::InvalidArgumentError(message);
      break;
#ifdef ETIMEDOUT
    case ETIMEDOUT:  // Connection timed out
#endif
#ifdef ETIME
    case ETIME:      // Timer expired
#endif
      return absl::DeadlineExceededError(message);
      break;
#ifdef ENODEV
    case ENODEV:  // No such device
#endif
#ifdef ENOENT
    case ENOENT:  // No such file or directory
#endif
#ifdef ENXIO
    case ENXIO:   // No such device or address
#endif
#ifdef ESRCH
    case ESRCH:   // No such process
#endif
      return absl::NotFoundError(message);
      break;
#ifdef EEXIST
    case EEXIST:         // File exists
#endif
#ifdef EADDRNOTAVAIL
    case EADDRNOTAVAIL:  // Address not available
#endif
#ifdef EALREADY
    case EALREADY:       // Connection already in progress
#endif
      return absl::AlreadyExistsError(message);
      break;
#ifdef EPERM
    case EPERM:   // Operation not permitted
#endif
#ifdef EACCES
    case EACCES:  // Permission denied
#endif
#ifdef EROFS
    case EROFS:   // Read only file system
#endif
      return absl::PermissionDeniedError(message);
      break;
#ifdef ENOTEMPTY
    case ENOTEMPTY:   // Directory not empty
#endif
#ifdef EISDIR
    case EISDIR:      // Is a directory
#endif
#ifdef ENOTDIR
    case ENOTDIR:     // Not a directory
#endif
#ifdef EADDRINUSE
    case EADDRINUSE:  // Address already in use
#endif
#ifdef EBADF
    case EBADF:       // Invalid file descriptor
#endif
#ifdef EBUSY
    case EBUSY:       // Device or resource busy
#endif
#ifdef ECHILD
    case ECHILD:      // No child processes
#endif
#ifdef EISCONN
    case EISCONN:     // Socket is connected
#endif
#if !defined(_WIN32)
#ifdef ENOTBLK
    case ENOTBLK:     // Block device required
#endif
#endif
#ifdef ENOTCONN
    case ENOTCONN:    // The socket is not connected
#endif
#ifdef EPIPE
    case EPIPE:       // Broken pipe
#endif
#if !defined(_WIN32)
#ifdef ESHUTDOWN
    case ESHUTDOWN:   // Cannot send after transport endpoint shutdown
#endif
#endif
#ifdef ETXTBSY
    case ETXTBSY:     // Text file busy
#endif
      return absl::FailedPreconditionError(message);
      break;
#ifdef ENOSPC
    case ENOSPC:   // No space left on device
#endif
#if !defined(_WIN32)
#ifdef EDQUOT
    case EDQUOT:   // Disk quota exceeded
#endif
#endif
#ifdef EMFILE
    case EMFILE:   // Too many open files
#endif
#ifdef EMLINK
    case EMLINK:   // Too many links
#endif
#ifdef ENFILE
    case ENFILE:   // Too many open files in system
#endif
#ifdef ENOBUFS
    case ENOBUFS:  // No buffer space available
#endif
#ifdef ENODATA
    case ENODATA:  // No message is available on the STREAM read queue
#endif
#ifdef ENOMEM
    case ENOMEM:   // Not enough space
#endif
#ifdef ENOSR
    case ENOSR:    // No STREAM resources
#endif
#if !defined(_WIN32)
#ifdef EUSERS
    case EUSERS:   // Too many users
#endif
#endif
      return absl::ResourceExhaustedError(message);
      break;
#ifdef EFBIG
    case EFBIG:      // File too large
#endif
#ifdef EOVERFLOW
    case EOVERFLOW:  // Value too large to be stored in data type
#endif
#ifdef ERANGE
    case ERANGE:     // Result too large
#endif
      return absl::OutOfRangeError(message);
      break;
#ifdef ENOSYS
    case ENOSYS:           // Function not implemented
#endif
#ifdef ENOTSUP
    case ENOTSUP:          // Operation not supported
#endif
#ifdef EAFNOSUPPORT
    case EAFNOSUPPORT:     // Address family not supported
#endif
#if !defined(_WIN32)
#ifdef EPFNOSUPPORT
    case EPFNOSUPPORT:     // Protocol family not supported
#endif
#endif
#ifdef EPROTONOSUPPORT
    case EPROTONOSUPPORT:  // Protocol not supported
#endif
#if !defined(_WIN32)
#ifdef ESOCKTNOSUPPORT
    case ESOCKTNOSUPPORT:  // Socket type not supported
#endif
#endif
#ifdef EXDEV
    case EXDEV:            // Improper link
#endif
      return absl::UnimplementedError(message);
      break;
#ifdef EAGAIN
    case EAGAIN:        // Resource temporarily unavailable
#endif
#ifdef ECONNREFUSED
    case ECONNREFUSED:  // Connection refused
#endif
#ifdef ECONNABORTED
    case ECONNABORTED:  // Connection aborted
#endif
#ifdef ECONNRESET
    case ECONNRESET:    // Connection reset
#endif
#ifdef EINTR
    case EINTR:         // Interrupted function call
#endif
#if !defined(_WIN32)
#ifdef EHOSTDOWN
    case EHOSTDOWN:     // Host is down
#endif
#endif
#ifdef EHOSTUNREACH
    case EHOSTUNREACH:  // Host is unreachable
#endif
#ifdef ENETDOWN
    case ENETDOWN:      // Network is down
#endif
#ifdef ENETRESET
    case ENETRESET:     // Connection aborted by network
#endif
#ifdef ENETUNREACH
    case ENETUNREACH:   // Network unreachable
#endif
#ifdef ENOLCK
    case ENOLCK:        // No locks available
#endif
#ifdef ENOLINK
    case ENOLINK:       // Link has been severed
#endif
#if !(defined(__APPLE__) || defined(__FreeBSD__) || defined(_WIN32) || defined(__OpenBSD__))
#ifdef ENONET
    case ENONET:  // Machine is not on the network
#endif
#endif
      return absl::UnavailableError(message);
      break;
#ifdef EDEADLK
    case EDEADLK:  // Resource deadlock avoided
#endif
#if !defined(_WIN32)
#ifdef ESTALE
    case ESTALE:   // Stale file handle
#endif
#endif
      return absl::AbortedError(message);
      break;
#ifdef ECANCELED
    case ECANCELED:  // Operation cancelled
#endif
      return absl::CancelledError(message);
      break;
    // NOTE: If you get any of the following (especially in a
    // reproducible way) and can propose a better mapping,
    // please email the owners about updating this mapping.
    // case EBADMSG:      // Bad message
    // case EIDRM:        // Identifier removed
    // case EINPROGRESS:  // Operation in progress
    // case EIO:          // I/O error
    // case ELOOP:        // Too many levels of symbolic links
    // case ENOEXEC:      // Exec format error
    // case ENOMSG:       // No message of the desired type
    // case EPROTO:       // Protocol error
    // #if !defined(_WIN32)
    // case EREMOTE:      // Object is remote
    // #endif
    default:
      return absl::UnknownError(message);
      break;
  }
}

absl::Status IncrementReadBuffer(absl::string_view filename,
    ssize_t bytes_read, char** buffer, size_t* bytes_to_read) {
  if (bytes_read > 0) {
    (*buffer) += bytes_read;
    (*bytes_to_read) -= bytes_read;
  } else if (bytes_read == 0) {
    return absl::OutOfRangeError(filename);
  } else if (errno == EINTR || errno == EAGAIN) {
    // Retry
  } else {
    return IOError(filename);
  }
  return absl::OkStatus();
}
}  // namespace

InputStream::InputStream(absl::string_view filename, FILE* file)
  : filename_(filename), file_(file) {}

InputStream::~InputStream() {
  if (file_ != nullptr) {
    fclose(file_);
    file_ = nullptr;
  }
}

absl::Status InputStream::Read(size_t n, absl::string_view* result,
    char* scratch) {
  absl::Status s;
  char* dst = scratch;
  while (n > 0 && s.ok()) {
    ssize_t bytes_read = fread(dst, 1, n, file_);
    s = IncrementReadBuffer(filename_, bytes_read, &dst, &n);
  }
  *result = absl::string_view(scratch, dst - scratch);
  return s;
}

OutputStream::OutputStream(absl::string_view filename, FILE* file)
  : filename_(filename), file_(file) {}

OutputStream::~OutputStream() {
  if (file_ != nullptr) {
    Close().IgnoreError();
  }
}

absl::Status OutputStream::Append(absl::string_view data) {
  size_t r = fwrite(data.data(), 1, data.size(), file_);
  if (r != data.size()) {
    return IOError(filename_);
  }
  return absl::OkStatus();
}

absl::Status OutputStream::Close() {
  absl::Status result;
  if (fflush(file_) != 0) {
    return IOError(filename_);
  }
  if (fclose(file_) != 0) {
    result = IOError(filename_);
  }
  file_ = NULL;
  return result;
}

absl::StatusOr<uint64_t> FileStorage::GetFileSize(
    const std::string& filename) const {
  struct stat sbuf;
  if (stat(filename.c_str(), &sbuf) != 0) {
    return IOError(filename);
  }
  return sbuf.st_size;
}

absl::StatusOr<std::unique_ptr<InputStream>> FileStorage::OpenForRead(
  const std::string& filename) const {
  FILE* file = fopen(filename.c_str(), "rb");
  if (file == nullptr) {
    return IOError(filename);
  }
  return absl::make_unique<InputStream>(filename, file);
}

absl::StatusOr<std::unique_ptr<OutputStream>> FileStorage::OpenForWrite(
  const std::string& filename) const {
  FILE* file = fopen(filename.c_str(), "wb");
  if (file == nullptr) {
    return IOError(filename);
  }
  return absl::make_unique<OutputStream>(filename, file);
}

}  // namespace protostore
