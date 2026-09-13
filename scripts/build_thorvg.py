#!/usr/bin/env python3
"""
SulphurCore build wrapper for thorvg.

Clones thorvg-cython next to SulphurCore if not already present,
then delegates to its build_thorvg.py script.

After a macOS/iOS/linux build this script also repackages the built binary
into Dependencies/apple/ or Dependencies/linux/ so downstream builds pick up
the new symbols.

Usage
-----
    python scripts/build_thorvg.py <platform> [options]

Platforms
    linux / macos / ios / android / windows

GPU
    --gpu=vulkan    Vulkan backend (linux, macos, ios, android)
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
THORVG_CYTHON_REPO   = "https://github.com/kivy/thorvg-cython.git"
THORVG_BUILD_SCRIPT  = THORVG_CYTHON_DIR / "tools" / "build_thorvg.py"

# wgpu-native XCFramework (built by NucleantVulkan/scripts/build_wgpu.py) — the
# ThorVG `wg` engine links against it. For iOS we stage its slices into the
# per-arch layout build_thorvg.py's pkg-config wiring expects.
WGPU_XCFRAMEWORK = DEV_ROOT / "NucleantVulkan" / "Dependencies" / "wgpu_native.xcframework"

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
    subprocess.run(
        ["git", "clone", "--depth=1", THORVG_CYTHON_REPO, str(THORVG_CYTHON_DIR)],
        check=True,
    )


def _repackage_macos_xcframework() -> None:
    """Copy the freshly-built fat dylib into ThorVG.xcframework.

    macOS requires a versioned framework layout (not a shallow bundle):
        ThorVG.framework/
          Versions/A/ThorVG          ← real binary
          Versions/A/Resources/Info.plist
          Versions/Current           → A
          ThorVG                     → Versions/Current/ThorVG
          Resources                  → Versions/Current/Resources
    """
    if not FAT_DYLIB_SRC.exists():
        print(f"[sulphur] WARNING: fat dylib not found at {FAT_DYLIB_SRC} — skipping xcframework repackage")
        return

    print(f"\n[sulphur] Repackaging ThorVG.xcframework ...")

    # Ensure versioned directories exist
    resources_dir = XCFW_BINARY.parent / "Resources"
    resources_dir.mkdir(parents=True, exist_ok=True)

    # Copy binary and fix install name
    shutil.copy2(str(FAT_DYLIB_SRC), str(XCFW_BINARY))
    subprocess.run(
        ["install_name_tool", "-id", XCFW_INSTALL_NAME, str(XCFW_BINARY)],
        check=True,
    )
    print(f"[sulphur]   xcframework binary: {XCFW_BINARY}")

    # Rebuild versioned symlinks at framework root (idempotent)
    current_link = XCFW_FW_DIR / "Versions" / "Current"
    for link, target in [
        (current_link,              "A"),
        (XCFW_FW_DIR / "ThorVG",   "Versions/Current/ThorVG"),
        (XCFW_FW_DIR / "Resources", "Versions/Current/Resources"),
    ]:
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target)

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
    """
    so_files = list(THORVG_LINUX_SO_DIR.glob("libthorvg-1.so*"))
    if not so_files:
        print(f"[sulphur] WARNING: no libthorvg-1.so* found in {THORVG_LINUX_SO_DIR} — skipping Dependencies/linux repackage")
        return

    print(f"\n[sulphur] Repackaging Dependencies/linux ...")

    lib_dir = NUCLEANT_LINUX_DIR / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)

    for f in so_files:
        shutil.copy2(str(f), str(lib_dir / f.name))
    print(f"[sulphur]   libs: {lib_dir}")
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
        if args.platform == "macos":
            _repackage_macos_lib_xcframework()
        else:
            sys.exit(f"[sulphur] --repackage-only is macos-only, got {args.platform!r}")
        return

    _ensure_thorvg_cython()

    env = os.environ.copy()
    if args.platform == "ios":
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
        if shutil.which("pkg-config") is None or subprocess.run(
            ["pkg-config", "--exists", "wgpu-native"]
        ).returncode != 0:
            sys.exit(
                "[sulphur] wgpu-native not found via pkg-config — build it first, "
                "e.g.: python3 ../NucleantVulkan/scripts/build_wgpu.py --prefix ~/.local "
                "&& export PKG_CONFIG_PATH=~/.local/lib/pkgconfig:$PKG_CONFIG_PATH"
            )
        # Default to the `wg` (WebGPU) engine, unless the caller forwarded
        # their own --gpu.
        if not any(a.startswith("--gpu") for a in forwarded):
            forwarded = ["--gpu=vulkan"] + forwarded

    cmd = [sys.executable, str(THORVG_BUILD_SCRIPT), args.platform]
    if args.thorvg_version:
        cmd += [f"--version={args.thorvg_version}"]
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
        _repackage_macos_xcframework()
        _repackage_macos_lib_xcframework()
    elif args.platform == "ios":
        _repackage_ios_xcframework()
    elif args.platform == "linux":
        _repackage_linux()
    elif args.platform == "android":
        _repackage_android()


if __name__ == "__main__":
    main()
