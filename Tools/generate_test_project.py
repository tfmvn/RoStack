#!/usr/bin/env python3
"""Generate ReusableSystems/test.project.json.

The library's sources are spread across 28 system folders
(`Systems/<Sys>/Source/<RobloxPath>`), and the specs are spread across
per-system `Tests/` folders. Neither layout can be handed to Rojo
directly:

  * Rojo cannot merge two filesystem folders into one instance, and one
    Roblox path here is contributed by up to six systems.
  * The specs were written against the source game's FLAT test layout and
    reach their helper with `require(script.Parent._Helpers)`, so every
    spec must sit next to `_Helpers.lua`.

`Tools/generate_test_tree.py` solves both by materialising a merged tree
of HARD LINKS at `ReusableSystems/Tests/Tree/`. This script then writes
the project file that mounts it.

The project file is small and stable; regenerate it if you add a system
whose source lives under a new Roblox root.

Usage:
    python ReusableSystems/Tools/generate_test_tree.py
    python ReusableSystems/Tools/generate_test_project.py
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.abspath(os.path.join(HERE, ".."))
TREE = "Tests/Tree"


def main():
    project = {
        "name": "reusable-systems-tests",
        "tree": {
            "$className": "DataModel",
            "ReplicatedStorage": {
                "$className": "ReplicatedStorage",
                "Packages": {"$className": "Folder", "$path": "../Packages"},
                "Config": {"$className": "Folder", "$path": TREE + "/ReplicatedStorage/Config"},
                "Types": {"$className": "Folder", "$path": TREE + "/ReplicatedStorage/Types"},
                "Utility": {"$className": "Folder", "$path": TREE + "/ReplicatedStorage/Utility"},
                "ShopAnimations": {"$path": TREE + "/ReplicatedStorage/ShopAnimations.lua"},
            },
            "ServerScriptService": {
                "$className": "ServerScriptService",
                "$path": TREE + "/ServerScriptService",
                "Packages": {
                    "$className": "Folder",
                    "Janitor": {"$path": "../ServerPackages/Janitor.lua"},
                    "_Index": {"$className": "Folder", "$path": "../ServerPackages/_Index"},
                    "ProfileService": {"$path": "Vendored/ProfileService.lua"},
                    "DevPackages": {
                        "$className": "Folder",
                        "TestEZ": {"$path": "../DevPackages/TestEZ.lua"},
                        "_Index": {"$className": "Folder", "$path": "../DevPackages/_Index"},
                    },
                },
                "TestEZTests": {
                    "$className": "Folder",
                    "$path": TREE + "/ServerScriptService/TestEZTests",
                },
            },
            "StarterPlayer": {
                "$className": "StarterPlayer",
                "StarterPlayerScripts": {
                    "$className": "Folder",
                    "$path": TREE + "/StarterPlayer/StarterPlayerScripts",
                },
            },
        },
    }

    out = os.path.join(LIB, "test.project.json")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(project, f, indent=2)
        f.write("\n")
    print("wrote %s" % out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
