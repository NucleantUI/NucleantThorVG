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

XCFW_INSTALL_NAME = "@rpath/ThorVG.framework/ThorVG"


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
    args, forwarded = parser.parse_known_args()

    _ensure_thorvg_cython()

    env = os.environ.copy()
    if args.platform == "ios":
        if not WGPU_XCFRAMEWORK.is_dir():
            sys.exit(f"[sulphur] wgpu XCFramework not found at {WGPU_XCFRAMEWORK} — "
                     f"run NucleantVulkan/scripts/build_wgpu.py first")
        # build_thorvg.py stages per-slice wgpu_native.framework bundles from
        # this xcframework (iOS links -framework, not a bare dylib).
        env["WGPU_XCFRAMEWORK"] = str(WGPU_XCFRAMEWORK)
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
        sys.exit(result.returncode)

    if args.platform == "macos":
        _repackage_macos_xcframework()
    elif args.platform == "ios":
        _repackage_ios_xcframework()
    elif args.platform == "linux":
        _repackage_linux()


if __name__ == "__main__":
    main()
