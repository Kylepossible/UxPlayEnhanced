"""Verify a portable release without searching the build PC's PATH/System32.

--runtime-dir resolves missing third-party imports from the selected MinGW
runtime during packaging. Without it verification never changes the package.
Requires pefile (also installed with PyInstaller on Windows).
"""
import argparse
from pathlib import Path
import shutil

import pefile


# Windows OS libraries, not arbitrary DLLs that happen to be in System32.
WINDOWS_DLLS = set("""
advapi32.dll avrt.dll bcrypt.dll bcryptprimitives.dll comctl32.dll comdlg32.dll
cfgmgr32.dll crypt32.dll d2d1.dll d3d11.dll d3d12.dll dnsapi.dll dsound.dll dwmapi.dll
dwrite.dll dxgi.dll gdi32.dll gdiplus.dll imm32.dll iphlpapi.dll kernel32.dll
mmdevapi.dll msimg32.dll msvcrt.dll ncrypt.dll normaliz.dll ntdll.dll ole32.dll
oleaut32.dll opengl32.dll powrprof.dll propsys.dll psapi.dll rpcrt4.dll
secur32.dll setupapi.dll shell32.dll shlwapi.dll user32.dll userenv.dll
usp10.dll uxtheme.dll version.dll winhttp.dll wininet.dll winmm.dll
winspool.drv wintrust.dll ws2_32.dll wsock32.dll wtsapi32.dll
""".split())
REQUIRED = (
    "uxplay.exe", "UxPlayEnhanced.exe", "xvidcore.dll", "LICENSE", "README.md",
    "UxPlayEnhanced-Setup.cmd", "UxPlayEnhanced-Setup.ps1", "setup-firewall.ps1",
    "UxPlayEnhanced-Uninstall.ps1",
    *(f"lib/gstreamer-1.0/{name}.dll" for name in (
        "libgstcoreelements", "libgstapp", "libgstaudioconvert",
        "libgstaudioresample", "libgstlibav", "libgstwasapi",
    )),
)


def imports(path):
    with pefile.PE(str(path), fast_load=True) as binary:
        binary.parse_data_directories(directories=[1, 13])
        return {
            entry.dll.decode("ascii").lower()
            for kind in ("DIRECTORY_ENTRY_IMPORT", "DIRECTORY_ENTRY_DELAY_IMPORT")
            for entry in getattr(binary, kind, [])
        }


def verify(root, runtime=None):
    root = Path(root).resolve()
    errors = [f"Missing required file: {name}" for name in REQUIRED if not (root / name).is_file()]
    queue = [p for p in root.rglob("*") if p.suffix.lower() in {".exe", ".dll"}]
    checked = set()
    while queue:
        path = queue.pop()
        if path in checked:
            continue
        checked.add(path)
        for name in imports(path):
            if name in WINDOWS_DLLS or name.startswith(("api-ms-win-", "ext-ms-win-")):
                continue
            if (root / name).is_file() or (path.parent / name).is_file():
                continue
            candidate = Path(runtime) / name if runtime else None
            if candidate and candidate.is_file():
                target = root / name
                shutil.copy2(candidate, target)
                queue.append(target)
            else:
                errors.append(f"{path.relative_to(root)} imports missing {name}")
    if errors:
        raise RuntimeError("\n".join(errors))
    return len(checked)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--runtime-dir", type=Path)
    args = parser.parse_args()
    count = verify(args.package, args.runtime_dir)
    print(f"Package verified: {count} PE files, no missing third-party imports")
