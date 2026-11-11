// Copyright 2022 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef COMPONENTS_NAMED_MOJO_IPC_SERVER_CONNECTION_INFO_H_
#define COMPONENTS_NAMED_MOJO_IPC_SERVER_CONNECTION_INFO_H_

#include "base/process/process.h"
#include "base/process/process_handle.h"
#include "build/buildflag.h"

#if BUILDFLAG(IS_WIN)
#include <cstdint>

#include "base/win/scoped_handle.h"
#elif BUILDFLAG(IS_MAC)
#include <bsm/libbsm.h>
#elif BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_BSD)
#if !BUILDFLAG(IS_HAIKU)
#include <sys/ucred.h>
#endif
#include <sys/socket.h>
#include <sys/socket.h>
#endif

#if BUILDFLAG(IS_HAIKU)
#include <sys/types.h>
#include <sys/socket.h>
#if !defined(SO_PEERCRED)
#define SO_PEERCRED (-1)  // getsockopt() fails cleanly
#endif
#endif

namespace named_mojo_ipc_server {

#if BUILDFLAG(IS_HAIKU)
// Haiku: no struct ucred in its headers; same layout as SO_PEERCRED's.
struct ucred {
  pid_t pid;
  uid_t uid;
  gid_t gid;
};
#endif

// ConnectionInfo encapsulates information useful for verifying a potential
// endpoint.
struct ConnectionInfo {
  ConnectionInfo();
  ~ConnectionInfo();
  ConnectionInfo(const ConnectionInfo&) = delete;
  ConnectionInfo& operator=(const ConnectionInfo&) = delete;

  base::ProcessId pid{};
#if BUILDFLAG(IS_MAC)
  audit_token_t audit_token{};
#elif BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_OPENBSD) || BUILDFLAG(IS_HAIKU) // ucred
  ucred credentials{};
#elif BUILDFLAG(IS_FREEBSD)
  xucred credentials{};
#elif BUILDFLAG(IS_WIN)
  // The process of the peer. Only valid if `include_peer_process_info` is true
  // in EndpointOptions.
  base::Process process;

  // The Windows session ID of the peer.
  uint32_t session_id = UINT32_MAX;
#endif
};

}  // namespace named_mojo_ipc_server

#endif  // COMPONENTS_NAMED_MOJO_IPC_SERVER_CONNECTION_INFO_H_
