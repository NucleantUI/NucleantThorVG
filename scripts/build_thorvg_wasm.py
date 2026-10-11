#!/usr/bin/env python3
"""Cross-compile ThorVG for WebAssembly (wasm32-unknown-wasip1).

The wasm counterpart of build_thorvg.py: the same ThorVG release the other
platforms vendor, built as a static archive

    Dependencies/wasm/lib/libthorvg-1.a

for NucleantThorVG's CThorVG target to link into the app's one module (a
browser has no dynamic loader).

Engines: `wg`, as everywhere else — on wasm it draws through NucleantVulkan's
CWgpu, which is webgpu.h on the browser's WebGPU, so ThorVG renders on the
page's GPUDevice into textures the Vulkan engine imports without a copy —
and `cpu` for software canvases. The webgpu.h it compiles against is
CWgpuWasm's (the same header as wgpu-native's); meson finds it through a
`wgpu_native` pkg-config file written here, with no library to link — the
symbols come from CWgpu when the app links.

Loaders as in the Linux build (svg, png, jpg, lottie, ttf). No threads: a
wasm32-wasip1 module runs on the page's one thread, and the SDK's libc++ has
no thread support; ThorVG's task scheduler then runs every task inline. The
wg engine still names a `std::mutex` around its renderer count, so — as in
NucleantVulkan's build_shader_tools_wasm.py — a force-included header
supplies a mutex that never contends.

The compiler is the clang of the Swift toolchain matching the installed wasm
Swift SDK, and the sysroot is that SDK's WASI.sdk — the libc/libc++ the
Swift side links against.

    python3 scripts/build_thorvg_wasm.py [--clean] [--thorvg-version 1.0.5]
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PACKAGE_ROOT = SCRIPT_DIR.parent
WORK_DIR = SCRIPT_DIR / ".work"
WASM_LIB_DIR = PACKAGE_ROOT / "Dependencies" / "wasm" / "lib"
# CWgpuWasm's include/ (webgpu/webgpu.h) in the sibling NucleantVulkan checkout.
DEFAULT_WEBGPU_INCLUDE = PACKAGE_ROOT.parent / "NucleantVulkan" / "Sources" / "CWgpuWasm" / "include"

THORVG_REPO = "https://github.com/thorvg/thorvg.git"
# The release the Apple/Linux/Android binaries are built from.
THORVG_VERSION = "1.0.5"
TRIPLE = "wasm32-wasip1"
VERSION_RE = re.compile(r"(\d+\.\d+(?:\.\d+)?)")

MUTEX_SHIM = """\
#pragma once
#ifdef __cplusplus
#include <__config>
#if !_LIBCPP_HAS_THREADS
_LIBCPP_BEGIN_NAMESPACE_STD
class mutex {
public:
    constexpr mutex() noexcept = default;
    mutex(const mutex&) = delete;
    mutex& operator=(const mutex&) = delete;
    void lock() {}
    bool try_lock() { return true; }
    void unlock() {}
};
_LIBCPP_END_NAMESPACE_STD
#endif
#endif
"""


def log(message: str) -> None:
    print(f"[build_thorvg_wasm] {message}", flush=True)


def run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> None:
    log("$ " + " ".join(str(c) for c in cmd))
    subprocess.check_call(cmd, cwd=cwd, env=env)


def require(tool: str) -> None:
    if shutil.which(tool) is None:
        sys.exit(f"error: required tool not found on PATH: {tool}")


def find_sysroot() -> Path:
    """The WASI.sdk sysroot inside the installed wasm Swift SDK bundle."""
    for root in (Path.home() / "Library" / "org.swift.swiftpm" / "swift-sdks", Path.home() / ".swiftpm" / "swift-sdks"):
        for sysroot in sorted(root.glob(f"*_wasm.artifactbundle/*/wasm32-unknown-wasip1/WASI.sdk"), reverse=True):
            return sysroot
    sys.exit("error: no wasm Swift SDK found (https://www.swift.org/documentation/articles/wasm-getting-started.html)")


def find_toolchain_bin(sysroot: Path) -> Path:
    """usr/bin of the Swift toolchain whose version matches the SDK."""
    match = VERSION_RE.search(str(sysroot))
    version = match.group(1) if match else None
    for base in (Path.home() / "Library" / "Developer" / "Toolchains", Path("/Library/Developer/Toolchains")):
        candidate = base / f"swift-{version}-RELEASE.xctoolchain" / "usr" / "bin"
        if (candidate / "clang").is_file() and (candidate / "llvm-ar").is_file():
            return candidate
    sys.exit(f"error: no Swift {version} toolchain with clang found; install it with `swiftly install {version}`")


def sync_thorvg(version: str) -> Path:
    src = WORK_DIR / "thorvg"
    tag = f"v{version}"
    if (src / ".git").is_dir():
        run(["git", "fetch", "--depth", "1", "origin", "tag", tag], cwd=src)
        run(["git", "checkout", "--force", tag], cwd=src)
    else:
        WORK_DIR.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--depth", "1", "--branch", tag, THORVG_REPO, str(src)])
    return src


def patch_thorvg(src: Path) -> None:
    """ThorVG's meson links pthread on every system but Windows, Android and
    Emscripten. wasi has no threads to link (and this build turns them off);
    meson's probe for the library fails outright. Treat it like Emscripten."""
    meson_build = src / "src" / "meson.build"
    text = meson_build.read_text()
    probe = "host_machine.system() != 'emscripten'\n    thread_dep"
    if probe in text:
        meson_build.write_text(text.replace(
            probe, "host_machine.system() != 'emscripten' and host_machine.system() != 'wasi'\n    thread_dep"))
        log("patched src/meson.build: no pthread on wasi")


def write_cross_files(bin_dir: Path, sysroot: Path, webgpu_include: Path) -> tuple[Path, Path]:
    wasm_dir = WORK_DIR / "wasm"
    wasm_dir.mkdir(parents=True, exist_ok=True)
    shim = wasm_dir / "wasi_single_thread_mutex.h"
    shim.write_text(MUTEX_SHIM)

    # dependency('wgpu_native') in ThorVG's wg meson.build: headers only.
    pkgconfig = wasm_dir / "pkgconfig"
    pkgconfig.mkdir(exist_ok=True)
    (pkgconfig / "wgpu_native.pc").write_text(
        "Name: wgpu_native\n"
        "Description: webgpu.h on the browser's WebGPU (NucleantVulkan CWgpuWasm)\n"
        "Version: 0\n"
        f"Cflags: -I{webgpu_include}\n"
        "Libs:\n"
    )

    target = [f"--target={TRIPLE}", f"--sysroot={sysroot}"]
    # ThorVG keeps a few scratch buffers thread_local. With one thread they
    # are plain statics, and the SDK's thread-less libc++abi has no
    # __cxa_thread_atexit to register their destructors with — so compile
    # them as statics outright.
    single_thread = ["-Dthread_local=", "-Wno-keyword-macro"]
    cross = wasm_dir / "wasm32-wasip1.ini"
    cross.write_text(
        "[binaries]\n"
        f"c = '{bin_dir / 'clang'}'\n"
        f"cpp = '{bin_dir / 'clang++'}'\n"
        f"ar = '{bin_dir / 'llvm-ar'}'\n"
        f"strip = '{bin_dir / 'llvm-strip'}'\n"
        "pkg-config = 'pkg-config'\n"
        "\n[built-in options]\n"
        f"c_args = {target}\n"
        f"cpp_args = {target + ['-include', str(shim), '-fno-exceptions'] + single_thread}\n"
        f"c_link_args = {target}\n"
        f"cpp_link_args = {target}\n"
        "\n[host_machine]\n"
        "system = 'wasi'\n"
        "cpu_family = 'wasm32'\n"
        "cpu = 'wasm32'\n"
        "endian = 'little'\n"
    )
    return cross, pkgconfig


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--thorvg-version", default=THORVG_VERSION)
    parser.add_argument("--webgpu-include", type=Path, default=DEFAULT_WEBGPU_INCLUDE,
                        help="directory holding webgpu/webgpu.h (NucleantVulkan/Sources/CWgpuWasm/include)")
    parser.add_argument("--clean", action="store_true", help="reconfigure from scratch")
    args = parser.parse_args()

    for tool in ("git", "meson", "ninja", "pkg-config"):
        require(tool)
    if not (args.webgpu_include / "webgpu" / "webgpu.h").is_file():
        sys.exit(f"error: no webgpu/webgpu.h under {args.webgpu_include}; pass --webgpu-include")

    sysroot = find_sysroot()
    bin_dir = find_toolchain_bin(sysroot)
    log(f"sysroot {sysroot}")
    log(f"toolchain {bin_dir}")

    src = sync_thorvg(args.thorvg_version)
    patch_thorvg(src)
    cross, pkgconfig = write_cross_files(bin_dir, sysroot, args.webgpu_include.resolve())
    build_dir = WORK_DIR / "build" / "thorvg-wasm32"
    if args.clean and build_dir.exists():
        shutil.rmtree(build_dir)

    env = dict(os.environ, PKG_CONFIG_LIBDIR=str(pkgconfig), PKG_CONFIG_PATH="")
    if not (build_dir / "build.ninja").is_file():
        run([
            "meson", "setup", str(build_dir), str(src),
            "--cross-file", str(cross),
            "--buildtype=release",
            "-Ddefault_library=static",
            "-Dengines=cpu,wg",
            "-Dloaders=svg,png,jpg,lottie,ttf",
            "-Dthreads=false",
            "-Dsimd=false",
            "-Dbindings=capi",
            "-Dextra=",
            "-Dfile=true",
            "-Dlog=false",
            "-Dtests=false",
        ], env=env)
    run(["ninja", "-C", str(build_dir)], env=env)

    archive = next(build_dir.rglob("libthorvg-1.a"), None)
    if archive is None:
        sys.exit(f"error: libthorvg-1.a not produced under {build_dir}")
    WASM_LIB_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(archive, WASM_LIB_DIR / archive.name)
    log(f"installed -> {WASM_LIB_DIR / archive.name} ({archive.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
