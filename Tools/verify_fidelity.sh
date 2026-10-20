#!/usr/bin/env bash
# Verify every library source file is byte-identical to its original in src/,
# except for the deliberately adapted files.
#
# The library keeps each file at its EXACT original Roblox path inside
# Source/, so the mapping is mechanical:
#
#   Systems/<Sys>/Source/<RobloxPath>      ->  src/<RobloxPath>
#   Shared/Types/<F>.lua                   ->  src/ReplicatedStorage/Types/<F>.lua
#   Shared/Utilities/<F>.lua               ->  src/ReplicatedStorage/Utility/<F>.lua
#   Shared/CommonModules/<F>.lua           ->  src/ReplicatedStorage/Utility/<F>.lua
#   Shared/CommonModules/ShopAnimations.lua->  src/ReplicatedStorage/ShopAnimations.lua
#   Systems/<Sys>/Tests/<F>.spec.lua       ->  src/Tests/ServerScriptService/TestEZTests/<F>.spec.lua
#   Tests/IntegrationTests/<F>.spec.lua    ->  src/Tests/ServerScriptService/TestEZTests/<F>.spec.lua
#   Tests/_Helpers.lua                     ->  src/Tests/ServerScriptService/TestEZTests/_Helpers.lua
#
# Every spec file in the library is byte-verified against src/ too -- the
# specs are copies, not rewrites, and a spec that drifted from the code it
# tests would be a silent lie.
#
# Usage:  bash Tools/verify_fidelity.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
LIB="$ROOT"
SRC="$REPO/src"

# The two files intentionally changed during extraction (secrets scrubbed).
# See SECURITY_NOTES.md.
ADAPTED="ReusableSystems/Systems/PlayerLogging/Source/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua
ReusableSystems/Systems/AdminTools/Source/ServerScriptService/Admin/AdminConfig.lua"

# Files AUTHORED for the library (no src/ original exists). Each is a new
# file the task asked for.
is_authored() {
  case "$1" in
    Systems/*/Config.lua) return 0 ;;         # per-system config summary
    Templates/SystemConfigTemplate.lua) return 0 ;;
    Tests/TestRunner.server.lua) return 0 ;;  # the FIXED runner
    *) return 1 ;;
  esac
}

# Third-party code copied verbatim into the library. It is not this game's
# source, so it is not part of the extraction accounting, but it MUST still
# be byte-identical to what it was copied from. See EXTRACTION_MANIFEST.md
# section 1.1.
is_vendored() {
  case "$1" in
    Vendored/ProfileService.lua) return 0 ;;
    *) return 1 ;;
  esac
}

total=0; same=0; adapted=0; missing=0; differs=0; authored=0; unmapped=0; vendored=0; vendored_same=0
declare -a REPORT_MISSING=() REPORT_DIFFER=()

while IFS= read -r f; do
  rel="${f#$LIB/}"
  case "$rel" in
    Examples/*|Tools/*|Tests/Tree/*) continue ;;
  esac
  if is_authored "$rel"; then authored=$((authored+1)); continue; fi
  if is_vendored "$rel"; then
    vendored=$((vendored+1))
    total=$((total+1))
    if cmp -s "$f" "$REPO/src/Vendored/ProfileService.lua"; then
      vendored_same=$((vendored_same+1))
    else
      differs=$((differs+1)); REPORT_DIFFER+=("$rel -> src/Vendored/ProfileService.lua (vendored copy differs)")
    fi
    continue
  fi

  # Reconstruct the original source path.
  case "$rel" in
    Systems/*/Source/*)  orig="src/${rel#Systems/*/Source/}" ;;
    Shared/Types/*)      orig="src/ReplicatedStorage/Types/${rel#Shared/Types/}" ;;
    Shared/Utilities/*)  orig="src/ReplicatedStorage/Utility/${rel#Shared/Utilities/}" ;;
    Shared/CommonModules/ShopAnimations.lua) orig="src/ReplicatedStorage/ShopAnimations.lua" ;;
    Shared/CommonModules/*) orig="src/ReplicatedStorage/Utility/${rel#Shared/CommonModules/}" ;;
    Systems/*/Tests/*.spec.lua) orig="src/Tests/ServerScriptService/TestEZTests/${rel##*/}" ;;
    Tests/IntegrationTests/*.spec.lua) orig="src/Tests/ServerScriptService/TestEZTests/${rel##*/}" ;;
    Tests/_Helpers.lua)  orig="src/Tests/ServerScriptService/TestEZTests/_Helpers.lua" ;;
    *) echo "UNMAPPED: $rel"; unmapped=$((unmapped+1)); continue ;;
  esac

  total=$((total+1))
  if [ ! -f "$REPO/$orig" ]; then
    missing=$((missing+1)); REPORT_MISSING+=("$rel -> $orig (no such file)")
    continue
  fi
  if cmp -s "$f" "$REPO/$orig"; then
    same=$((same+1))
  else
    case "$ADAPTED" in
      *"$rel"*) adapted=$((adapted+1)) ;;
      *) differs=$((differs+1)); REPORT_DIFFER+=("$rel -> $orig") ;;
    esac
  fi
done < <(find "$LIB" \( -name "*.lua" -o -name "*.luau" \) -type f | sort)

echo "Fidelity check"
echo "  total source files checked : $total"
echo "  byte-identical to src/     : $same"
echo "  intentionally adapted      : $adapted"
echo "  UNEXPECTEDLY DIFFERENT     : $differs"
echo "  no matching file in src/   : $missing"
echo "  authored for the library   : $authored"
echo "  vendored third-party       : $vendored (byte-identical: $vendored_same)"
echo "  unmapped                   : $unmapped"
echo
if [ ${#REPORT_DIFFER[@]} -gt 0 ]; then
  echo "Unexpected differences:"; printf '  %s\n' "${REPORT_DIFFER[@]}"
fi
if [ ${#REPORT_MISSING[@]} -gt 0 ]; then
  echo "Missing originals:"; printf '  %s\n' "${REPORT_MISSING[@]}"
fi
[ "$differs" -eq 0 ] && [ "$missing" -eq 0 ] && [ "$unmapped" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
