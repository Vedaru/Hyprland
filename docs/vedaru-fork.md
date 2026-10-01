# Vedaru's Hyprland fork

A fork of [hyprwm/Hyprland](https://github.com/hyprwm/Hyprland), based on upstream
tag `v0.56.2` (`efb50993780079460b0cbed1363e2166a2de1d9f`, 2026-08-05). Everything
below is either upstream as-is or one of the commits this fork carries on top of
it. Primary branch: `vedaru/v0.56.2-ime-popup`.

This fork is the compositor for a self-built daily driver configured in **Lua**
(`~/.config/hypr/hyprland.lua`), which selects `Config::Lua::CConfigManager`
instead of the legacy config manager — several of the fixes here exist because
of that.

## Modifications

### Compositor behaviour

**`062c25e0` — view: pin a parentless modal xdg-dialog to a fixed size**

Once `8db15170` floated parentless modal xdg-dialogs, the borders of such a
window (Kdenlive's Quick Setup / splash) could be dragged, stretching a surface
the client lays out as a single, fixed size. A parentless modal has nothing to
be transient for and no meaningful resize behaviour, so it now reports its
current size as both min and max — the same state a client declares with
`min == max`, which is what GTK's `set_resizable(false)` produces for Faugus.
The drag-resize clamp, `getGeometryForWindow` and `clampSizeForDesired` all snap
to it. Keyed purely off the client's own protocol state (parentless +
`xdg_dialog_v1` modal), so there is no rule, no app name and no config option;
explicit `minSize`/`maxSize` rules still take precedence.

**`fc91f418` — ipc: keep classic `dispatch <name> <arg>` valid under the lua config manager**

The IPC handler wrapped *every* `dispatch <in>` request as `hl.dispatch(<in>)`
when the Lua config manager was active, so the documented classic form
`dispatch workspace 3` was parsed as Lua and failed:

```
error: [string "return hl.dispatch(workspace 3)"]:1: ')' expected near '3'
```

waybar's `hyprland/workspaces` module speaks exactly that form and has no
`on-click` hook for workspace buttons, so the workspace numbers in the bar were
inert on click. Any external client speaking a classic dispatch was affected the
same way.

The fix routes input through the existing dispatcher map
(`CKeybindManager::m_dispatchers`, populated unconditionally and already used by
the non-Lua IPC path) whenever the first word is a registered dispatcher name,
and keeps the `hl.dispatch(...)` shorthand for everything else. Non-dispatcher
names still get the original "syntax might need to be updated" hint, so the
change is purely additive. `dispatch workspace 3` now lands on
`CA::changeWorkspace` — the same function `hl.dsp.focus({ workspace = ... })`
reaches.

Tagged `v0.56.2-vedaru2`.

**`8db15170` — managers: float native Wayland modal toplevels**

`shouldBeFloated()` only honoured a transient parent or a fixed size for xdg
toplevels, so a parentless toplevel calling `xdg_dialog_v1.set_modal()` (e.g.
Kdenlive's splash) ended up tiled. X11 already covered this via `isModal()` and
`_NET_WM_WINDOW_TYPE_DIALOG`, so the behaviour was never at parity. The
xdg-dialog-v1 modal flag is now honoured, matching KWin.

**`2eb66329` — renderer: draw IME popups in the solitary fullscreen path**

IME candidate popups were not drawn when a single fullscreen window was the only
thing on the workspace.

### Packaging and CI

One commit, `13dbd2ec`, **removes all 13 upstream GitHub Actions workflows**
(712 lines under `.github/workflows/`) and replaces them with
`.forgejo/workflows/hyprbuntu-package.yml`. This fork's CI runs on a self-hosted
Forgejo instance, not GitHub Actions — **as a result, nothing under
`.github/workflows/` exists here and the GitHub mirror runs no CI.**

The remaining ten CI commits build out that job — a `hyprbuntu` bundle
rebuilt from this repo instead of re-tarring a machine, run in a glibc
container on a glibc-labelled runner:

| Commit | What it fixes |
| --- | --- |
| `b06bc278` | rebuild hyprbuntu from this repo instead of re-tarring a machine |
| `160b1d82` | upload the build log from its own always-run step |
| `7e74c5b2` | build in a glibc container, probe what the runner can do |
| `f14fb2c0` | install git and curl in the container before cloning |
| `3bc89cef` | stop uploading the build log to the package registry |
| `6bd42b4d` | run on a glibc-labelled runner instead of a per-job container |
| `b9f3c497` | install glslang-tools and libudis86-dev for the bundle build |
| `70a5bdfd` | mirror the machine's Hyprland apt deps, incl. libglaze-dev |
| `a58794d2` | install GCC 16 and the runtimes the bundle's libs link against |
| `80a1913a` | publish the bundle over loopback, retry the edge's 520-524 |

The CI job talks to a self-hosted Forgejo package registry and uses a
`FORGEJO_TOKEN` secret supplied by the runner environment; no credentials are
stored in the repository.

## Building

Built against GCC 16 and the Hypr* stack from `/usr/local`:

```sh
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig" \
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=gcc-16 -DCMAKE_CXX_COMPILER=g++-16 \
  -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="/usr/local;/usr" -DBUILD_TESTING=OFF

ninja -C build -j"$(nproc)"
```

## Tags

| Tag | Points at |
| --- | --- |
| `v0.56.2` | upstream release, unmodified |
| `v0.56.2-vedaru1` | first fork commit, the IME popup renderer fix (`2eb66329`) |
| `v0.56.2-vedaru2` | current tip, adds the IPC dispatch fix (`fc91f418`) |
