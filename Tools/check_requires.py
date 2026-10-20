#!/usr/bin/env python3
"""Check every `require(...)` in the library resolves against the built tree.

Builds the instance tree from a Rojo XML build of
`ReusableSystems/test.project.json`, then walks every library source file
and resolves its requires two ways:

  * ABSOLUTE  -- `require(ServerScriptService.AnimalService)` resolves from
    the DataModel root.
  * RELATIVE  -- `require(script.Parent.Parent.ReplicatedStorage.Config.X)`
    resolves from the requiring module's own position in the tree.

Reports any require that points at something that does not exist.

Usage:
    rojo build ReusableSystems/test.project.json -o /tmp/lib-test.rbxlx
    python ReusableSystems/Tools/check_requires.py /tmp/lib-test.rbxlx

TWO MODES
---------

1. LIBRARY MODE (default). The build is the library's own test project
   (`ReusableSystems/test.project.json`). Every library file is mapped to
   the Roblox path it occupies in that build, and every `require` in it is
   resolved.

2. SELF-CONTAINED PROJECT MODE (`--project <dir>`). The build is a
   standalone mini-project -- e.g. `Examples/MinimalGame` -- whose sources
   live in `<dir>/src/`. The files are mapped to their Roblox paths
   relative to `<dir>/src/`, and only the files that are actually in the
   build are checked. Use this for the example, which is deliberately a
   SUBSET of the library and therefore does not contain every library
   module.

   rojo build ReusableSystems/Examples/MinimalGame/minimalgame.project.json        -o /tmp/minimal.rbxlx
   python ReusableSystems/Tools/check_requires.py /tmp/minimal.rbxlx        --project ReusableSystems/Examples/MinimalGame
"""

import re
import sys
import os
import xml.etree.ElementTree as ET

REQUIRE_RE = re.compile(r"\brequire\s*\(")


def extract_requires(line):
    """Yield the argument of every `require(...)` on the line.

    The argument is scanned with balanced parentheses so that
    `require(game:GetService('ReplicatedStorage').Utility.Debug)` is
    captured whole rather than truncated at the first `)`.
    """
    for m in REQUIRE_RE.finditer(line):
        i = m.end()
        depth = 1
        start = i
        while i < len(line) and depth > 0:
            ch = line[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if depth == 0:
            yield line[start:i].strip()


def load_tree(path):
    """Return {full_path: class} for every instance in the built place.

    Rojo's XML format nests <Item> elements inside their parent's <Item>,
    so the tree structure IS the XML structure. The DataModel root is
    <roblox> itself.
    """
    root = ET.parse(path).getroot()
    tree = {}

    def name_of(item):
        props = item.find("Properties")
        if props is None:
            return None
        for s in props.findall("string"):
            if s.get("name") == "Name":
                return s.text
        return None

    def walk(node, prefix):
        for item in node.findall("Item"):
            nm = name_of(item)
            if nm is None:
                continue
            full = prefix + "/" + nm
            tree[full] = item.get("class")
            walk(item, full)

    walk(root, "")
    # Strip the leading "/" so paths read like "ReplicatedStorage/Config/X.lua".
    return {k.lstrip("/"): v for k, v in tree.items()}


def build_parent_map(tree):
    parent = {}
    for fullpath in tree:
        parts = fullpath.split("/")
        for i in range(1, len(parts)):
            parent["/".join(parts[:i])] = "/".join(parts[: i - 1]) if i > 1 else ""
    return parent


def resolve(expr, module_path, tree, parent):
    """Resolve a require expression to a path in the built tree."""
    expr = expr.strip()
    if not expr:
        return None, "empty"

    # Normalise the string-index form: ServerScriptService['Egg'].HoverMath
    #  -> ServerScriptService.Egg.HoverMath
    expr = re.sub(r"\[\s*'([^']*)'\s*\]", r".\1", expr)
    expr = re.sub(r'\[\s*"([^"]*)"\s*\]', r".\1", expr)

    # game:GetService('ReplicatedStorage').Utility.Debug
    #   -> ReplicatedStorage.Utility.Debug
    g = re.match(r"^game\s*:\s*GetService\s*\(\s*['\"]([^'\"]+)['\"]\s*\)\s*\.\s*(.+)$", expr)
    if g:
        expr = g.group(1) + "." + g.group(2)
    # game.ReplicatedStorage.Utility.Debug -> ReplicatedStorage.Utility.Debug
    if expr.startswith("game."):
        expr = expr[len("game."):]

    # The codebase uses one local alias: `local sss = game:GetService('ServerScriptService')`.
    if expr.startswith("sss."):
        expr = "ServerScriptService." + expr[len("sss."):]

    m = re.match(r"^([A-Za-z_][\w]*)\s*\.\s*(.+)$", expr)
    if not m:
        return None, "unparsed"
    base = m.group(1)
    segs = [s.strip() for s in m.group(2).split(".") if s.strip()]

    if base == "script":
        # Relative to the requiring module.
        cur = module_path
        for seg in segs:
            if seg == "Parent":
                cur = cur.rsplit("/", 1)[0] if "/" in cur else ""
                continue
            if seg == "script":
                continue
            cur = (cur + "/" + seg) if cur else seg
        return (cur if cur in tree else None), None

    # Absolute from the DataModel root.
    cur = base
    for seg in segs:
        cur = cur + "/" + seg
    if cur in tree:
        return cur, None
    return None, "not-found"


def rojo_name(path):
    """Apply Rojo's filename-to-instance-name rule.

    Rojo strips the script extension, and strips a trailing `.client` /
    `.server` kind suffix, but keeps any other dotted suffix:

        `bootstrap.client.lua`    -> `bootstrap`
        `bootstrap.server.lua`    -> `bootstrap`
        `AdminFramework.spec.lua` -> `AdminFramework.spec`
        `CmdrBootstrap.luau`      -> `CmdrBootstrap`
    """
    stem, dot, ext = path.rpartition(".")
    if dot and ext in ("lua", "luau"):
        path = stem
    stem, dot, ext = path.rpartition(".")
    if dot and ext in ("client", "server"):
        path = stem
    return path


def map_library_files(lib):
    """Map each library source file to the Roblox path it occupies."""
    src_to_built = {}
    for root, _d, files in os.walk(lib):
        for fn in files:
            if not fn.endswith((".lua", ".luau")):
                continue
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, lib).replace(os.sep, "/")
            if rel.startswith(("Examples/", "Tools/")):
                continue
            # Systems/<Sys>/Source/<RobloxPath>
            m = re.match(r"^Systems/[^/]+/Source/(.*)$", rel)
            if m:
                roblox = m.group(1)
            elif rel.startswith("Shared/Types/"):
                roblox = "ReplicatedStorage/Types/" + rel[len("Shared/Types/"):]
            elif rel.startswith("Shared/Utilities/"):
                roblox = "ReplicatedStorage/Utility/" + rel[len("Shared/Utilities/"):]
            elif rel.startswith("Shared/CommonModules/"):
                fn2 = rel[len("Shared/CommonModules/"):]
                roblox = ("ReplicatedStorage/ShopAnimations.lua" if fn2 == "ShopAnimations.lua"
                          else "ReplicatedStorage/Utility/" + fn2)
            else:
                continue
            src_to_built[full] = rojo_name(roblox)
    return src_to_built


def map_project_files(project_dir):
    """Map a self-contained project's own sources to their Roblox paths.

    `<project_dir>/src/<RobloxPath>` is the layout, so the mapping is the
    path relative to `src/`. Only files that are actually IN the build are
    checked -- a self-contained project is deliberately a subset of the
    library, so a library module that is absent from it is not a broken
    require.
    """
    src = os.path.join(project_dir, "src")
    src_to_built = {}
    for root, _d, files in os.walk(src):
        for fn in files:
            if not fn.endswith((".lua", ".luau")):
                continue
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, src).replace(os.sep, "/")
            src_to_built[full] = rojo_name(rel)
    return src_to_built


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    project = None
    for a in sys.argv[1:]:
        if a.startswith("--project"):
            project = a.split("=", 1)[1] if "=" in a else args[0]
    if not args:
        print(__doc__)
        return 2
    build = args[0]
    tree = load_tree(build)
    parent = build_parent_map(tree)

    lib = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

    if project:
        src_to_built = map_project_files(os.path.abspath(project))
    else:
        src_to_built = map_library_files(lib)

    broken = []
    dynamic = []
    checked = 0
    not_in_tree = []
    for full, built in sorted(src_to_built.items()):
        if built not in tree:
            not_in_tree.append((os.path.relpath(full, lib), built))
            continue
        try:
            text = open(full, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("--"):
                continue
            for expr in extract_requires(line):
                checked += 1
                target, err = resolve(expr, built, tree, parent)
                if target is not None:
                    continue
                # A require of a runtime VARIABLE (`require(node)`,
                # `require(mod)`, `require(Packages:WaitForChild('X'))`)
                # cannot be checked statically. Report it separately
                # rather than calling it broken.
                # A require of a bare variable (`require(node)`,
                # `require(mod)`) is dynamic too.
                if not re.match(r"^[A-Za-z_][\w]*(\.[A-Za-z_][\w]*)+$", expr):
                    dynamic.append((os.path.relpath(full, lib), line_no, expr))
                    continue
                broken.append((os.path.relpath(full, lib), line_no, expr.strip(), err))

    print("require check")
    print("  library files mapped         : %d" % len(src_to_built))
    print("  files present in the build   : %d" % (len(src_to_built) - len(not_in_tree)))
    print("  require expressions checked : %d" % checked)
    print("  UNRESOLVED (broken)          : %d" % len(broken))
    print("  dynamic (unverifiable)       : %d" % len(dynamic))
    if not_in_tree:
        # A file that is not in the build was NOT checked. Say so loudly:
        # a silent skip would let a build with the wrong layout look green.
        print("  NOT PRESENT IN BUILD (unchecked): %d" % len(not_in_tree))
        for rel, built in not_in_tree[:20]:
            print("    %s -> %s" % (rel, built))
    for b in broken[:200]:
        print("    %s:%d  %s   (%s)" % b)
    for d in dynamic[:200]:
        print("    (dynamic) %s:%d  %s" % d)
    return 0 if not broken else 1


if __name__ == "__main__":
    sys.exit(main())
