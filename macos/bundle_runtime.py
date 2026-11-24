"""Assemble and relocate the build machine's arm64 inference runtime."""
import argparse
import concurrent.futures
import os
from pathlib import Path
import re
import shutil
import subprocess

MAGICS = {bytes.fromhex(n) for n in ("cffaedfe", "feedfacf", "cafebabe", "cafebabf", "bebafeca")}
SYSTEM = ("/usr/lib/", "/System/")
SEEN = set()


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def metadata(path):
    output = command("otool", "-L", str(path))
    links = list(dict.fromkeys(re.findall(r"^\s+(\S+) \(compatibility version", output, re.M)))
    kind = command("otool", "-hv", str(path))
    if "DYLIB" in kind and links:
        links.pop(0)
    return path, links, "DYLIB" in kind


def copy_tree(source, target):
    shutil.copytree(source, target, symlinks=False, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("venv", type=Path)
    parser.add_argument("--ffmpeg", default="/opt/homebrew/bin/ffmpeg", type=Path)
    args = parser.parse_args()
    runtime = args.app.resolve() / "Contents/Resources/Runtime"
    python = Path(command(str(args.venv / "bin/python"), "-c", "import sys; print(sys.base_prefix)").strip())
    stdlib = python / "lib/python3.11"
    site = Path(command(str(args.venv / "bin/python"), "-c", "import sysconfig; print(sysconfig.get_path('purelib'))").strip())
    bin_dir, lib = runtime / "bin", runtime / "lib"
    vendor = lib / "vendor"
    vendor.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(exist_ok=True)
    shutil.copy2(python / "Resources/Python.app/Contents/MacOS/Python", bin_dir / "python3.11")
    shutil.copy2(python / "Python", lib / "libpython3.11.dylib")
    copy_tree(stdlib, lib / "python3.11")
    copy_tree(site, lib / "python3.11/site-packages")
    for executable in [args.ffmpeg, args.ffmpeg.with_name("ffprobe")]:
        shutil.copy2(executable, bin_dir)
    paths = []
    for file in runtime.rglob("*"):
        if file.is_file():
            with file.open("rb") as handle:
                if handle.read(4) in MAGICS:
                    paths.append(file)
    destinations = {(python / "Python").resolve(): lib / "libpython3.11.dylib"}
    owners = {path: original for original, path in destinations.items()}
    notices = runtime / "Notices"
    notices.mkdir(exist_ok=True)

    def retain_notices(source):
        cellar = Path("/opt/homebrew/Cellar")
        if not source.is_relative_to(cellar):
            return
        formula, version, *_ = source.relative_to(cellar).parts
        root = cellar / formula / version
        if root in SEEN:
            return
        SEEN.add(root)
        for file in root.iterdir():
            if file.is_file() and file.name.upper().startswith(("COPYING", "LICENSE", "NOTICE", "COPYRIGHT", "SBOM")):
                target = notices / formula / file.name
                target.parent.mkdir(exist_ok=True)
                shutil.copy2(file, target)

    retain_notices((python / "Python").resolve())
    retain_notices(args.ffmpeg.resolve())
    processed = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        while paths:
            current, paths = paths, []
            for file, links, dylib in executor.map(metadata, current):
                changes = []
                for link in links:
                    if not link.startswith("/") or link.startswith(SYSTEM):
                        continue
                    original = Path(link).resolve(strict=True)
                    target = destinations.get(original)
                    if target is None:
                        target = vendor / original.name
                        if target in owners and owners[target] != original:
                            target = vendor / f"{original.parent.parent.name}-{original.name}"
                        if target in owners and owners[target] != original:
                            raise RuntimeError(f"Dependency filename collision: {original}")
                        owners[target] = original
                        destinations[original] = target
                        shutil.copy2(original, target)
                        retain_notices(original)
                        paths.append(target)
                    relative = os.path.relpath(target, file.parent)
                    changes += ["-change", link, "@loader_path/" + relative]
                if changes:
                    file.chmod(file.stat().st_mode | 0o200)
                    if dylib:
                        changes += ["-id", "@rpath/" + file.name]
                    command("install_name_tool", *changes, str(file))
                processed.append(file)
        list(executor.map(lambda file: command("codesign", "--force", "--sign", "-", str(file)), processed))
    print(f"Bundled {len(processed)} Mach-O files, including {len(destinations)} relocated libraries.")


if __name__ == "__main__":
    main()
