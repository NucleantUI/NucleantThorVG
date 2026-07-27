# Linux dependencies

`libthorvg-1.so` is vendored here (`lib/`), committed into the repo, the
same way `Dependencies/apple/` vendors the macOS/iOS xcframeworks — built
via [thorvg-cython](https://github.com/kivy/thorvg-cython) with the `wg`
(WebGPU) engine enabled, since no distro packages thorvg with that engine.

`CThorVG`'s Linux target links this directly (`-L`/`-l` plus an `-rpath`
back to this directory) instead of going through pkg-config — deliberately
not `.systemLibrary`, so nothing depends on what pkg-config happens to
resolve on the machine building this. That only works because this stays
the *root* package build (SwiftPM rejects `unsafeFlags` — what the direct
link needs — in any target belonging to a package used as someone else's
dependency).

wgpu-native itself (thorvg's `wg` engine *build-time* dependency) is not
vendored here — see `NucleantVulkan/Dependencies/linux/README.md`, it's
vendored there instead and only needs to be discoverable via pkg-config
while *building* thorvg (meson resolves it that way); nothing about running
the resulting `libthorvg-1.so` depends on pkg-config.

## 1. wgpu-native first

```
python3 ../NucleantVulkan/scripts/build_wgpu.py --prefix ../NucleantVulkan/Dependencies/linux
export PKG_CONFIG_PATH="$(pwd)/../NucleantVulkan/Dependencies/linux/lib/pkgconfig:$PKG_CONFIG_PATH"
```

See `NucleantVulkan/Dependencies/linux/README.md` for the full prerequisites
(Rust via rustup, `libclang-dev`). `PKG_CONFIG_PATH` is only needed for this
build step (thorvg-cython's meson build resolving `dependency('wgpu_native')`)
— not for building this package afterwards.

## 2. Build + vendor thorvg

```
pip install --user meson ninja   # or: sudo apt install meson ninja-build
python3 scripts/build_thorvg.py linux
```

This clones `thorvg-cython` next to this repo (if missing), builds thorvg
with the `wg` engine (`--gpu=vulkan`, thorvg's own flag name for "enable the
WebGPU engine") and the CAPI bindings, then copies the result here:

* `Dependencies/linux/lib/libthorvg-1.so*`

No headers are vendored here — `Sources/CThorVG/include/thorvg_capi.h` (the
same hand-vendored CAPI header the macOS/iOS builds already use — the
CAPI's C ABI is stable across platforms, so one header serves all of them)
is what `CThorVG` publishes on Linux too.

## Building the package

```
swift build
```

No `PKG_CONFIG_PATH`, no `LD_LIBRARY_PATH` — `Package.swift` detects Linux
automatically (`#if os(Linux)`) and links `CThorVG` straight against
`Dependencies/linux/lib/libthorvg-1.so`, with an `-rpath` baked in so the
built binary finds it at runtime with no extra setup.
