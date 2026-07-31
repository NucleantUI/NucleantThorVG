ok like macos/ios we need thorvg-cython to make the dependecies for linux support

also output should be called Dependencies 

and we should have platform folders inside 

/Dependencies/apple/*current_frameworks
/Dependencies/linux/*linux_deps

## Status: done for this package

* `output/` renamed to `Dependencies/`, with the existing macOS/iOS
  xcframeworks moved to `Dependencies/apple/` (`ThorVG.xcframework`,
  `libomp.xcframework` — also fixed a pre-existing case mismatch,
  `thorvg.xcframework` → `ThorVG.xcframework`, that only worked on macOS's
  case-insensitive filesystem).
* `Dependencies/linux/` holds a vendored, committed `libthorvg-1.so`
  (`lib/`), the same way `Dependencies/apple/` vendors the macOS/iOS
  xcframeworks — built via thorvg-cython with the `wg` (WebGPU) engine,
  since no distro packages thorvg with that engine enabled. See
  `Dependencies/linux/README.md`.
* `scripts/build_thorvg.py` (wrapper) gained a `linux` code path: checks
  wgpu-native is pkg-config-discoverable first (needed at *build* time —
  meson resolves thorvg's `wg` engine dependency on wgpu-native that way;
  see `NucleantVulkan/Dependencies/linux/README.md` for how wgpu-native
  itself is vendored there), forwards `--gpu=vulkan` to thorvg-cython
  (thorvg-cython drops its build output in its own
  `thorvg/output/linux_<arch>/`, same as it already does for macOS/iOS),
  then a new `_repackage_linux()` copies that `.so` into
  `Dependencies/linux/lib/` — mirroring `_repackage_macos_xcframework()`'s
  job exactly.
* `thorvg-cython/tools/build_thorvg.py` gained the minimum needed to make
  `--gpu=vulkan` (the `wg` engine) work on Linux at all: `dependency
  ('wgpu_native')` in thorvg's meson.build needs a `wgpu_native.pc`
  (underscore) on `PKG_CONFIG_PATH`, but wgpu-native installs as
  `wgpu-native.pc` (hyphen, `NucleantVulkan/scripts/build_wgpu.py`'s own
  naming choice) — so `_linux_wgpu_pkgconfig_dir()` aliases one to the
  other, plus stages a `webgpu/` header subdir (the `wg` engine does
  `#include <webgpu/webgpu.h>`, but wgpu-native installs headers flat).
  Nothing else in thorvg-cython changed.
* `Package.swift` now branches on `#if os(Linux)`: `CThorVG` becomes a
  plain `.target` (reusing the same `Sources/CThorVG` directory and vendored
  `thorvg_capi.h` the Apple build already uses — one header serves both,
  the CAPI's C ABI is stable across platforms) that links
  `Dependencies/linux/lib` directly via `linkerSettings.unsafeFlags`
  (`-L`/`-l` plus an `-rpath` back to that same directory) instead of the
  `ThorVG`/`libomp` binary targets used on Apple. No `.systemLibrary`, no
  pkg-config, no `PKG_CONFIG_PATH` needed to build or run this target —
  deliberately not the pkg-config/`.systemLibrary` route (ruled out: can't
  pin what version gets resolved, and it was silently linking whatever
  happened to be on the machine rather than what was actually built here).
  `unsafeFlags` only works because this stays the *root* package build; see
  `Dependencies/linux/README.md`.

**Verified end to end**: built thorvg 1.0.5 for `linux_x86_64` with
`engines=cpu,wg`, vendored it into `Dependencies/linux/lib/`, and — in a
genuinely clean shell (`env -i`, nothing carried over from prior
commands) — ran `swift build`/`swift test` for the whole package (not a
standalone probe): builds and passes with **zero env vars required** for
`CThorVG` specifically (`libthorvg-1.so` resolves via the baked rpath).
`NucleantVulkan`'s own `CWgpu` needed the same vendoring treatment to reach
a fully env-var-free build; see its `linux-wayland-support.md`.

The `SulphurGeometry`/`NucleantVulkan`/`NucleantThorVG` `import simd`
blocker `NucleantVulkan/linux-wayland-support.md` had flagged is also fixed
now: those files only used `SIMD2`/`SIMD4`/`SIMDScalar`, which are
Swift-stdlib builtins as of recent toolchains — `import simd` (Apple's
Accelerate-backed module) was dead weight, not an actual dependency. Commented
out (not deleted) in `SulphurGeometry`'s `Point.swift`/`Size.swift`/
`Rect.swift`/`EdgeInsets.swift` and this package's `ThorPaint.swift`/
`ThorText.swift`/`ThorScene.swift`/`ThorPicture.swift`/`ThorShape.swift`.

**Not attempted** (out of scope — this plan was about the C dependency and
the build graph, not a full API audit): no line-by-line audit of
`NucleantThorVG`'s other Apple-flavored APIs (CoreGraphics/QuartzCore, if
any remain) beyond what `swift test` already exercises — the compiler
would catch those the same way it caught `import simd`.
