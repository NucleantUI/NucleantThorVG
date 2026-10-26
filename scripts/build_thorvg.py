#!/usr/bin/env python3
"""
SulphurCore build wrapper for thorvg.

Clones thorvg-cython next to SulphurCore if not already present,
then delegates to its build_thorvg.py script.

wgpu-native (the `wg` engine links it) comes from the sibling NucleantVulkan
checkout on every platform: Dependencies/macos/wgpu_native.xcframework
(macOS, iOS), Dependencies/linux, Dependencies/android/<abi> and
Dependencies/windows — in CI, NucleantVulkan's release archives unpacked there.

macOS one architecture at a time (what CI does, a step each):

    python scripts/build_thorvg.py macos --gpu=vulkan --target-arch arm64
    python scripts/build_thorvg.py macos --gpu=vulkan --target-arch x86_64
    python scripts/build_thorvg.py macos --repackage-only

After a macOS/iOS/linux/windows build this script also repackages the built
binary into Dependencies/apple/, Dependencies/linux/ or Dependencies/windows/
so downstream builds pick up the new symbols.

Windows builds natively with MSVC (meson --vsenv), x64:

    python scripts/build_thorvg.py windows

Usage
-----
    python scripts/build_thorvg.py <platform> [options]

Platforms
    linux / macos / ios / android / windows

GPU
    --gpu=vulkan    Vulkan backend (linux, macos, ios, android, windows)
    --gpu=gl        OpenGL         (linux, windows, android)
    --gpu=gles      OpenGL ES      (android)
    --gpu=angle     ANGLE          (macos, ios, windows, android)

ThorVG source
    --thorvg-version=<x.y.z>   Auto-download this release if source is missing

All remaining args are forwarded verbatim to build_thorvg.py.
"""
from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR   = Path(__file__).resolve().parent
SULPHUR_ROOT = SCRIPT_DIR.parent
DEV_ROOT     = SULPHUR_ROOT.parent

THORVG_CYTHON_DIR    = DEV_ROOT / "thorvg-cython"
THORVG_CYTHON_REPO   = "https://github.com/Py-Swift/thorvg-cython.git"
# The commit every platform is built with: its build script, cross files and
# patches are part of what ends up in the binaries.
THORVG_CYTHON_REF    = "2ccda447dc5e4de0eaba8c7c73dd97f35b9e5951"
# The ThorVG release thorvg-cython downloads when it has no source yet — the
# same one scripts/build_thorvg_wasm.py builds.
THORVG_VERSION       = "1.0.5"
THORVG_BUILD_SCRIPT  = THORVG_CYTHON_DIR / "tools" / "build_thorvg.py"

# wgpu-native XCFramework (built by NucleantVulkan/scripts/build_wgpu.py) — the
# ThorVG `wg` engine links against it. For iOS we stage its slices into the
# per-arch layout build_thorvg.py's pkg-config wiring expects.
WGPU_XCFRAMEWORK = DEV_ROOT / "NucleantVulkan" / "Dependencies" / "macos" / "wgpu_native.xcframework"

# iOS thorvg.xcframework build_thorvg.py emits, and where we fold it in.
THORVG_IOS_XCFW  = THORVG_CYTHON_DIR / "thorvg" / "output" / "thorvg.xcframework"
NUCLEANT_XCFW    = SULPHUR_ROOT / "Dependencies" / "apple" / "ThorVG.xcframework"
# iOS libomp.xcframework (dynamic OpenMP the iOS thorvg framework links) — copied
# alongside so NucleantThorVG's Package.swift can embed libomp.framework on iOS.
LIBOMP_IOS_XCFW  = THORVG_CYTHON_DIR / "thorvg" / "output" / "libomp.xcframework"
NUCLEANT_LIBOMP  = SULPHUR_ROOT / "Dependencies" / "apple" / "libomp.xcframework"

# Where build_thorvg.py drops the macOS fat dylib
THORVG_ROOT     = THORVG_CYTHON_DIR / "thorvg"
FAT_DYLIB_SRC   = THORVG_ROOT / "output" / "macos_fat" / "libthorvg-1.dylib"

# Where NucleantThorVG/Package.swift expects the binary.
# macOS frameworks must use the versioned layout (not shallow bundles):
#   ThorVG.framework/Versions/A/ThorVG   ← actual binary
#   ThorVG.framework/ThorVG              → Versions/Current/ThorVG (symlink)
XCFW_FW_DIR     = NUCLEANT_XCFW / "macos-arm64_x86_64" / "ThorVG.framework"
XCFW_BINARY     = XCFW_FW_DIR / "Versions" / "A" / "ThorVG"
LOOSE_DYLIB_DST = SULPHUR_ROOT / "Dependencies" / "apple" / "macos" / "libthorvg-1.dylib"

# Where build_thorvg.py drops the Linux .so (own build output, same as
# THORVG_ROOT/output/macos_fat/ for macOS above).
THORVG_LINUX_SO_DIR = THORVG_ROOT / "output" / f"linux_{platform.machine()}"
# Where NucleantThorVG vendors it — mirrors Dependencies/apple/.
NUCLEANT_LINUX_DIR  = SULPHUR_ROOT / "Dependencies" / "linux"
# wgpu-native for Linux, vendored by NucleantVulkan/scripts/build_wgpu.py
# --prefix: lib/libwgpu_native.so and include/{webgpu.h,wgpu.h}.
WGPU_LINUX_DIR      = DEV_ROOT / "NucleantVulkan" / "Dependencies" / "linux"

# Android: build_thorvg.py emits one directory per architecture, named after
# the Meson cross file rather than the ABI. Package.swift and Gradle both work
# in ABI names, so this table is the join — same role the ABI mapping plays in
# NucleantVulkan/scripts/build_wgpu.py.
ANDROID_OUTPUT_ABIS = {
    "android_aarch64": "arm64-v8a",
    "android_x86_64":  "x86_64",
}
NUCLEANT_ANDROID_DIR = SULPHUR_ROOT / "Dependencies" / "android"

# thorvg-cython's build_android() builds aarch64 then x86_64 inside a single
# process, and pkg-config is configured once per process — so the staged .pc
# can only describe one ABI per run. aarch64 is built first, so that is the one
# a run reliably yields.
ANDROID_PRIMARY_ABI = "arm64-v8a"
ANDROID_PRIMARY_ARCH = "android_aarch64"

# wgpu-native for Android, vendored per ABI by
# NucleantVulkan/scripts/build_wgpu.py --android. ThorVG's `wg` engine links
# the same .so this engine does, so both land on one loaded instance.
WGPU_ANDROID_DIR = DEV_ROOT / "NucleantVulkan" / "Dependencies" / "android"

# Windows: build_thorvg.py emits thorvg-1.dll and its import library here;
# NucleantThorVG vendors them as Dependencies/windows/{bin,lib}, the layout
# NucleantVulkan's Dependencies/windows has (wgpu_native.dll, .lib, include/).
THORVG_WINDOWS_OUT_DIR = THORVG_ROOT / "output" / "windows_x64"
NUCLEANT_WINDOWS_DIR   = SULPHUR_ROOT / "Dependencies" / "windows"
WGPU_WINDOWS_DIR       = DEV_ROOT / "NucleantVulkan" / "Dependencies" / "windows"

XCFW_INSTALL_NAME = "@rpath/ThorVG.framework/ThorVG"

# The bare-dylib form of the same binary, for PIP_MODE. A wheel vendors plain
# files into nucleant/.dylibs; a framework bundle is what Xcode embed mode
# wants. NucleantVulkan already splits wgpu the same way (wgpu_native.xcframework
# vs wgpu_native_framework.xcframework) — this is that split for ThorVG.
NUCLEANT_LIB_XCFW = SULPHUR_ROOT / "Dependencies" / "apple" / "ThorVG_lib.xcframework"
LIB_XCFW_DYLIB    = "libthorvg-1.dylib"
LIB_INSTALL_NAME  = f"@rpath/{LIB_XCFW_DYLIB}"


def _ensure_thorvg_cython() -> None:
    if THORVG_CYTHON_DIR.is_dir():
        print(f"[sulphur] thorvg-cython found at {THORVG_CYTHON_DIR}")
        return
    print(f"[sulphur] Cloning thorvg-cython into {THORVG_CYTHON_DIR} ...")
    subprocess.run(["git", "clone", THORVG_CYTHON_REPO, str(THORVG_CYTHON_DIR)], check=True)
    subprocess.run(["git", "checkout", "--quiet", THORVG_CYTHON_REF],
                   cwd=str(THORVG_CYTHON_DIR), check=True)


MACOS_FRAMEWORK_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ThorVG</string>
    <key>CFBundleIdentifier</key>
    <string>org.thorvg.ThorVG</string>
    <key>CFBundleName</key>
    <string>ThorVG</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>MinimumOSVersion</key>
    <string>11.0</string>
</dict>
</plist>
"""


def _repackage_macos_xcframework() -> None:
    """Build ThorVG.xcframework's macOS slice from the freshly-built fat
    dylib — from scratch, nothing of a previous one kept, so it needs no
    committed Dependencies/ (the iOS build adds its slices after).

    macOS requires a versioned framework layout (not a shallow bundle):
        ThorVG.framework/
          Versions/A/ThorVG          ← real binary
          Versions/A/Headers/thorvg.h
          Versions/A/Resources/Info.plist
          Versions/Current           → A
          ThorVG                     → Versions/Current/ThorVG
          Headers                    → Versions/Current/Headers
          Resources                  → Versions/Current/Resources
    """
    if not FAT_DYLIB_SRC.exists():
        print(f"[sulphur] WARNING: fat dylib not found at {FAT_DYLIB_SRC} — skipping xcframework repackage")
        return

    print(f"\n[sulphur] Repackaging ThorVG.xcframework ...")

    stage = SCRIPT_DIR / ".work" / "macos_framework"
    if stage.exists():
        shutil.rmtree(stage)
    framework = stage / "ThorVG.framework"
    version_a = framework / "Versions" / "A"
    (version_a / "Headers").mkdir(parents=True)
    (version_a / "Resources").mkdir()
    binary = version_a / "ThorVG"
    shutil.copy2(str(FAT_DYLIB_SRC), str(binary))
    subprocess.run(["install_name_tool", "-id", XCFW_INSTALL_NAME, str(binary)], check=True)
    shutil.copy2(str(THORVG_ROOT / "inc" / "thorvg.h"), str(version_a / "Headers" / "thorvg.h"))
    (version_a / "Resources" / "Info.plist").write_text(MACOS_FRAMEWORK_PLIST)
    (framework / "Versions" / "Current").symlink_to("A")
    for name in ("ThorVG", "Headers", "Resources"):
        (framework / name).symlink_to(f"Versions/Current/{name}")

    # install_name_tool invalidated the signature, and an arm64 slice will not
    # load unsigned: sign the bundle (ad hoc).
    subprocess.run(["codesign", "--force", "--sign", "-", str(framework)], check=True)

    if NUCLEANT_XCFW.exists():
        shutil.rmtree(NUCLEANT_XCFW)
    NUCLEANT_XCFW.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcodebuild", "-create-xcframework", "-framework", str(framework),
                    "-output", str(NUCLEANT_XCFW)], check=True)
    print(f"[sulphur]   xcframework: {NUCLEANT_XCFW}")

    # Also refresh the loose dylib (used by Python bindings etc.)
    LOOSE_DYLIB_DST.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(FAT_DYLIB_SRC), str(LOOSE_DYLIB_DST))
    print(f"[sulphur]   loose dylib:        {LOOSE_DYLIB_DST}")

    print("[sulphur] Repackage done.\n")


def _repackage_macos_lib_xcframework() -> None:
    """Wrap the macOS binary as ThorVG_lib.xcframework — a bare dylib, no bundle.

    The Mach-O is the one _repackage_macos_xcframework() just installed, so the
    two forms never drift; only LC_ID_DYLIB differs. `install_name_tool`
    invalidates the code signature and an arm64 slice will not load unsigned,
    hence the ad-hoc re-sign.
    """
    if not XCFW_BINARY.is_file():
        print(f"[sulphur] WARNING: {XCFW_BINARY} missing — skipping lib xcframework")
        return

    print(f"\n[sulphur] Repackaging ThorVG_lib.xcframework ...")
    if NUCLEANT_LIB_XCFW.exists():
        shutil.rmtree(NUCLEANT_LIB_XCFW)

    slice_id = "macos-arm64_x86_64"
    dylib = NUCLEANT_LIB_XCFW / slice_id / LIB_XCFW_DYLIB
    dylib.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(XCFW_BINARY), str(dylib))
    subprocess.run(["install_name_tool", "-id", LIB_INSTALL_NAME, str(dylib)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(dylib)], check=True)

    arches = subprocess.check_output(["lipo", "-archs", str(dylib)], text=True).split()
    archs_xml = "".join(f"\n\t\t\t\t<string>{a}</string>" for a in arches)
    (NUCLEANT_LIB_XCFW / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        "<dict>\n"
        "\t<key>AvailableLibraries</key>\n"
        "\t<array>\n"
        "\t\t<dict>\n"
        f"\t\t\t<key>BinaryPath</key>\n\t\t\t<string>{LIB_XCFW_DYLIB}</string>\n"
        f"\t\t\t<key>LibraryIdentifier</key>\n\t\t\t<string>{slice_id}</string>\n"
        f"\t\t\t<key>LibraryPath</key>\n\t\t\t<string>{LIB_XCFW_DYLIB}</string>\n"
        f"\t\t\t<key>SupportedArchitectures</key>\n\t\t\t<array>{archs_xml}\n\t\t\t</array>\n"
        "\t\t\t<key>SupportedPlatform</key>\n\t\t\t<string>macos</string>\n"
        "\t\t</dict>\n"
        "\t</array>\n"
        "\t<key>CFBundlePackageType</key>\n\t<string>XFWK</string>\n"
        "\t<key>XCFrameworkFormatVersion</key>\n\t<string>1.0</string>\n"
        "</dict>\n"
        "</plist>\n"
    )
    print(f"[sulphur]   lib xcframework:    {dylib} ({' '.join(arches)})")
    print("[sulphur] Repackage done.\n")


def _repackage_linux() -> None:
    """Copy the freshly-built .so into Dependencies/linux/lib — vendored
    into the repo, the same way _repackage_macos_xcframework() vendors the
    fat dylib into Dependencies/apple/. Package.swift's Linux `CThorVG`
    target links this directly (unsafeFlags -L/-l + an -rpath back to this
    same directory), not through pkg-config.

    One file, made relocatable with patchelf, so it loads wherever it is
    copied — next to an executable, as SwiftPM does with an artifact bundle's
    library, or into a wheel:
      * SONAME libthorvg-1.so, the one file there is (not .so.1, a file
        nobody ships next to it);
      * wgpu by name, libwgpu_native.so: it has no SONAME, so the link
        recorded the absolute path meson resolved it to;
      * RUNPATH $ORIGIN instead of that build machine's directory.
    """
    built = THORVG_LINUX_SO_DIR / "libthorvg-1.so"
    if not built.is_file():
        print(f"[sulphur] WARNING: no libthorvg-1.so found in {THORVG_LINUX_SO_DIR} — skipping Dependencies/linux repackage")
        return
    if shutil.which("patchelf") is None:
        sys.exit("[sulphur] patchelf not found (apt install patchelf)")

    print(f"\n[sulphur] Repackaging Dependencies/linux ...")

    lib_dir = NUCLEANT_LINUX_DIR / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    for old in lib_dir.glob("libthorvg-1.so*"):
        old.unlink()
    so = lib_dir / "libthorvg-1.so"
    shutil.copy2(str(built), str(so))

    needed = subprocess.check_output(["patchelf", "--print-needed", str(so)], text=True).split()
    for name in needed:
        if name != "libwgpu_native.so" and name.endswith("/libwgpu_native.so"):
            subprocess.run(["patchelf", "--replace-needed", name, "libwgpu_native.so", str(so)], check=True)
    subprocess.run(["patchelf", "--set-soname", "libthorvg-1.so", str(so)], check=True)
    subprocess.run(["patchelf", "--set-rpath", "$ORIGIN", str(so)], check=True)
    needed = subprocess.check_output(["patchelf", "--print-needed", str(so)], text=True).split()
    if any("/" in name for name in needed):
        sys.exit(f"[sulphur] {so} still needs a library by path: {needed}")
    print(f"[sulphur]   {so}: needs {' '.join(needed)}")
    print("[sulphur] Repackage done.\n")


def _stage_wgpu_pkgconfig(name: str, stage: Path, include_dir: Path, lib_dir: Path,
                          libs: str) -> str:
    """A pkg-config directory holding only wgpu-native, as `name`.pc, with
    its headers under include/webgpu/ (the wg engine does `#include
    <webgpu/webgpu.h>`; wgpu-native ships them flat). Returned for
    PKG_CONFIG_LIBDIR, which *replaces* the default search path: the build
    machine's libpng/libjpeg stay invisible and thorvg builds its bundled
    decoders, as it does for every other platform."""
    inc = stage / "include" / "webgpu"
    pc_dir = stage / "pc"
    inc.mkdir(parents=True, exist_ok=True)
    pc_dir.mkdir(parents=True, exist_ok=True)
    for header in ("webgpu.h", "wgpu.h"):
        src = include_dir / header
        if not src.is_file():
            sys.exit(f"[sulphur] wgpu-native header not found: {src}")
        shutil.copy2(src, inc / header)
    # Forward slashes, also on Windows: pkg-config reads a backslash as an
    # escape.
    (pc_dir / f"{name}.pc").write_text(
        f"libdir={lib_dir.as_posix()}\n"
        f"includedir={include_dir.as_posix()}\n"
        "\n"
        f"Name: {name}\n"
        "Description: wgpu-native (WebGPU) for the ThorVG wg engine\n"
        "Version: 29.0.1.1\n"
        f"Cflags: -I{(stage / 'include').as_posix()}\n"
        f"Libs: {libs}\n"
    )
    return str(pc_dir)


def _repackage_windows() -> None:
    """Copy the freshly-built DLL and its import library into
    Dependencies/windows — the Windows _repackage_linux(). Nothing to patch:
    the DLL names wgpu_native.dll, no path, and Windows looks for it next to
    the executable, where SwiftPM copies both."""
    dll = THORVG_WINDOWS_OUT_DIR / "thorvg-1.dll"
    lib = THORVG_WINDOWS_OUT_DIR / "thorvg-1.lib"
    for built in (dll, lib):
        if not built.is_file():
            sys.exit(f"[sulphur] {built} not found — did the Windows build finish?")

    print(f"\n[sulphur] Repackaging Dependencies/windows ...")
    for built, sub_dir in ((dll, "bin"), (lib, "lib")):
        dest = NUCLEANT_WINDOWS_DIR / sub_dir
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(built), str(dest / built.name))
        print(f"[sulphur]   {dest / built.name}")
    print("[sulphur] Repackage done.\n")


def _stage_wgpu_android(abi: str) -> str:
    """Stage wgpu-native for one ABI into what thorvg's `wg` engine expects.

    The Android counterpart of _stage_wgpu_ios(): thorvg-cython knows nothing
    about this package, so everything it needs is handed over by environment —
    here a pkg-config directory it can be pointed at with PKG_CONFIG_LIBDIR.

    Three details, all forced by thorvg/meson rather than chosen:

      * the module is `wgpu_native` (underscore) while build_wgpu.py installs
        `wgpu-native.pc` (hyphen), so the name is aliased here — same aliasing
        _linux_wgpu_pkgconfig_dir() does inside thorvg-cython for Linux.
      * the wg engine does `#include <webgpu/webgpu.h>` while wgpu-native ships
        its headers flat, so a `webgpu/` directory of symlinks is staged.
      * Cflags uses -isystem and Libs uses -Wl,-L rather than -I/-L. pkg-config
        prefixes PKG_CONFIG_SYSROOT_DIR onto -I and -L only, and meson sets
        that from the Android cross file's sys_root — which would rewrite these
        absolute paths to <ndk-sysroot>/home/... and make them vanish. The
        other two spellings pass through untouched.
    """
    stage = SULPHUR_ROOT / "build" / "wgpu_stage" / abi
    inc = stage / "include" / "webgpu"
    pc_dir = stage / "pc"
    inc.mkdir(parents=True, exist_ok=True)
    pc_dir.mkdir(parents=True, exist_ok=True)

    src_inc = WGPU_ANDROID_DIR / "include"
    lib_dir = WGPU_ANDROID_DIR / abi / "lib"
    for header in ("webgpu.h", "wgpu.h"):
        src = src_inc / header
        if not src.is_file():
            sys.exit(f"[sulphur] wgpu-native header not found: {src}")
        dst = inc / header
        if dst.is_symlink() or dst.exists():
            dst.unlink()
        dst.symlink_to(src)

    (pc_dir / "wgpu_native.pc").write_text(
        "Name: wgpu_native\n"
        "Description: wgpu-native (WebGPU) for the ThorVG wg engine\n"
        "Version: 29.0.1.1\n"
        f"Cflags: -isystem{stage / 'include'}\n"
        f"Libs: -Wl,-L{lib_dir} -lwgpu_native\n"
    )
    return str(pc_dir)


def _build_android_abi(abi: str, arch_name: str, gpu: str) -> None:
    """Build one Android ABI against its own staged wgpu.

    thorvg-cython builds every ABI inside a single process, and pkg-config is
    configured once per process — so one run can only ever describe one ABI's
    wgpu. Rather than ask thorvg-cython to change (it knows nothing about this
    package and must stay that way), the remaining ABIs are driven here, from
    the cross files it already generated, with that ABI's staged .pc.

    meson args come from thorvg-cython's own _meson_common() so the two paths
    cannot drift.
    """
    build_root = THORVG_ROOT / "build_android"
    cross_file = build_root / "cross" / f"{arch_name}.txt"
    if not cross_file.is_file():
        sys.exit(f"[sulphur] cross file missing: {cross_file}")

    build_dir = build_root / arch_name
    if build_dir.exists():
        # A fresh configure is required, not --reconfigure: meson caches the
        # pkg-config result and would reuse the previous ABI's wgpu.
        shutil.rmtree(build_dir)

    pc_dir = _stage_wgpu_android(abi)
    env = {
        **os.environ,
        "PKG_CONFIG": shutil.which("pkg-config") or "pkg-config",
        "PKG_CONFIG_LIBDIR": pc_dir,
        "PKG_CONFIG_PATH": pc_dir,
    }

    print(f"\n[sulphur] Building {arch_name} ({abi}) against staged wgpu ...")
    subprocess.run(
        ["meson", "setup", str(build_dir), "--cross-file", str(cross_file)]
        + _thorvg_meson_args(gpu),
        cwd=str(THORVG_ROOT), env=env, check=True,
    )
    subprocess.run(["ninja", "-C", str(build_dir)],
                   cwd=str(THORVG_ROOT), env=env, check=True)

    out_dir = THORVG_ROOT / "output" / arch_name
    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(build_dir / "src" / "libthorvg-1.so"),
                 str(out_dir / "libthorvg-1.so"))
    print(f"[sulphur]   {arch_name}: {out_dir / 'libthorvg-1.so'}")


def _thorvg_meson_args(gpu: str) -> list[str]:
    """Reuse thorvg-cython's own meson arguments rather than restating them."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "_tvg_build", str(THORVG_BUILD_SCRIPT))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod._meson_common("android", gpu)


def _repackage_android() -> None:
    """Copy the freshly-built .so files into Dependencies/android/<abi>/lib.

    Same job as _repackage_linux(), but per-ABI: Android builds one
    architecture at a time and Package.swift's `.android` branch resolves
    Dependencies/android/<abi>/lib for whichever ABI is being built. No rpath
    is involved (unlike Linux) — on device the loader resolves DT_NEEDED out of
    the app's native library directory, where Gradle stages this .so.
    """
    for out_name, abi in ANDROID_OUTPUT_ABIS.items():
        src_dir = THORVG_ROOT / "output" / out_name
        so_files = list(src_dir.glob("libthorvg-1.so*"))
        if not so_files:
            print(f"[sulphur] WARNING: no libthorvg-1.so* found in {src_dir} "
                  f"— skipping {abi}")
            continue

        lib_dir = NUCLEANT_ANDROID_DIR / abi / "lib"
        lib_dir.mkdir(parents=True, exist_ok=True)
        for f in so_files:
            shutil.copy2(str(f), str(lib_dir / f.name))
        print(f"[sulphur]   {abi}: {lib_dir}")

    print("[sulphur] Android repackage done.\n")


def _stage_wgpu_ios() -> Path:
    """Lay the wgpu XCFramework's iOS slices out the way build_thorvg.py's
    per-slice pkg-config expects:

        include/webgpu/{webgpu.h,wgpu.h}
        lib/ios_arm64/libwgpu_native.dylib        (device arm64)
        lib/ios_sim_arm64/libwgpu_native.dylib    (simulator arm64)
        lib/ios_sim_x86_64/libwgpu_native.dylib   (simulator x86_64)

    Each dylib keeps its @rpath/libwgpu_native.dylib install name so the built
    ThorVG.framework references the same shared wgpu the engine embeds.
    """
    if not WGPU_XCFRAMEWORK.is_dir():
        sys.exit(f"[sulphur] wgpu XCFramework not found at {WGPU_XCFRAMEWORK} — "
                 f"run NucleantVulkan/scripts/build_wgpu.py first")

    # Sibling of build_ios/ (which build_thorvg.py wipes on each run).
    stage = THORVG_CYTHON_DIR / "thorvg" / "_wgpu_ios_stage"
    if stage.exists():
        shutil.rmtree(stage)
    inc = stage / "include" / "webgpu"
    inc.mkdir(parents=True)
    hdrs = WGPU_XCFRAMEWORK / "ios-arm64" / "Headers"
    for h in ("webgpu.h", "wgpu.h"):
        shutil.copy2(hdrs / h, inc / h)

    device = WGPU_XCFRAMEWORK / "ios-arm64" / "libwgpu_native.dylib"
    sim    = WGPU_XCFRAMEWORK / "ios-arm64_x86_64-simulator" / "libwgpu_native.dylib"

    def _put(src: Path, slice_name: str, thin_arch: str | None) -> None:
        d = stage / "lib" / slice_name
        d.mkdir(parents=True, exist_ok=True)
        out = d / "libwgpu_native.dylib"
        if thin_arch:
            subprocess.run(["lipo", str(src), "-thin", thin_arch, "-output", str(out)],
                           check=True)
        else:
            shutil.copy2(src, out)

    _put(device, "ios_arm64", None)          # already a single arm64 slice
    _put(sim,    "ios_sim_arm64", "arm64")
    _put(sim,    "ios_sim_x86_64", "x86_64")
    print(f"[sulphur] staged iOS wgpu at {stage}")
    return stage


def _repackage_ios_xcframework() -> None:
    """Fold build_thorvg.py's iOS thorvg.xcframework slices into
    NucleantThorVG's ThorVG.xcframework, renaming thorvg -> ThorVG to match the
    macOS convention (binary name, install name, CThorVG's link)."""
    import plistlib
    import tempfile

    if not THORVG_IOS_XCFW.is_dir():
        sys.exit(f"[sulphur] expected {THORVG_IOS_XCFW} after the iOS build")

    work = Path(tempfile.mkdtemp(prefix="thorvg_ios_"))
    ios_frameworks: list[Path] = []
    for slice_dir in sorted(THORVG_IOS_XCFW.iterdir()):
        fw = slice_dir / "thorvg.framework"
        if not fw.is_dir():
            continue
        dst = work / slice_dir.name / "ThorVG.framework"
        dst.mkdir(parents=True)
        shutil.copy2(fw / "thorvg", dst / "ThorVG")
        subprocess.run(["install_name_tool", "-id",
                        "@rpath/ThorVG.framework/ThorVG", str(dst / "ThorVG")], check=True)
        shutil.copytree(fw / "Headers", dst / "Headers")
        plist_path = fw / "Info.plist"
        info = plistlib.loads(plist_path.read_bytes()) if plist_path.exists() else {}
        info["CFBundleExecutable"] = "ThorVG"
        info["CFBundleName"] = "ThorVG"
        (dst / "Info.plist").write_bytes(plistlib.dumps(info))
        ios_frameworks.append(dst)

    if not ios_frameworks:
        sys.exit(f"[sulphur] no thorvg.framework slices under {THORVG_IOS_XCFW}")

    # Rebuild ThorVG.xcframework from the existing macOS slice + the new iOS ones.
    macos_fw = NUCLEANT_XCFW / "macos-arm64_x86_64" / "ThorVG.framework"
    cmd = ["xcodebuild", "-create-xcframework", "-framework", str(macos_fw)]
    for fw in ios_frameworks:
        cmd += ["-framework", str(fw)]
    new_xcfw = work / "ThorVG.xcframework"
    cmd += ["-output", str(new_xcfw)]
    subprocess.run(cmd, check=True)

    if NUCLEANT_XCFW.exists():
        shutil.rmtree(NUCLEANT_XCFW)
    shutil.copytree(new_xcfw, NUCLEANT_XCFW, symlinks=True)
    print(f"[sulphur] ThorVG.xcframework rebuilt with macos + "
          f"{[f.parent.name for f in ios_frameworks]}")

    # Fold in libomp.xcframework (iOS-only, dynamic OpenMP) so NucleantThorVG's
    # Package.swift can embed libomp.framework on iOS — the iOS ThorVG.framework
    # links @rpath/libomp.framework/libomp.
    if LIBOMP_IOS_XCFW.is_dir():
        if NUCLEANT_LIBOMP.exists():
            shutil.rmtree(NUCLEANT_LIBOMP)
        shutil.copytree(LIBOMP_IOS_XCFW, NUCLEANT_LIBOMP, symlinks=True)
        print(f"[sulphur] libomp.xcframework copied -> {NUCLEANT_LIBOMP}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="SulphurCore thorvg build wrapper.",
        add_help=False,
    )
    parser.add_argument("platform", help="Target platform")
    parser.add_argument(
        "--thorvg-version", default=None,
        help="ThorVG release version to auto-download if source is missing",
    )
    parser.add_argument(
        "--repackage-only", action="store_true",
        help="re-run only the repackage step against the already-built artifacts",
    )
    args, forwarded = parser.parse_known_args()

    if args.repackage_only:
        if args.platform != "macos":
            sys.exit(f"[sulphur] --repackage-only is macos-only, got {args.platform!r}")
        # After a build per architecture (--target-arch): the fat dylib.
        thin = [THORVG_ROOT / "output" / f"macos_{arch}" / "libthorvg-1.dylib" for arch in ("arm64", "x86_64")]
        if all(path.is_file() for path in thin):
            FAT_DYLIB_SRC.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["lipo", "-create", *map(str, thin), "-output", str(FAT_DYLIB_SRC)], check=True)
            _repackage_macos_xcframework()
        _repackage_macos_lib_xcframework()
        return

    _ensure_thorvg_cython()

    env = os.environ.copy()
    if args.platform == "macos":
        if not WGPU_XCFRAMEWORK.is_dir():
            sys.exit(f"[sulphur] wgpu XCFramework not found at {WGPU_XCFRAMEWORK} — "
                     f"run NucleantVulkan/scripts/build_wgpu.py first")
        # thorvg-cython's macOS build finds wgpu through pkg-config alone: the
        # xcframework's macOS slice (fat), linked as @rpath/libwgpu_native.dylib.
        wgpu_macos = WGPU_XCFRAMEWORK / "macos-arm64_x86_64"
        pc_dir = _stage_wgpu_pkgconfig(
            "wgpu_native", SCRIPT_DIR / ".work" / "wgpu_stage" / "macos",
            wgpu_macos / "Headers", wgpu_macos, f"-L{wgpu_macos} -lwgpu_native")
        env["PKG_CONFIG_LIBDIR"] = pc_dir
        env["PKG_CONFIG_PATH"] = pc_dir
    elif args.platform == "ios":
        if not WGPU_XCFRAMEWORK.is_dir():
            sys.exit(f"[sulphur] wgpu XCFramework not found at {WGPU_XCFRAMEWORK} — "
                     f"run NucleantVulkan/scripts/build_wgpu.py first")
        # build_thorvg.py stages per-slice wgpu_native.framework bundles from
        # this xcframework (iOS links -framework, not a bare dylib).
        env["WGPU_XCFRAMEWORK"] = str(WGPU_XCFRAMEWORK)
    elif args.platform == "android":
        # The `wg` engine links wgpu-native, so it has to exist before thorvg
        # is configured — failing here beats a link error deep in Meson.
        missing = [
            abi for abi in ANDROID_OUTPUT_ABIS.values()
            if not (WGPU_ANDROID_DIR / abi / "lib" / "libwgpu_native.so").is_file()
        ]
        if missing:
            sys.exit(
                f"[sulphur] wgpu-native missing for Android ABI(s) {missing} — "
                "build it first: python3 ../NucleantVulkan/scripts/build_wgpu.py "
                "--android"
            )
        # thorvg-cython stages each ABI's wgpu itself from here
        # (<abi>/lib, include/), so every ABI links its own.
        env["THORVG_ANDROID_WGPU_ROOT"] = str(WGPU_ANDROID_DIR)
        # thorvg-cython builds every ABI in one invocation, so one
        # PKG_CONFIG_LIBDIR has to serve them all — see the note in main()
        # below about which ABIs that actually yields.
        pc_dir = _stage_wgpu_android(ANDROID_PRIMARY_ABI)
        env["PKG_CONFIG"] = shutil.which("pkg-config") or "pkg-config"
        # LIBDIR *replaces* the default search path, so the build machine's
        # .pc files (libpng etc — x86_64 Linux objects that cannot link into an
        # Android .so) stay invisible and thorvg falls back to its bundled
        # decoders.
        env["PKG_CONFIG_LIBDIR"] = pc_dir
        env["PKG_CONFIG_PATH"] = pc_dir
        if not any(a.startswith("--gpu") for a in forwarded):
            forwarded = ["--gpu=vulkan"] + forwarded
    elif args.platform == "linux":
        if not (WGPU_LINUX_DIR / "lib" / "libwgpu_native.so").is_file():
            sys.exit(
                f"[sulphur] wgpu-native not found in {WGPU_LINUX_DIR} — build it first: "
                "python3 ../NucleantVulkan/scripts/build_wgpu.py --prefix ../NucleantVulkan/Dependencies/linux"
            )
        # thorvg-cython asks pkg-config for `wgpu-native`; this is the only
        # one it sees.
        pc_dir = _stage_wgpu_pkgconfig(
            "wgpu-native", SCRIPT_DIR / ".work" / "wgpu_stage" / "linux",
            WGPU_LINUX_DIR / "include", WGPU_LINUX_DIR / "lib",
            f"-L{WGPU_LINUX_DIR / 'lib'} -lwgpu_native")
        env["PKG_CONFIG_LIBDIR"] = pc_dir
        env["PKG_CONFIG_PATH"] = pc_dir
        # Default to the `wg` (WebGPU) engine, unless the caller forwarded
        # their own --gpu.
        if not any(a.startswith("--gpu") for a in forwarded):
            forwarded = ["--gpu=vulkan"] + forwarded

    elif args.platform == "windows":
        if not (WGPU_WINDOWS_DIR / "lib" / "wgpu_native.lib").is_file():
            sys.exit(
                f"[sulphur] wgpu-native not found in {WGPU_WINDOWS_DIR} — build it first: "
                "python ../NucleantVulkan/scripts/build_wgpu.py"
            )
        # As on Android, the module is `wgpu_native`. Linked through its
        # import library; the DLL goes next to the executable.
        lib_dir = WGPU_WINDOWS_DIR / "lib"
        pc_dir = _stage_wgpu_pkgconfig(
            "wgpu_native", SCRIPT_DIR / ".work" / "wgpu_stage" / "windows",
            WGPU_WINDOWS_DIR / "include", lib_dir,
            f"-L{lib_dir.as_posix()} -lwgpu_native")
        # pkgconf (pip/uv's), ahead of any other pkg-config on PATH —
        # GitHub's Windows machines have Strawberry Perl's.
        env["PKG_CONFIG"] = shutil.which("pkgconf") or "pkg-config"
        env["PKG_CONFIG_LIBDIR"] = pc_dir
        env["PKG_CONFIG_PATH"] = pc_dir
        if not any(a.startswith("--gpu") for a in forwarded):
            forwarded = ["--gpu=vulkan"] + forwarded

    cmd = [sys.executable, str(THORVG_BUILD_SCRIPT), args.platform]
    cmd += [f"--version={args.thorvg_version or THORVG_VERSION}"]
    cmd += forwarded

    print(f"[sulphur] Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(THORVG_CYTHON_DIR), env=env)
    if result.returncode != 0:
        if args.platform != "android":
            sys.exit(result.returncode)
        # Expected on Android with the wg engine: the run is staged for the
        # first ABI, so the later ones fail at link against the wrong
        # architecture. Tolerated only when the first ABI actually produced its
        # library — otherwise this is a real failure.
        primary = (THORVG_ROOT / "build_android" / ANDROID_PRIMARY_ARCH
                   / "src" / "libthorvg-1.so")
        if not primary.is_file():
            sys.exit(result.returncode)
        print(f"[sulphur] {ANDROID_PRIMARY_ARCH} built; rebuilding the "
              f"remaining ABIs with their own wgpu ...")

    if args.platform == "android":
        gpu = "vulkan" if any(a == "--gpu=vulkan" for a in forwarded) else ""
        out_root = THORVG_ROOT / "output"
        for arch_name, abi in ANDROID_OUTPUT_ABIS.items():
            built = THORVG_ROOT / "build_android" / arch_name / "src" / "libthorvg-1.so"
            if built.is_file():
                dst = out_root / arch_name
                dst.mkdir(parents=True, exist_ok=True)
                shutil.copy2(str(built), str(dst / "libthorvg-1.so"))
                continue
            _build_android_abi(abi, arch_name, gpu)

    if args.platform == "macos":
        if any(a.startswith("--target-arch") for a in forwarded) and not any(
                a in ("universal", "--target-arch=universal") for a in forwarded):
            print("[sulphur] one architecture built; `macos --repackage-only` "
                  "makes the fat binary once both are")
            return
        _repackage_macos_xcframework()
        _repackage_macos_lib_xcframework()
    elif args.platform == "ios":
        _repackage_ios_xcframework()
    elif args.platform == "linux":
        _repackage_linux()
    elif args.platform == "android":
        _repackage_android()
    elif args.platform == "windows":
        _repackage_windows()


if __name__ == "__main__":
    main()
