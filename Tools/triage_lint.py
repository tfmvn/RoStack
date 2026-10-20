#!/usr/bin/env python3
"""Triage stylua/selene findings on the library against the src/ baseline.

For every library file that fails a linter, work out the ORIGINAL `src/`
file it was extracted from and re-run the same linter on that original.
If the original fails too, the finding is PRE-EXISTING in the source game
and was carried over unchanged by the extraction.

Findings on library-authored files (no src/ original) are reported
separately -- those are the extraction's own.

Usage:
    python ReusableSystems/Tools/triage_lint.py
"""

import os
import re
import subprocess
import sys

LIB = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO = os.path.abspath(os.path.join(LIB, ".."))

# selene's output contains box-drawing characters; the default Windows
# console encoding cannot encode them.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass


def library_to_src(rel):
    """Map a library-relative path to its `src/` original, or None."""
    m = re.match(r"^Systems/[^/]+/Source/(.*)$", rel)
    if m:
        return os.path.join(REPO, "src", m.group(1))
    if rel.startswith("Shared/Types/"):
        return os.path.join(REPO, "src/ReplicatedStorage/Types", rel[len("Shared/Types/"):])
    if rel.startswith("Shared/Utilities/"):
        return os.path.join(REPO, "src/ReplicatedStorage/Utility", rel[len("Shared/Utilities/"):])
    if rel.startswith("Shared/CommonModules/"):
        tail = rel[len("Shared/CommonModules/"):]
        if tail == "ShopAnimations.lua":
            return os.path.join(REPO, "src/ReplicatedStorage/ShopAnimations.lua")
        return os.path.join(REPO, "src/ReplicatedStorage/Utility", tail)
    # Specs: the library distributes them by owning system, but the source
    # game keeps all 89 flat in one folder.
    m = re.match(r"^Systems/[^/]+/Tests/(.*\.spec\.lua)$", rel)
    if m:
        return os.path.join(REPO, "src/Tests/ServerScriptService/TestEZTests", m.group(1))
    m = re.match(r"^Tests/(IntegrationTests/)?(.*\.spec\.lua)$", rel)
    if m:
        return os.path.join(REPO, "src/Tests/ServerScriptService/TestEZTests", m.group(2))
    if rel == "Tests/_Helpers.lua":
        return os.path.join(REPO, "src/Tests/ServerScriptService/TestEZTests/_Helpers.lua")
    return None


def lua_files(root, skip=()):
    out = []
    for dirpath, dirnames, files in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root).replace(os.sep, "/")
        if any(rel_dir == s or rel_dir.startswith(s + "/") for s in skip):
            continue
        for fn in files:
            if fn.endswith((".lua", ".luau")):
                out.append(os.path.join(dirpath, fn))
    return out


def chunked(seq, n=40):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def stylua_failures(paths):
    """Return the set of paths stylua --check complains about.

    stylua prints `Diff in <path>:` -- note the trailing colon, which is
    part of the message format and NOT part of the path.
    """
    bad = set()
    for chunk in chunked(paths):
        proc = subprocess.run(
            ["stylua", "--check", *chunk],
            capture_output=True, cwd=REPO,
        )
        text = (proc.stdout + proc.stderr).decode("utf-8", errors="replace")
        for line in text.splitlines():
            if line.startswith("Diff in "):
                p = line[len("Diff in "):].strip().rstrip(":")
                if p:
                    bad.add(os.path.abspath(p))
    return bad


def selene_findings(paths):
    """Return {path: [(code, message)]} for selene on the given paths.

    selene's default output puts the diagnostic on one line and the
    location on the next:

        error[undefined_variable]: `_thiefSpeed` is not defined
            ┌─ src/ServerScriptService/Steal/StealService.lua:444:2

    The location line may be indented, so it is matched anywhere in the
    line rather than only at the start.
    """
    out = {}
    for chunk in chunked(paths):
        proc = subprocess.run(
            ["selene", *chunk],
            capture_output=True, cwd=REPO,
        )
        text = (proc.stdout + proc.stderr).decode("utf-8", errors="replace")
        text = re.sub(r"\x1b\[[0-9;]*m", "", text)
        lines = text.splitlines()
        for i, line in enumerate(lines):
            m = re.match(r"^(error|warning|lint)\[([\w ]+)\]:\s*(.*)$", line)
            if not m:
                continue
            severity, code, msg = m.group(1), m.group(2), m.group(3)
            loc = None
            for nxt in lines[i + 1:i + 4]:
                # The location line looks like:
                #     ┌─ src/path/to/file.lua:444:2
                # The box-drawing prefix must be stripped from the path.
                lm = re.search(r"([^\s:][^:]*?):(\d+):(\d+)\s*$", nxt)
                if lm:
                    loc = (lm.group(1).strip(), int(lm.group(2)))
                    break
            if loc is None:
                continue
            p = os.path.abspath(loc[0])
            out.setdefault(p, []).append((severity, code, msg, loc[1]))
    return out


def main():
    # "Vendored" is excluded: it holds verbatim third-party code, which the
    # repo's .styluaignore and selene.toml also exclude. Reformatting or
    # "fixing" it would break the byte-identical guarantee.
    lib_files = lua_files(LIB, skip=("Examples", "Tools", "Tests/Tree", "Vendored"))
    src_files = lua_files(os.path.join(REPO, "src"))

    print("=" * 72)
    print("STYLUA")
    print("=" * 72)
    lib_bad = stylua_failures(lib_files)
    src_bad = stylua_failures(src_files)

    pre_existing = []
    introduced = []
    for p in sorted(lib_bad):
        rel = os.path.relpath(p, LIB).replace(os.sep, "/")
        origin = library_to_src(rel)
        if origin and os.path.abspath(origin) in src_bad:
            pre_existing.append((rel, os.path.relpath(origin, REPO).replace(os.sep, "/")))
        elif origin and os.path.exists(origin):
            introduced.append((rel, os.path.relpath(origin, REPO).replace(os.sep, "/"), "orig passes, copy fails"))
        else:
            introduced.append((rel, None, "library-authored (no src/ original)"))

    print("  src/ baseline failures      : %d" % len(src_bad))
    print("  library failures            : %d" % len(lib_bad))
    print("    pre-existing in src/       : %d" % len(pre_existing))
    print("    introduced by extraction   : %d" % len(introduced))
    if introduced:
        print()
        print("  INTRODUCED / LIBRARY-AUTHORED:")
        for rel, origin, why in introduced:
            print("    %-70s  %s" % (rel, why))
    print()
    print("  PRE-EXISTING (carried over unchanged):")
    for rel, origin in pre_existing:
        print("    %-70s  <- %s" % (rel, origin))

    print()
    print("=" * 72)
    print("SELENE")
    print("=" * 72)
    lib_sel = selene_findings(lib_files)
    src_sel = selene_findings(src_files)
    lib_pre = []
    lib_new = []
    for p, msgs in sorted(lib_sel.items()):
        rel = os.path.relpath(p, LIB).replace(os.sep, "/")
        origin = library_to_src(rel)
        origin = os.path.abspath(origin) if origin else None
        # Compare by (code, message) so the same finding in the original
        # counts as pre-existing even if the line number moved.
        orig_msgs = src_sel.get(origin, [])
        for sev, code, msg, line_no in msgs:
            match = next((o for o in orig_msgs if o[1] == code and o[2] == msg), None)
            if match is not None:
                lib_pre.append((rel, code, msg, match[3], line_no))
            else:
                lib_new.append((rel, code, msg, line_no, origin))
    total_lib = sum(len(v) for v in lib_sel.values())
    total_src = sum(len(v) for v in src_sel.values())
    print("  src/ findings               : %d" % total_src)
    print("  library findings            : %d" % total_lib)
    print("    pre-existing              : %d" % len(lib_pre))
    print("    LIBRARY-ONLY              : %d" % len(lib_new))
    if lib_new:
        print()
        print("  LIBRARY-ONLY FINDINGS (must be fixed or justified):")
        for rel, code, msg, line_no, origin in lib_new:
            print("    %s:%d  %s -- %s" % (rel, line_no, code, msg))
    if lib_pre:
        print()
        print("  PRE-EXISTING SELENE FINDINGS (carried over unchanged):")
        for rel, code, msg, orig_line, line_no in lib_pre:
            print("    %s:%d  %s -- %s" % (rel, line_no, code, msg))

    return 0


if __name__ == "__main__":
    sys.exit(main())
