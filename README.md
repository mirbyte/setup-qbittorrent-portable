# Unofficial qBittorrent portable setup

Install and update the official **qBittorrent** Windows x64 client in native portable mode.

> Not affiliated with or endorsed by the qBittorrent project.

## Use

1. Run **`Update qBittorrent Portable.bat`** to install qBittorrent on first run, or update it later.
2. Launch **`qBittorrent Portable.lnk`**

Close qBittorrent before re-running. Each run fetches the latest release from GitHub.

**Requirements:** Windows 10/11 x64, PowerShell, internet, free disk space for the installer plus your existing `app\` folder during updates.

## Layout

| Path | Purpose |
|------|---------|
| `app\` | Installed qBittorrent (created on first run) |
| `app\profile\` | Portable user data (torrent list, resume state, settings) |
| `app-backup-*\` | Previous install kept during update; removed after a verified successful update |
| `app-broken-*\` | Failed install snapshot, kept only until the next successful update |
| `scripts\update-qbittorrent.ps1` | Install/update script |
| `7zip\` | Bundled 7-Zip (see below) |
| `updater_events.log` | Updater log (check here if an update fails) |

## Updates & data safety

On update, the script:

1. Renames the current `app\` folder to `app-backup-*` (full backup, including profile).
2. Deploys the new qBittorrent build into a fresh `app\`.
3. Moves `profile` from the backup into `app\` (falls back to a staged copy if move fails).
4. Verifies `qbittorrent.exe`, the profile directory, and profile file count/size before treating the update as successful.
5. Rolls back automatically if deploy or verification fails, restoring the previous `app\`.

Downloaded torrent files are stored wherever you configured save paths in qBittorrent; only `app\profile\` is managed by this updater. Back up `app\profile\` separately if your data is critical.

## Bundled 7-Zip

This repo includes an **unmodified** copy of [7-Zip](https://www.7-zip.org/) (currently 26.02) in `7zip\`. It is used only to extract the official qBittorrent installer. No changes were made to the 7-Zip binaries.

7-Zip is Copyright (C) 1999-2026 Igor Pavlov, licensed under the GNU LGPL (see `7zip\License.txt`). A system-wide 7-Zip install is used instead if present.

---

<img width="1968" height="995" alt="download" src="https://github.com/user-attachments/assets/4e813550-3ebd-48d3-9a24-6e75302ce534" />


<br>


<img width="1456" height="731" alt="success" src="https://github.com/user-attachments/assets/14036b3d-c348-495d-911b-176acbf3905d" />



