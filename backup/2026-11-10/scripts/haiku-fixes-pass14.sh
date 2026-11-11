#!/bin/bash
# Chromium-HaikuOS pass 14: native Haiku window title bar.
#
# Haiku's in-process Wayland server (wayland_server package) draws real Haiku
# window decorations (yellow tab, close/zoom buttons, borders) when a client
# asks for server-side decorations through the KDE "server-decoration"
# protocol. Chromium only knows the newer xdg-decoration protocol, which
# Haiku's server doesn't offer, so it always drew its own frame.
#
# This teaches Chromium's Wayland backend the KDE protocol as a fallback and
# makes "Use system title bar and borders" the default on Haiku.
# Safe to re-run. Needs a gn regen (ninja does it), then rebuilds the
# Wayland backend and relinks chrome.
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
cd "$SRC"

XML=third_party/wayland-protocols/kde/src/protocols/server-decoration.xml
if [ ! -f "$XML" ]; then
    echo "ERROR: $XML is missing from the tree; send me a screenshot of:"
    echo "  ls third_party/wayland-protocols/kde/src/protocols/"
    exit 1
fi

python3 <<'PY'
import os, re, sys

TAG = "Chromium-HaikuOS"
fails = []

def edit(path, fn, what=""):
    if not os.path.exists(path):
        print("    WARN missing", path); fails.append(path); return
    s = open(path).read()
    t = fn(s)
    if t is None:
        print("    WARN pattern not found:", path, what); fails.append(path); return
    if t != s:
        open(path, "w").write(t); print("    patched", path, what)
    else:
        print("    already done", path, what)

def once(marker, fn):
    """Run fn(s) only if marker isn't in s yet."""
    return lambda s: s if marker in s else fn(s)

def sub1(s, old, new):
    if s.count(old) != 1:
        return None
    return s.replace(old, new, 1)

# --- GN: protocol target + dependency -------------------------------------
edit("third_party/wayland-protocols/BUILD.gn", once('"org_kde_kwin_server_decoration"', lambda s: sub1(s,
    'wayland_protocol("org_kde_kwin_idle") {\n  sources = [ "kde/src/protocols/idle.xml" ]\n}\n',
    'wayland_protocol("org_kde_kwin_idle") {\n  sources = [ "kde/src/protocols/idle.xml" ]\n}\n'
    '\n# Chromium-HaikuOS: server-side decorations on Haiku.\n'
    'wayland_protocol("org_kde_kwin_server_decoration") {\n'
    '  sources = [ "kde/src/protocols/server-decoration.xml" ]\n}\n')),
    "protocol target")

edit("ui/ozone/platform/wayland/BUILD.gn", once(":org_kde_kwin_server_decoration", lambda s: sub1(s,
    '    "//third_party/wayland-protocols:org_kde_kwin_idle",\n',
    '    "//third_party/wayland-protocols:org_kde_kwin_idle",\n'
    '    "//third_party/wayland-protocols:org_kde_kwin_server_decoration",\n')),
    "dependency")

# --- WaylandConnection: bind the global -----------------------------------
H = "ui/ozone/platform/wayland/host/wayland_connection.h"
def conn_h(s):
    s = sub1(s, "\nnamespace ui {\n",
             "\n// " + TAG + ": KDE server-decoration (Haiku wayland_server).\n"
             "struct org_kde_kwin_server_decoration_manager;\n\nnamespace ui {\n")
    if s is None: return None
    s = sub1(s,
        "  zxdg_decoration_manager_v1* xdg_decoration_manager_v1() const {\n"
        "    return xdg_decoration_manager_.get();\n  }\n",
        "  zxdg_decoration_manager_v1* xdg_decoration_manager_v1() const {\n"
        "    return xdg_decoration_manager_.get();\n  }\n"
        "  // " + TAG + ": KDE server-decoration manager, if offered.\n"
        "  ::org_kde_kwin_server_decoration_manager* kde_server_decoration_manager()\n"
        "      const {\n    return kde_server_decoration_manager_;\n  }\n")
    if s is None: return None
    return sub1(s,
        "  wl::Object<zxdg_decoration_manager_v1> xdg_decoration_manager_;\n",
        "  wl::Object<zxdg_decoration_manager_v1> xdg_decoration_manager_;\n"
        "  // " + TAG + ": not owned by a wl::Object; lives as long as the\n"
        "  // connection.\n"
        "  ::org_kde_kwin_server_decoration_manager* kde_server_decoration_manager_ =\n"
        "      nullptr;\n")
edit(H, once("kde_server_decoration_manager_", conn_h), "accessor + member")

C = "ui/ozone/platform/wayland/host/wayland_connection.cc"
def conn_cc(s):
    s = sub1(s, "#include <presentation-time-client-protocol.h>\n",
             "#include <presentation-time-client-protocol.h>\n"
             "#include <server-decoration-client-protocol.h>  // " + TAG + "\n")
    if s is None: return None
    return sub1(s,
        "  } else if (!xdg_decoration_manager_ &&\n",
        "  } else if (!kde_server_decoration_manager_ &&\n"
        "             UNSAFE_TODO(strcmp(interface,\n"
        "                                \"org_kde_kwin_server_decoration_manager\")) ==\n"
        "                 0) {\n"
        "    // " + TAG + ": Haiku's wayland_server draws native decorations\n"
        "    // through this protocol.\n"
        "    kde_server_decoration_manager_ =\n"
        "        static_cast<::org_kde_kwin_server_decoration_manager*>(\n"
        "            wl_registry_bind(registry, name,\n"
        "                             &org_kde_kwin_server_decoration_manager_interface,\n"
        "                             1));\n"
        "    if (!kde_server_decoration_manager_) {\n"
        "      LOG(ERROR) << \"Failed to bind org_kde_kwin_server_decoration_manager\";\n"
        "      return;\n"
        "    }\n"
        "  } else if (!xdg_decoration_manager_ &&\n")
edit(C, once("org_kde_kwin_server_decoration_manager_interface", conn_cc), "bind global")

# --- XdgToplevel: per-window decoration object ----------------------------
TH = "ui/ozone/platform/wayland/host/xdg_toplevel.h"
def top_h(s):
    s = sub1(s, "\nnamespace ui {\n",
             "\n// " + TAG + ": KDE server-decoration (Haiku wayland_server).\n"
             "struct org_kde_kwin_server_decoration;\n\nnamespace ui {\n")
    if s is None: return None
    s = sub1(s, "  void InitializeXdgDecoration();\n",
             "  void InitializeXdgDecoration();\n\n"
             "  // " + TAG + ": org_kde_kwin_server_decoration listener.\n"
             "  static void OnKdeDecorationMode(\n"
             "      void* data,\n"
             "      ::org_kde_kwin_server_decoration* decoration,\n"
             "      uint32_t mode);\n")
    if s is None: return None
    return sub1(s,
        "  wl::Object<zxdg_toplevel_decoration_v1> zxdg_toplevel_decoration_;\n",
        "  wl::Object<zxdg_toplevel_decoration_v1> zxdg_toplevel_decoration_;\n"
        "  // " + TAG + ": used when only the KDE protocol is available.\n"
        "  ::org_kde_kwin_server_decoration* kde_decoration_ = nullptr;\n")
edit(TH, once("kde_decoration_", top_h), "decl")

TC = "ui/ozone/platform/wayland/host/xdg_toplevel.cc"
def top_cc(s):
    s = sub1(s, "#include <xdg-decoration-unstable-v1-client-protocol.h>\n",
             "#include <server-decoration-client-protocol.h>  // " + TAG + "\n"
             "#include <xdg-decoration-unstable-v1-client-protocol.h>\n")
    if s is None: return None
    s = sub1(s, '#include "ui/ozone/platform/wayland/host/wayland_shm_buffer.h"\n',
             '#include "ui/ozone/platform/wayland/host/wayland_shm_buffer.h"\n'
             '#include "ui/ozone/platform/wayland/host/wayland_surface.h"\n')
    if s is None: return None
    s = sub1(s, "XdgToplevel::~XdgToplevel() = default;\n",
             "XdgToplevel::~XdgToplevel() {\n"
             "  if (kde_decoration_) {  // " + TAG + "\n"
             "    org_kde_kwin_server_decoration_release(kde_decoration_);\n"
             "    kde_decoration_ = nullptr;\n"
             "  }\n"
             "}\n")
    if s is None: return None
    s = sub1(s,
        "void XdgToplevel::SetTopLevelDecorationMode(DecorationMode requested_mode) {\n",
        "// static\n"
        "void XdgToplevel::OnKdeDecorationMode(\n"
        "    void* data,\n"
        "    ::org_kde_kwin_server_decoration* decoration,\n"
        "    uint32_t mode) {\n"
        "  auto* self = static_cast<XdgToplevel*>(data);\n"
        "  DCHECK(self);\n"
        "  switch (mode) {\n"
        "    case ORG_KDE_KWIN_SERVER_DECORATION_MODE_SERVER:\n"
        "      self->decoration_mode_ = DecorationMode::kServerSide;\n"
        "      break;\n"
        "    case ORG_KDE_KWIN_SERVER_DECORATION_MODE_CLIENT:\n"
        "      self->decoration_mode_ = DecorationMode::kClientSide;\n"
        "      break;\n"
        "    default:\n"
        "      self->decoration_mode_ = DecorationMode::kNone;\n"
        "      break;\n"
        "  }\n"
        "}\n\n"
        "void XdgToplevel::SetTopLevelDecorationMode(DecorationMode requested_mode) {\n"
        "  if (kde_decoration_) {  // " + TAG + "\n"
        "    if (requested_mode != decoration_mode_) {\n"
        "      org_kde_kwin_server_decoration_request_mode(\n"
        "          kde_decoration_,\n"
        "          requested_mode == DecorationMode::kServerSide\n"
        "              ? ORG_KDE_KWIN_SERVER_DECORATION_MODE_SERVER\n"
        "              : ORG_KDE_KWIN_SERVER_DECORATION_MODE_CLIENT);\n"
        "    }\n"
        "    return;\n"
        "  }\n")
    if s is None: return None
    return sub1(s,
        "        zxdg_toplevel_decoration_.get(), &kToplevelDecorationListener, this);\n"
        "  }\n}\n",
        "        zxdg_toplevel_decoration_.get(), &kToplevelDecorationListener, this);\n"
        "  } else if (connection()->kde_server_decoration_manager()) {\n"
        "    // " + TAG + ": fall back to the KDE protocol (Haiku wayland_server).\n"
        "    kde_decoration_ = org_kde_kwin_server_decoration_manager_create(\n"
        "        connection()->kde_server_decoration_manager(),\n"
        "        window()->root_surface()->surface());\n"
        "    static constexpr org_kde_kwin_server_decoration_listener\n"
        "        kKdeDecorationListener = {\n"
        "            .mode = &OnKdeDecorationMode,\n"
        "        };\n"
        "    org_kde_kwin_server_decoration_add_listener(\n"
        "        kde_decoration_, &kKdeDecorationListener, this);\n"
        "  }\n}\n")
edit(TC, once("OnKdeDecorationMode", top_cc), "KDE decoration")

# --- Platform properties: report SSD support, default to system frame -----
OP = "ui/ozone/platform/wayland/ozone_platform_wayland.cc"
def oz(s):
    s = sub1(s,
        "    return connection_->xdg_decoration_manager_v1() == nullptr;\n",
        "    return connection_->xdg_decoration_manager_v1() == nullptr &&\n"
        "           connection_->kde_server_decoration_manager() == nullptr;  // " + TAG + "\n")
    if s is None: return None
    s = sub1(s,
        "          (connection_->xdg_decoration_manager_v1() != nullptr &&\n",
        "          ((connection_->xdg_decoration_manager_v1() != nullptr ||\n"
        "            connection_->kde_server_decoration_manager() != nullptr) &&  // " + TAG + "\n")
    if s is None: return None
    s = sub1(s,
        "      properties->custom_frame_pref_default = true;\n",
        "#if BUILDFLAG(IS_HAIKU)\n"
        "      // " + TAG + ": use the native Haiku window frame by default.\n"
        "      properties->custom_frame_pref_default = false;\n"
        "#else\n"
        "      properties->custom_frame_pref_default = true;\n"
        "#endif\n")
    if s is None: return None
    if '#include "build/build_config.h"' not in s:
        s = sub1(s, "#include <vector>\n", "#include <vector>\n\n#include \"build/build_config.h\"\n")
    return s
edit(OP, once("kde_server_decoration_manager", oz), "platform properties")

if fails:
    print("\n==> Some edits did not apply; send me a screenshot of the WARN lines.")
    sys.exit(1)
PY

echo "==> Now rebuild (ninja reruns gn first; keep the two export lines set):"
echo "  ninja -C out/Release -j8 -k 0 chrome 2>&1 | tee ~/build14.log"
