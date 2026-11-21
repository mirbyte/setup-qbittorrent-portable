import re
import traceback
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
UPDATER = ROOT / "scripts" / "update-qbittorrent.ps1"

FILES = [
    "Update qBittorrent Portable.bat",
    "README.md",
    "LICENSE",
    "scripts/update-qbittorrent.ps1",
    "7zip/7z.exe",
    "7zip/7z.dll",
    "7zip/History.txt",
    "7zip/License.txt",
]
EMPTY_DIRS = ["app/"]


def main():
    match = re.search(r"ScriptVersion = '(.+?)'", UPDATER.read_text(encoding="utf-8"))
    if not match:
        raise RuntimeError("ScriptVersion not found in scripts/update-qbittorrent.ps1")

    default = match.group(1)
    version = input(f"Version [{default}]: ").strip() or default

    zip_path = ROOT / "release" / f"v{version}.zip"
    zip_path.parent.mkdir(exist_ok=True)

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in FILES:
            zf.write(ROOT / name, name)
        for name in EMPTY_DIRS:
            zf.writestr(name, "")

    print(f"Created {zip_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
    input("Press Enter to exit...")
