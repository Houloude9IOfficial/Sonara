#!/usr/bin/env python3
"""Persistent interactive build launcher for Sonara."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent
APP = ROOT / "apps" / "sonara"
RELEASE_SCRIPT = ROOT / "tools" / "packaging" / "build-release.ps1"
MAC_RELEASE_SCRIPT = ROOT / "tools" / "packaging" / "build-macos.sh"
ANDROID_RELEASE_SCRIPT = ROOT / "tools" / "packaging" / "build-android.py"
OUTPUT_LOCK = threading.Lock()
PROCESS_LOCK = threading.Lock()
ACTIVE_PROCESSES: set[subprocess.Popen[str]] = set()

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")


@dataclass(frozen=True)
class BuildJob:
    channel: str
    command: tuple[str, ...]
    cwd: Path
    results: tuple[Path, ...]


def version() -> str:
    for line in (APP / "pubspec.yaml").read_text(encoding="utf-8").splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip().split("+", 1)[0]
    raise RuntimeError("Could not read the Sonara version from pubspec.yaml")


def powershell() -> str:
    executable = shutil.which("pwsh") or shutil.which("powershell")
    if executable is None:
        raise RuntimeError("PowerShell was not found on PATH")
    return executable


def flutter_executable() -> str:
    """Find Flutter even when a GUI-launched Python has a minimal PATH."""
    candidates: list[Path] = []
    for name in ("SONARA_FLUTTER_BIN", "FLUTTER_BIN"):
        if value := os.environ.get(name):
            candidates.append(Path(value).expanduser())
    for name in ("FLUTTER_ROOT", "FLUTTER_HOME"):
        if value := os.environ.get(name):
            candidates.append(Path(value).expanduser() / "bin" / "flutter")
    for name in ("flutter.bat", "flutter"):
        if value := shutil.which(name):
            candidates.append(Path(value))
    candidates.extend(
        [
            ROOT / ".fvm" / "flutter_sdk" / "bin" / "flutter",
            Path.home() / "Documents" / "workapps" / "flutter" / "bin" / "flutter",
            Path.home() / "development" / "flutter" / "bin" / "flutter",
            Path.home() / "flutter" / "bin" / "flutter",
            Path("/opt/homebrew/bin/flutter"),
            Path("/usr/local/bin/flutter"),
        ]
    )
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
    raise RuntimeError(
        "Flutter was not found. Set SONARA_FLUTTER_BIN to the full path of "
        "your Flutter executable, or add Flutter's bin directory to PATH."
    )


def flutter_command(*arguments: str) -> tuple[str, ...]:
    executable = flutter_executable()
    if os.name == "nt" and Path(executable).suffix.lower() in {".bat", ".cmd"}:
        command_processor = os.environ.get("COMSPEC", r"C:\Windows\System32\cmd.exe")
        return (command_processor, "/d", "/c", executable, *arguments)
    return (executable, *arguments)


def jobs_for(target: str, mode: str) -> list[BuildJob]:
    release = mode == "production"
    app_version = version()
    jobs: list[BuildJob] = []
    if target == "all":
        targets = {"android", "windows"} if os.name == "nt" else (
            {"android", "macos"} if sys.platform == "darwin" else {"android"}
        )
    else:
        targets = {target}

    if "windows" in targets:
        if release:
            command = (
                powershell(),
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(RELEASE_SCRIPT),
                "-Platform",
                "Windows",
            )
            results = (
                ROOT / "dist" / f"Sonara-{app_version}-windows-x64-setup.exe",
                ROOT / "dist" / "Sonara-windows-x64-portable" / "sonara.exe",
            )
        else:
            command = flutter_command("build", "windows", "--debug")
            results = (
                APP / "build" / "windows" / "x64" / "runner" / "Debug" / "sonara.exe",
            )
        jobs.append(BuildJob("Windows", command, ROOT if release else APP, results))

    if "macos" in targets:
        if release:
            command = ("bash", str(MAC_RELEASE_SCRIPT))
            results = (ROOT / "dist" / f"Sonara-{app_version}-macos-arm64.dmg",)
        else:
            command = flutter_command("build", "macos", "--debug")
            results = (APP / "build" / "macos" / "Build" / "Products" / "Debug" / "sonara.app",)
        jobs.append(BuildJob("macOS", command, ROOT if release else APP, results))

    if "android" in targets:
        if release:
            command = (
                (powershell(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(RELEASE_SCRIPT), "-Platform", "Android")
                if os.name == "nt" else (sys.executable, str(ANDROID_RELEASE_SCRIPT))
            )
            results = (ROOT / "dist" / f"Sonara-{app_version}-android.apk",)
        else:
            command = flutter_command("build", "apk", "--debug")
            results = (
                APP / "build" / "app" / "outputs" / "flutter-apk" / "app-debug.apk",
            )
        jobs.append(BuildJob("Android", command, ROOT if release else APP, results))

    return jobs


def channel_print(channel: str, message: str) -> None:
    with OUTPUT_LOCK:
        print(f"[{channel}] {message}", flush=True)


def run_job(job: BuildJob, dry_run: bool = False) -> int:
    channel_print(job.channel, f"Starting in {job.cwd}")
    channel_print(job.channel, "Command: " + subprocess.list2cmdline(job.command))
    if dry_run:
        return 0

    environment = os.environ.copy()
    cargo_bin = Path.home() / ".cargo" / "bin"
    flutter_bin = Path(flutter_executable()).parent
    python_bin = Path(sys.executable).resolve().parent
    environment["PATH"] = os.pathsep.join(
        (str(flutter_bin), str(cargo_bin), str(python_bin), environment.get("PATH", ""))
    )
    environment["SONARA_PYTHON"] = sys.executable
    process = subprocess.Popen(
        job.command,
        cwd=job.cwd,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    with PROCESS_LOCK:
        ACTIVE_PROCESSES.add(process)
    try:
        assert process.stdout is not None
        for line in process.stdout:
            channel_print(job.channel, line.rstrip())
        return process.wait()
    finally:
        with PROCESS_LOCK:
            ACTIVE_PROCESSES.discard(process)


def stop_active_processes() -> None:
    with PROCESS_LOCK:
        processes = list(ACTIVE_PROCESSES)
    for process in processes:
        if process.poll() is None:
            process.terminate()
    for process in processes:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def run_build(target: str, mode: str, dry_run: bool = False) -> bool:
    jobs = jobs_for(target, mode)
    outcomes: dict[str, int] = {}
    try:
        # Both platforms share one Flutter checkout. Run "all" in sequence so
        # macOS AOT's temporary SDK workaround cannot overlap Android's build.
        for job in jobs:
            try:
                outcomes[job.channel] = run_job(job, dry_run=dry_run)
            except Exception as error:
                channel_print(job.channel, f"Build process could not start: {error}")
                outcomes[job.channel] = 1
    except KeyboardInterrupt:
        print("\nStopping active builds…", flush=True)
        stop_active_processes()
        return False

    print("\nBuild results")
    print("-" * 72)
    success = True
    for job in jobs:
        exit_code = outcomes.get(job.channel, 1)
        if exit_code != 0:
            success = False
            print(f"{job.channel}: FAILED (exit code {exit_code})")
            continue
        print(f"{job.channel}: OK")
        for result in job.results:
            state = "created" if result.exists() else "missing"
            print(f"  {result.resolve()} [{state}]")
            success = success and (dry_run or result.exists())
    print("-" * 72)
    return success


def choose(prompt: str, options: dict[str, str], allow_back: bool = False) -> str | None:
    while True:
        print(f"\n{prompt}")
        for key, label in options.items():
            print(f"  {key}. {label}")
        if allow_back:
            print("  B. Back")
        print("  Q. Quit")
        answer = input("> ").strip().lower()
        if answer == "q":
            raise EOFError
        if allow_back and answer == "b":
            return None
        if answer in options:
            return options[answer].lower()
        print("Choose one of the listed options.")


def interactive() -> int:
    print("Sonara Builder")
    print("The menu remains open after each build; choose Q when you want to exit.")
    while True:
        try:
            target = choose(
                "What should be built?",
                ({"1": "Android", "2": "Windows", "3": "All"}
                 if os.name == "nt" else
                 {"1": "Android", "2": "macOS", "3": "All"}),
            )
            mode = choose(
                "Which build type?",
                {"1": "Production", "2": "Debug"},
                allow_back=True,
            )
            if mode is None:
                continue
            assert target is not None
            display_target = "macOS" if target == "macos" else target.title()
            print(f"\nBuilding {display_target} ({mode})…")
            run_build(target, mode)
            input("\nPress Enter to return to the build menu…")
        except EOFError:
            print("\nBuilder closed by request.")
            return 0
        except KeyboardInterrupt:
            stop_active_processes()
            print("\nBuild interrupted. Returning to the menu.")
            time.sleep(0.2)
        except Exception as error:
            print(f"\nBuild launcher error: {error}", file=sys.stderr)
            input("Press Enter to return to the build menu…")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build Sonara packages")
    parser.add_argument("--target", choices=("android", "windows", "macos", "all"))
    parser.add_argument("--mode", choices=("production", "debug"))
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.target or args.mode:
        if not args.target or not args.mode:
            print("--target and --mode must be supplied together", file=sys.stderr)
            return 2
        return 0 if run_build(args.target, args.mode, dry_run=args.dry_run) else 1
    return interactive()


if __name__ == "__main__":
    raise SystemExit(main())
