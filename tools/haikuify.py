#!/usr/bin/env python3
"""Extend FreeBSD's BSD guards in a Chromium tree to also cover Haiku.

Run this on a Chromium source tree *after* the FreeBSD port patches have been
applied. FreeBSD (like Haiku) builds Chromium as `is_linux` in GN while the C++
side sees BUILDFLAG(IS_LINUX) == 0, and marks every place where it needs the
"desktop Unix, but not Linux" behaviour with BUILDFLAG(IS_BSD) / is_bsd. Most of
those places are exactly what Haiku needs too, so this tool rewrites

    BUILDFLAG(IS_BSD)   ->  (BUILDFLAG(IS_BSD) || BUILDFLAG(IS_HAIKU))
    is_bsd              ->  (is_bsd || is_haiku)

The rewrite preserves operator precedence, so negated guards such as
`!BUILDFLAG(IS_BSD)` keep their meaning (Haiku is excluded from the Linux-only
branch, exactly like BSD).

A guard is NOT rewritten when the code it controls uses BSD-kernel interfaces
that Haiku does not provide (sysctl, kqueue, kinfo_proc, pthread_*_np, ...).
Those sites are written to a report: they are the hand-porting worklist where
Haiku needs its own implementation (usually with a BUILDFLAG(IS_HAIKU) branch).

Usage:
    haikuify.py SRC_DIR [--report report.md] [--dry-run] [--paths a b ...]

The tool is idempotent: already-converted guards are left alone. Guards that
must stay BSD-only on purpose carry a "haikuify: bsd-only" comment on the same
line or the line above, and are never converted.

Run it before the Haiku patches (scripts/prepare-tree.sh does). On a tree that
already has them, only --python-only is safe.
"""

import argparse
import os
import re
import sys
from dataclasses import dataclass, field

# Tokens that mark code as depending on BSD-kernel or BSD-userland interfaces
# that Haiku lacks. Matching is case-sensitive substring/regex on code lines.
BSD_ONLY_PATTERNS = [
    r"\bsysctl", r"\bsysctlbyname\b", r"\bCTL_KERN\b", r"\bCTL_HW\b",
    r"\bKERN_[A-Z_]+\b", r"\bHW_[A-Z_]+\b", r"\bkinfo_", r"\bkvm_",
    r"\bkqueue\b", r"\bkevent\b", r"\bEVFILT_", r"\bNOTE_[A-Z]+\b",
    r"\bprocctl\b", r"\belf_aux_info\b", r"pthread_np\.h",
    r"\bpthread_[a-z_]+_np\b", r"\bgetthrid\b", r"\bunveil\b", r"\bpledge\b",
    r"\bdevd\b", r"libutil", r"epoll[-_]shim", r"sys/user\.h",
    r"sys/procctl\.h", r"sys/ucred\.h", r"\bxucred\b", r"\bLOCAL_PEERCRED\b",
    r"\bsndio\b", r"\bcapsicum\b", r"\bcap_enter\b", r"__FreeBSD_version",
    r"\bdevstat\b", r"\bcpuset", r"_freebsd\.(cc|h|mm|c)\b",
    r"_openbsd\.(cc|h|mm|c)\b", r"_bsd\.(cc|h|mm|c)\b", r"\bkenv\b",
    r"\bsys/event\.h\b", r"\bsys/sysctl\.h\b", r"\bmachine/", r"\bdev/usb",
    r"\bsetproctitle\b", r"\bgetprogname\b", r"\bkldload\b", r"\bjail\b",
    r"sys/syscall\.h", r"\bsyscall\s*\(", r"\bSYS_[a-z_]+\b",
]
BSD_ONLY_RE = re.compile("|".join(BSD_ONLY_PATTERNS))

# BSD-libc functions that recent Haiku may or may not provide (some live in
# libbsd). Guards over these are still converted, but listed in the report so
# they can be checked with tools/probe-haiku-libc.sh on the target.
VERIFY_PATTERNS = [
    r"\bgetentropy\b", r"\barc4random\w*", r"\bgetdents\b", r"\bmemfd_create\b",
    r"\bpipe2\b", r"\baccept4\b", r"\bMSG_NOSIGNAL\b", r"\bstrtonum\b",
    r"\breallocarray\b", r"\bexplicit_bzero\b", r"\bposix_fallocate\b",
    r"\bSOCK_CLOEXEC\b", r"\bSOCK_NONBLOCK\b", r"\bMAP_ANON\b",
    r"\bMADV_FREE\b", r"\bMADV_DONTNEED\b", r"\bmalloc_usable_size\b",
    r"\bsched_getaffinity\b", r"\bpthread_getattr_np\b", r"\bgetpeereid\b",
    r"\bSO_PEERCRED\b", r"\bbacktrace\b", r"\bdl_iterate_phdr\b",
    r"\bfutimens\b", r"\butimensat\b", r"\bppoll\b", r"\bmkostemp\b",
]
VERIFY_RE = re.compile("|".join(VERIFY_PATTERNS))


def verify_tokens(lines):
    found = set()
    for l in lines:
        for m in VERIFY_RE.finditer(strip_comment(l)):
            found.add(m.group(0))
    return sorted(found)

# Matches BUILDFLAG(IS_BSD) and PartitionAlloc's PA_BUILDFLAG(IS_BSD), but not
# other identifiers that merely end in "BUILDFLAG", and not guards that were
# already converted.
CXX_GUARD_RE = re.compile(
    r"(?<![A-Za-z0-9_])(PA_)?BUILDFLAG\(IS_BSD\)"
    r"(?! \|\| (?:PA_)?BUILDFLAG\(IS_HAIKU\)\))")


def _cxx_repl(m):
    p = m.group(1) or ""
    return f"({p}BUILDFLAG(IS_BSD) || {p}BUILDFLAG(IS_HAIKU))"


CXX_REPL = _cxx_repl
# Never rewrite an assignment target (`is_bsd = ...` in BUILDCONFIG.gn) or a
# `defined(is_bsd)` probe; only uses of the value.
GN_GUARD_RE = re.compile(
    r"(?<![\w.])(?<!defined\()is_bsd\b(?!\s*[+-]?=(?!=))(?! \|\| is_haiku\))")
GN_REPL = "(is_bsd || is_haiku)"

CXX_EXTS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".mm", ".m", ".inc", ".def"}
GN_EXTS = {".gn", ".gni"}

SKIP_DIRS = {".git", "out", "node_modules", ".cipd"}


@dataclass
class Site:
    path: str
    line: int
    text: str
    reasons: list = field(default_factory=list)


def strip_comment(line):
    i = line.find("//")
    return line if i < 0 else line[:i]


def bsd_tokens(lines):
    found = set()
    for l in lines:
        for m in BSD_ONLY_RE.finditer(strip_comment(l)):
            found.add(m.group(0))
    return sorted(found)


DIRECTIVE_RE = re.compile(r"^\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b")


def cxx_chain_extent(lines, start):
    """Given the index of an #if/#elif line, return (first, last) indices of the
    whole #if ... #endif chain that contains it."""
    # Walk backwards to the opening #if of this chain.
    depth = 0
    first = start
    i = start
    kind = DIRECTIVE_RE.match(lines[start]).group(1)
    if kind == "elif":
        i = start - 1
        while i >= 0:
            m = DIRECTIVE_RE.match(lines[i])
            if m:
                k = m.group(1)
                if k == "endif":
                    depth += 1
                elif k in ("if", "ifdef", "ifndef"):
                    if depth == 0:
                        first = i
                        break
                    depth -= 1
            i -= 1
    # Walk forwards to the matching #endif.
    depth = 0
    last = len(lines) - 1
    for j in range(first, len(lines)):
        m = DIRECTIVE_RE.match(lines[j])
        if not m:
            continue
        k = m.group(1)
        if k in ("if", "ifdef", "ifndef"):
            depth += 1
        elif k == "endif":
            depth -= 1
            if depth == 0:
                last = j
                break
    return first, last


def cxx_branches(lines, first, last):
    """Split an #if chain [first, last] into branches: list of (start, end)
    index pairs, where start is the directive line and end is the line before
    the next same-level directive."""
    heads = []
    depth = 0
    for j in range(first, last + 1):
        m = DIRECTIVE_RE.match(lines[j])
        if not m:
            continue
        k = m.group(1)
        if k in ("if", "ifdef", "ifndef"):
            depth += 1
            if depth == 1:
                heads.append(j)
        elif k == "endif":
            depth -= 1
        elif depth == 1:
            heads.append(j)
    heads.append(last)
    return [(heads[n], heads[n + 1] - 1) for n in range(len(heads) - 1)]


NEGATED_RE = re.compile(r"!\s*\(?\s*(PA_)?BUILDFLAG\(IS_BSD\)")


def directive_logical_line(lines, i):
    """Return (start, end) of a possibly backslash-continued directive."""
    end = i
    while end < len(lines) - 1 and lines[end].rstrip().endswith("\\"):
        end += 1
    return i, end


# Start of a function definition at column 0: "<type> name(" not ending in ';'.
# The parameter list may continue on later lines.
FUNC_DEF_RE = re.compile(
    r"^(?:[A-Za-z_][\w:<>,\*&]*\s+[\*&]*)+([A-Za-z_]\w*)\s*\((?!.*;\s*$)")
CXX_KEYWORDS = {"if", "for", "while", "switch", "return", "sizeof", "defined",
                "BUILDFLAG", "PA_BUILDFLAG", "catch", "decltype", "static_assert"}


def defined_functions(lines):
    """Names of functions defined (not just called) in `lines`."""
    names = set()
    for l in lines:
        code = strip_comment(l).rstrip()
        if not code or code[0] in " \t#":
            continue
        m = FUNC_DEF_RE.match(code)
        if not m:
            continue
        name = m.group(1)
        if name in CXX_KEYWORDS or name.isupper():
            continue
        names.add(name)
    return names


def guard_body(lines, i):
    """Lines selected for Haiku once the guard on line i is extended."""
    d = i
    while d > 0 and lines[d - 1].rstrip().endswith("\\"):
        d -= 1
    m = DIRECTIVE_RE.match(lines[d])
    if m and m.group(1) in ("if", "elif"):
        first, last = cxx_chain_extent(lines, d)
        branches = cxx_branches(lines, first, last)
        idx = next((n for n, (s, e) in enumerate(branches) if s == d), None)
        if idx is None:
            return lines[first:last + 1]
        if NEGATED_RE.search(lines[i]):
            # Haiku will now skip this branch: check where it lands instead.
            return [l for s, e in branches[idx + 1:] for l in lines[s:e + 1]]
        s, e = branches[idx]
        return lines[s:e + 1]
    # Ordinary code (if constexpr, constants, ternaries): look at a window
    # around the use.
    return lines[max(0, i - 3): i + 25]


BSD_ONLY_MARKER = "haikuify: bsd-only"


def _marked_bsd_only(lines, i):
    """A deliberate BSD-only guard, marked on its line or the line above."""
    return BSD_ONLY_MARKER in lines[i] or (i > 0 and BSD_ONLY_MARKER in lines[i - 1])


def classify_cxx(lines, extra_re=None):
    """Return {line_index: (body, bsd_tokens)} for unconverted BSD guards."""
    out = {}
    for i, line in enumerate(lines):
        if "BUILDFLAG(IS_BSD)" not in line or not CXX_GUARD_RE.search(line):
            continue
        if _marked_bsd_only(lines, i):
            continue
        body = guard_body(lines, i)
        toks = bsd_tokens(body)
        if extra_re is not None:
            for l in body:
                for m in extra_re.finditer(strip_comment(l)):
                    toks = sorted(set(toks) | {m.group(0) + "() [BSD-only here]"})
        out[i] = (body, toks)
    return out


def process_cxx(path, text, report, stats, verify):
    lines = text.split("\n")
    # Pass 1: find guards that stay BSD-only, and the functions those blocks
    # define. A block extended to Haiku must not call them, or Haiku would
    # reference a function it never compiles (e.g. a kqueue-based helper).
    first = classify_cxx(lines)
    bsd_only_funcs = set()
    for i, (body, toks) in first.items():
        if toks and not NEGATED_RE.search(lines[i]):
            bsd_only_funcs |= defined_functions(body)
    extra_re = None
    if bsd_only_funcs:
        extra_re = re.compile(
            r"\b(" + "|".join(sorted(map(re.escape, bsd_only_funcs))) + r")(?=\s*\()")
    # Pass 2: decide with the extra knowledge, then rewrite.
    result = classify_cxx(lines, extra_re)
    changed = False
    for i in sorted(result):
        body, toks = result[i]
        line = lines[i]
        if toks:
            report.append(Site(path, i + 1, line.strip(), toks))
            stats["manual"] += 1
            continue
        new = CXX_GUARD_RE.sub(CXX_REPL, line)
        if new != line:
            lines[i] = new
            changed = True
            stats["converted"] += 1
            vt = verify_tokens(body)
            if vt:
                verify.append(Site(path, i + 1, line.strip(), vt))
    return ("\n".join(lines), changed)


def gn_block_extent(lines, i):
    """For a GN line, return the lines of the `if (...) { ... } else ...` block
    it opens, or a small window if it is not an if-statement."""
    stripped = lines[i].lstrip()
    if not re.match(r"(\}\s*else\s+)?if\s*\(", stripped):
        return lines[max(0, i - 2): i + 6]
    depth = 0
    seen_open = False
    out = []
    for j in range(i, len(lines)):
        l = strip_gn_comment(lines[j])
        out.append(lines[j])
        depth += l.count("{") - l.count("}")
        if "{" in l:
            seen_open = True
        if seen_open and depth <= 0:
            # Include a following else / else if chain.
            nxt = lines[j + 1].lstrip() if j + 1 < len(lines) else ""
            if l.rstrip().endswith("{"):
                continue
            if nxt.startswith("} else") or nxt.startswith("else"):
                continue
            break
    return out


def strip_gn_comment(line):
    i = line.find("#")
    return line if i < 0 else line[:i]


def process_gn(path, text, report, stats, verify):
    lines = text.split("\n")
    changed = False
    for i, line in enumerate(lines):
        code = strip_gn_comment(line)
        if not GN_GUARD_RE.search(code):
            continue
        if _marked_bsd_only(lines, i):
            continue
        body = gn_block_extent(lines, i)
        toks = bsd_tokens([strip_gn_comment(b) for b in body])
        if toks:
            report.append(Site(path, i + 1, line.strip(), toks))
            stats["manual"] += 1
            continue
        new_code = GN_GUARD_RE.sub(GN_REPL, code)
        lines[i] = new_code + line[len(code):]
        changed = True
        stats["converted"] += 1
    return ("\n".join(lines), changed)


# --- Python build helpers -------------------------------------------------
# Several build scripts map an OS name to Linux-like behaviour ("freebsd" ->
# LINUX_PLATFORM, platform.system() == "FreeBSD" -> node-freebsd, ...). Mirror
# every FreeBSD entry for Haiku: platform.system() is "Haiku" there, GN's
# target_os is "haiku", and sys.platform starts with "haiku".
PY_DICT_KEY_RE = re.compile(r"""^(\s*)(['"])(freebsd|FreeBSD)\2(\s*:.*)$""")
# A list/tuple item: preceded by "[", "(" or "," and followed by ",", ")",
# "]" or end of line (multi-line lists).
PY_LIST_ITEM_RE = re.compile(
    r"""(?:(?<=[\[(,])|(?<=[\[(,]\s)|^(?=\s*['"]))\s*(['"])freebsd\1(?=\s*(?:[,)\]]|$))""")
PY_EQ_RE = re.compile(r"""([\w.()\[\]]+)\s*==\s*(['"])freebsd\2""")


def _haiku_value(text):
    # node.py: ('freebsd', 'node-freebsd', 'bin', 'node') -> haiku paths.
    return text.replace("node-freebsd", "node-haiku").replace(
        "'freebsd'", "'haiku'").replace('"freebsd"', '"haiku"')


# A previous version of this tool turned a lone call argument such as
# startswith('freebsd') into startswith('freebsd', 'haiku'), which passes
# 'haiku' as the start index. Recognise that output so it can be repaired.
PY_BAD_CALL_RE = re.compile(
    r"""([\w.]*\b\w+)\((['"])freebsd\2, \2haiku\2\)""")
PY_SOLE_ARG_RE = re.compile(r"""(\w+)\(\s*(['"])freebsd\2\s*\)""")
PY_OURS_RE = re.compile(r"""freebsd['"]\)?, \(?['"]haiku""")


def _is_ours(lines, i):
    """True if line i mentions Haiku only because this tool added it."""
    line = lines[i]
    if PY_OURS_RE.search(line):
        return True
    # A 'haiku': ... dict entry right after the 'freebsd': ... one it mirrors.
    return (i > 0 and
            re.match(r"""^\s*['"](haiku|Haiku)['"]\s*:""", line) is not None and
            re.match(r"""^\s*['"](freebsd|FreeBSD)['"]\s*:""", lines[i - 1])
            is not None)


def _haiku_aware(lines):
    """The file handled Haiku on its own, before this tool touched it."""
    return any("haiku" in l.lower() and not _is_ours(lines, i)
               for i, l in enumerate(lines))


def _enclosing_call(line, pos):
    """If the string at `pos` is inside a call's parentheses on this line,
    return the called name; else None (list, tuple, or multi-line context)."""
    depth = 0
    for j in range(pos - 1, -1, -1):
        c = line[j]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth:
                depth -= 1
                continue
            if c != "(":
                return None
            k = j - 1
            while k >= 0 and line[k] == " ":
                k -= 1
            m = re.search(r"([\w.]+)$", line[:k + 1])
            if not m or m.group(1) in ("in", "not", "and", "or", "return",
                                       "if", "elif", "else", "for", "yield"):
                return None
            return m.group(1)
    return None


def process_py(path, text, report, stats):
    if "freebsd" not in text.lower() or "test" in os.path.basename(path):
        return text, False
    lines = text.split("\n")
    changed = False

    # Repair output of the old, buggy call-argument rewrite first.
    aware = None
    for i, line in enumerate(lines):
        if not PY_BAD_CALL_RE.search(line):
            continue
        if aware is None:
            aware = _haiku_aware(lines)

        def fix(m):
            name, q = m.group(1), m.group(2)
            if not aware and name.split(".")[-1] in ("startswith", "endswith"):
                return f"{name}(({q}freebsd{q}, {q}haiku{q}))"
            return f"{name}({q}freebsd{q})"
        lines[i] = PY_BAD_CALL_RE.sub(fix, line)
        changed = True
        stats["repaired"] = stats.get("repaired", 0) + 1

    # A file that already handles Haiku itself (e.g. GN's build/gen.py) is
    # left alone: adding Haiku to its FreeBSD cases would shadow its own.
    if _haiku_aware(lines):
        return "\n".join(lines), changed

    out = []
    for i, line in enumerate(lines):
        out.append(line)
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        m = PY_DICT_KEY_RE.match(line)
        if m:
            if "haiku" in nxt.lower():
                continue
            key = "haiku" if m.group(3) == "freebsd" else "Haiku"
            out.append(f"{m.group(1)}{m.group(2)}{key}{m.group(2)}"
                       f"{_haiku_value(m.group(4))}")
            changed = True
            stats["converted"] += 1
            continue
        if "haiku" in line.lower() or "haiku" in nxt.lower():
            continue
        if PY_EQ_RE.search(line):
            out[-1] = PY_EQ_RE.sub(
                lambda mm: (f"{mm.group(1)} in ({mm.group(2)}freebsd{mm.group(2)}, "
                            f"{mm.group(2)}haiku{mm.group(2)})"), line)
            changed = True
            stats["converted"] += 1
            continue
        sole = PY_SOLE_ARG_RE.search(line)
        if sole:
            if sole.group(1) in ("startswith", "endswith"):
                q = sole.group(2)
                out[-1] = PY_SOLE_ARG_RE.sub(
                    lambda mm: f"{mm.group(1)}(({q}freebsd{q}, {q}haiku{q}))",
                    line)
                changed = True
                stats["converted"] += 1
            else:
                report.append(Site(path, i + 1, line.strip(),
                                   [f"'freebsd' passed to {sole.group(1)}() (Python)"]))
                stats["manual"] += 1
            continue
        items = [mm for mm in PY_LIST_ITEM_RE.finditer(line)
                 if _enclosing_call(line, mm.start(1)) is None]
        if items:
            for mm in reversed(items):
                q = mm.group(1)
                line = line[:mm.end()] + f", {q}haiku{q}" + line[mm.end():]
            out[-1] = line
            changed = True
            stats["converted"] += 1
            continue
        if re.search(r"""['"]freebsd['"]""", line):
            report.append(Site(path, i + 1, line.strip(),
                               ["freebsd string (Python), not a list item"]))
            stats["manual"] += 1
            continue
        if re.search(r"""['"]FreeBSD['"]""", line):
            report.append(Site(path, i + 1, line.strip(),
                               ["FreeBSD platform check (Python)"]))
            stats["manual"] += 1
    return "\n".join(out), changed


def iter_files(root, subpaths):
    tops = [os.path.join(root, p) for p in subpaths] if subpaths else [root]
    for top in tops:
        if os.path.isfile(top):
            yield top
            continue
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                yield os.path.join(dirpath, fn)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("src", help="Chromium src/ directory")
    ap.add_argument("--report", default="haikuify-report.md")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--paths", nargs="*", help="limit to these subpaths of src")
    ap.add_argument("--python-only", action="store_true",
                    help="only process Python files (safe to run on a tree "
                         "that already has the Haiku patches applied)")
    args = ap.parse_args()

    report = []
    verify = []
    stats = {"converted": 0, "manual": 0, "files": 0}
    for path in iter_files(args.src, args.paths):
        ext = os.path.splitext(path)[1]
        if ext not in CXX_EXTS and ext not in GN_EXTS and ext != ".py":
            continue
        if args.python_only and ext != ".py":
            continue
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except (UnicodeDecodeError, OSError):
            continue
        if ext == ".py":
            new, changed = process_py(os.path.relpath(path, args.src), text,
                                      report, stats)
        elif ext in GN_EXTS:
            if "is_bsd" not in text:
                continue
            new, changed = process_gn(os.path.relpath(path, args.src), text, report, stats, verify)
        else:
            if "IS_BSD" not in text:
                continue
            new, changed = process_cxx(os.path.relpath(path, args.src), text, report, stats, verify)
        if changed:
            stats["files"] += 1
            if not args.dry_run:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(new)

    with open(args.report, "w", encoding="utf-8") as f:
        f.write("# haikuify report\n\n")
        f.write(f"- Guards extended to Haiku: {stats['converted']} "
                f"(in {stats['files']} files)\n")
        f.write(f"- Guards left BSD-only (need a Haiku implementation): "
                f"{stats['manual']}\n\n")
        f.write("## Hand-porting worklist\n\n")
        f.write("Each site below guards code that uses BSD-only interfaces. "
                "Haiku currently falls through to the other branch here; add a "
                "`BUILDFLAG(IS_HAIKU)` / `is_haiku` implementation or confirm "
                "the fallback is correct.\n\n")
        cur = None
        for s in sorted(report, key=lambda s: (s.path, s.line)):
            if s.path != cur:
                f.write(f"\n### `{s.path}`\n\n")
                cur = s.path
            f.write(f"- L{s.line}: `{s.text[:110]}` — uses {', '.join(s.reasons)}\n")
        f.write("\n## Converted, but verify on Haiku\n\n")
        f.write("These guards now include Haiku, and the code they select uses "
                "BSD-libc functions. Run `tools/probe-haiku-libc.sh` on the "
                "Haiku machine; for any symbol it reports missing, add a Haiku "
                "branch or a shim (see `patches/haiku/` and `compat/`).\n\n")
        cur = None
        for s in sorted(verify, key=lambda s: (s.path, s.line)):
            if s.path != cur:
                f.write(f"\n### `{s.path}`\n\n")
                cur = s.path
            f.write(f"- L{s.line}: `{s.text[:110]}` — uses {', '.join(s.reasons)}\n")
    if stats.get("repaired"):
        print(f"repaired={stats['repaired']} lines from an earlier haikuify version")
    print(f"converted={stats['converted']} files={stats['files']} "
          f"manual={stats['manual']} verify={len(verify)} report={args.report}"
          f"{' (dry run)' if args.dry_run else ''}")


if __name__ == "__main__":
    sys.exit(main())
