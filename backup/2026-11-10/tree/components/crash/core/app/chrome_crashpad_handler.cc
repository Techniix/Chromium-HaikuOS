// Copyright 2019 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Forward declare this for macOS (it's only defined by crashpad on Android.)
extern "C" int CrashpadHandlerMain(int argc, char* argv[]);

int main(int argc, char* argv[]) {
#if defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__HAIKU__)
  return -1;
#else
  return CrashpadHandlerMain(argc, argv);
#endif
}
