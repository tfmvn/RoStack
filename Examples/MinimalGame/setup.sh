#!/usr/bin/env bash
# Assemble the MinimalGame's src/ tree from the library.
#
# This is a deterministic copy driven by an explicit file list, not an
# auto-discovering installer. Every path is checked; a missing source is a
# hard error, not a silent skip.
#
# Usage:  ./setup.sh            (from this directory)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../.."
SRC="$HERE/src"

echo "MinimalGame setup"
echo "  library: $LIB"
echo "  target:  $SRC"
echo

if [ ! -d "$LIB/Systems" ]; then
  echo "ERROR: cannot find the library at $LIB/Systems" >&2
  exit 1
fi

# copy <library-relative-path> <roblox-destination-within-src>
copy() {
  local from="$LIB/$1"
  local to="$SRC/$2"
  if [ ! -f "$from" ]; then
    echo "ERROR: missing library file: $from" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$to")"
  cp "$from" "$to"
  echo "  $2"
}

# Remove only the library-derived subtrees. The hand-written files in
# src/ (bootstrap.server.lua, the client HUD) are left alone.
rm -rf "$SRC/ReplicatedStorage" "$SRC/ServerScriptService/PlayerService.lua" \
       "$SRC/ServerScriptService/EconomyService.lua" \
       "$SRC/ServerScriptService/Base" \
       "$SRC/ServerScriptService/Carry" \
       "$SRC/ServerScriptService/MutationService.lua"
mkdir -p "$SRC"

echo "ReplicatedStorage:"
# --- config -------------------------------------------------------------
copy "Systems/Economy/Source/ReplicatedStorage/Config/Economy/Money.lua" \
      "ReplicatedStorage/Config/Economy/Money.lua"
copy "Systems/SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua" \
      "ReplicatedStorage/Config/Systems/Debug.lua"
copy "Systems/Upgrades/Source/ReplicatedStorage/Config/Creatures/Progression.lua" \
      "ReplicatedStorage/Config/Creatures/Progression.lua"
copy "Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Mutations.lua" \
      "ReplicatedStorage/Config/Creatures/Mutations.lua"
copy "Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Traits.lua" \
      "ReplicatedStorage/Config/Creatures/Traits.lua"
copy "Systems/Animals/Source/ReplicatedStorage/Config/Creatures/Animals.lua" \
      "ReplicatedStorage/Config/Creatures/Animals.lua"
copy "Systems/EggsAndHatching/Source/ReplicatedStorage/Config/Creatures/Eggs.lua" \
      "ReplicatedStorage/Config/Creatures/Eggs.lua"

# --- utility ------------------------------------------------------------
# NOTE: the library splits shared modules between Shared/Utilities/ and
# Shared/CommonModules/, but BOTH land in ReplicatedStorage/Utility/ in
# the source game (they are separated in the library only to keep the
# folder sizes sane). Map each file to the folder it actually lives in.
for f in BigNumber Validation Debug Remotes Signals StudioTestMode NumberUtils OwnedObjectIdentity; do
  case "$f" in
    Remotes|OwnedObjectIdentity)
      copy "Shared/CommonModules/$f.lua" "ReplicatedStorage/Utility/$f.lua" ;;
    *)
      copy "Shared/Utilities/$f.lua" "ReplicatedStorage/Utility/$f.lua" ;;
  esac
done

# --- types --------------------------------------------------------------
for f in SlotType TransactionReason RarityType AnimalType AnimalDefinitionType EggType BaseType PlayerDataType; do
  copy "Shared/Types/$f.lua" "ReplicatedStorage/Types/$f.lua"
done

echo "ServerScriptService:"
# --- services -----------------------------------------------------------
copy "Systems/PlayerData/Source/ServerScriptService/PlayerService.lua" \
      "ServerScriptService/PlayerService.lua"
copy "Systems/PlayerData/Source/ServerScriptService/Base/PersistenceAudit.lua" \
      "ServerScriptService/Base/PersistenceAudit.lua"
copy "Systems/Economy/Source/ServerScriptService/EconomyService.lua" \
      "ServerScriptService/EconomyService.lua"
copy "Systems/Carry/Source/ServerScriptService/Carry/CarryRegistry.lua" \
      "ServerScriptService/Carry/CarryRegistry.lua"
copy "Systems/MutationsAndTraits/Source/ServerScriptService/MutationService.lua" \
      "ServerScriptService/MutationService.lua"

echo
echo "Done. Now build and play:"
echo "  rojo build minimalgame.project.json -o build/minimalgame.rbxl"
echo
echo "You will also need ProfileService and Janitor installed"
echo "(wally install, or vendor ProfileService into src/Vendored/)."
echo "See README.md."
