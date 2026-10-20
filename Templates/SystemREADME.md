# System README Template

Copy this into `Systems/<SystemName>/README.md` and fill it in. Delete the
instructional comments as you go.

---

# <SystemName>

One-sentence purpose.

**Portability:** Portable core / Game-specific adapter / Platform-bound —
say which, and why.

**Source game:** Brainrot Arena (`p-7`).

## What It Does

2–5 sentences. Describe the actual behaviour, not the intent.

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `ServerScriptService.<Path>.Init()` | Server | |
| `ServerScriptService.<Path>.Start()` | Server | |
| `ServerScriptService.<Path>.Set<X>` | Server | Late-bound injection. |

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/...` | `ServerScriptService/...` | |

## Configuration

Point at `Config.lua` and list the tunables that matter most.
Say which ones are safe to change and which are pinned.

## Dependencies

- **Requires:** other systems / shared modules.
- **Remotes:** names, direction, payload shape.
- **Profile fields:** the profile keys this system reads and writes.
- **Assets:** Studio assets this system requires.

## Initialization Order

Where this system sits in the bootstrap sequence, and why.

## Data

What it persists, if anything.

## Known Limitations

Be honest. List the coupling, the untested paths, and the
assumptions this system makes about the rest of the game.

## Testing

Which tests cover it, and what they need to run.

## Adapting to a New Game

The short list of things that MUST change.
