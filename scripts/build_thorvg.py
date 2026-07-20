#!/usr/bin/env python3
"""
SulphurCore build wrapper for thorvg.

Clones thorvg-cython next to SulphurCore if not already present,
then delegates to its build_thorvg.py script.

After a macOS build this script also repackages the fat dylib into
SulphurCore/output/ThorVG.xcframework so Xcode picks up the new symbols.

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

# Where build_thorvg.py drops the macOS fat dylib
THORVG_ROOT     = THORVG_CYTHON_DIR / "thorvg"
FAT_DYLIB_SRC   = THORVG_ROOT / "output" / "macos_fat" / "libthorvg-1.dylib"

# Where SulphurCore/Package.swift expects the binary.
# macOS frameworks must use the versioned layout (not shallow bundles):
#   ThorVG.framework/Versions/A/ThorVG   ← actual binary
#   ThorVG.framework/ThorVG              → Versions/Current/ThorVG (symlink)
XCFW_FW_DIR     = SULPHUR_ROOT / "output" / "ThorVG.xcframework" / \
                  "macos-arm64_x86_64" / "ThorVG.framework"
XCFW_BINARY     = XCFW_FW_DIR / "Versions" / "A" / "ThorVG"
LOOSE_DYLIB_DST = SULPHUR_ROOT / "output" / "macos" / "libthorvg-1.dylib"

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

    cmd = [sys.executable, str(THORVG_BUILD_SCRIPT), args.platform]
    if args.thorvg_version:
        cmd += [f"--version={args.thorvg_version}"]
    cmd += forwarded

    print(f"[sulphur] Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(THORVG_CYTHON_DIR))
    if result.returncode != 0:
        sys.exit(result.returncode)

    if args.platform == "macos":
        _repackage_macos_xcframework()


if __name__ == "__main__":
    main()
