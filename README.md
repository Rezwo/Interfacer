# Interfacer

A scope-based, typed reactive UI framework for Roblox, derived from [Flux](https://github.com/kohltastrophe/flux).

One import, modular Luau sources and a PascalCase API. This is the practical package, not the development archive.

## Install

Download **Interfacer.rbxm** from [Releases](https://github.com/Rezwo/Interfacer/releases), then drag the model into `ReplicatedStorage`. Require the resulting `Interfacer` ModuleScript from a LocalScript.

For Rojo projects, map this repository's `src` directory to a ModuleScript named `Interfacer`. Build the standalone model with:

```sh
rojo build default.project.json -o dist/Interfacer.rbxm
```

## A small counter

```lua
local Players = game:GetService("Players")
local Interfacer = require(game:GetService("ReplicatedStorage"):WaitForChild("Interfacer"))

local Owner = Interfacer.Scope(function()
    local Count = Interfacer.State(0)
    Interfacer.Cleanup(Count)

    local Screen = Interfacer.New("ScreenGui")({
        Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
        ResetOnSpawn = false,
    })

    local Button = Interfacer.New("TextButton")({
        Parent = Screen,
        Size = UDim2.fromOffset(220, 56),
        Text = Interfacer.Computed(function()
            return "Count: " .. tostring(Count())
        end),
    })

    Interfacer.Cleanup(Button.Activated:Connect(function()
        Count:Set(Count:Peek() + 1)
    end))
end)
```

Call `Interfacer.Dispose(Owner)` when that component unmounts. Constructors return real Instances. Normal frame settlement is automatic; call `Interfacer.Flush()` when an immediate update is required.

## Included

- Callable `State` and `Computed` values, `Effect`, scopes, ownership, cleanup and context.
- `New` / `Edit` construction, reactive property bindings, native events, attributes, tags and styles.
- Mapping and conditional helpers: `ForValue`, `ForIndex`, `Show`, `ShowKeyed` and `Switch`.
- Springs, tweens, clock, layout, responsive preferences, stores and asynchronous utilities.
- Portals, modal stacks, dialogs, focus handling and exit transitions.
- `VirtualCollection`: stable-ID row scopes for uniform-height vertical lists and responsive grids.
- `ReusableVirtualCollection`: explicit cell creation, Reset/Attach assignment guards and bounded warmed capacity, with editor retention.

Sources are organized by feature in `src/`. State handles expose `Get`, `Peek`, `Set`, `Update` and `Destroy`; callable reads remain supported.

## Contract and status

**Initial public preview.** APIs may change. This retains the Flux-derived execution/error contract, not a transactional evaluation/publication barrier. It does not add a general per-writer protected-call guarantee.

Collection root geometry and parenting belong to the collection. The reusable presenter has a private sibling presentation hierarchy: do not depend on rows being descendants of the native ScrollingFrame. Variable-height items and masonry are not included.

This release makes no competitive performance claim and no universal frame-perfect scrolling guarantee. See [verification](verification/ACCEPTANCE.md) for exactly what was checked and what was not.

The code uses current Luau syntax, including `const`, read-only type fields and type functions. Use a compatible recent Studio/toolchain. Static analysis requires the SolverV2 mode used for the recorded checks; older/default solver diagnostics are not a clean-audit claim.

## Verify

```sh
python verify_distribution.py --luau PATH_TO_COMPATIBLE_LUAU
```

The portable suite checks source identities, headless behavior and exact operation counts. Roblox-specific tests are separate and are skipped by the CLI, not counted as passes. The native test project is `test/default.project.json`.

## Attribution

Interfacer contains restyled and extended Flux code. Flux is copyright 2025 Kohl and licensed under MIT; its original notice is preserved in [LICENSE.md](LICENSE.md) and [LICENSE.Flux.md](LICENSE.Flux.md), and embedded in the standalone model. See [NOTICE.md](NOTICE.md).
