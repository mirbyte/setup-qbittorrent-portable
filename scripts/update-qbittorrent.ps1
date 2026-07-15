<#
.SYNOPSIS
    Install or update qBittorrent in native portable mode.
.DESCRIPTION
    Fetches the latest qBittorrent Windows x64 release from GitHub, downloads it,
    extracts it with 7-Zip, deploys it to the local app folder, and keeps user
    data in app\profile.
.PARAMETER NonInteractive
    Skip the final "Press Enter" prompts. Useful for automation.
#>

param(
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path $PSScriptRoot -Parent

# --- Configuration ---
$LogFile = Join-Path $RootDir "updater_events.log"
$AppDir = Join-Path $RootDir "app"
$ProfileDir = Join-Path $AppDir "profile"
$TempDir = Join-Path $RootDir "portable-temp"
$ShortcutPath = Join-Path $RootDir "qBittorrent Portable.lnk"
$BackupDir = Join-Path $RootDir ("app-backup-" + (Get-Date -Format "yyyy-MM-dd-HHmmss"))
$InstallerAssetPattern = '^qbittorrent_\d+\.\d+\.\d+_x64_setup\.exe$'

# --- Helper Functions ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] ${Level}: $Message"

    if ($Level -eq "ERROR") {
        Write-Host $LogLine -ForegroundColor Red
    } elseif ($Level -eq "SUCCESS") {
        Write-Host $LogLine -ForegroundColor Green
    } else {
        Write-Host $LogLine -ForegroundColor Cyan
    }

    Add-Content -Path $LogFile -Value $LogLine
}

function Wait-ForExit {
    if ($NonInteractive) { return }
    Write-Host ""
    Read-Host "Press Enter to exit"
}

function Test-ProcessRunning {
    param([string]$ProcessName)
    return [bool](Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
}

function Get-7ZipPath {
    $paths = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        (Join-Path $RootDir "7zip\7z.exe")
    )

    foreach ($path in $paths) {
        if (Test-Path $path) { return $path }
    }

    return $null
}

function Remove-NsisArtifacts {
    param([string]$Directory)

    Get-ChildItem -Path $Directory -Filter '$PLUGINSDIR' -Directory -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function New-QBittorrentShortcut {
    $ExecutablePath = Join-Path $AppDir "qbittorrent.exe"
    if (-not (Test-Path $ExecutablePath)) { return }

    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $ExecutablePath
    $Shortcut.WorkingDirectory = $AppDir
    $Shortcut.Save()
    Write-Log "Shortcut updated at $(Split-Path $ShortcutPath -Leaf)"
}

function Remove-TempState {
    param(
        [string]$InstallerPath = $null,
        [switch]$IncludeTempDir
    )

    if ($InstallerPath -and (Test-Path $InstallerPath)) {
        Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue
    }

    if ($IncludeTempDir -and (Test-Path $TempDir)) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Main Logic ---
Write-Log "Updater started"

if (Test-ProcessRunning "qbittorrent") {
    Write-Log "qbittorrent.exe is currently running. Close it before updating." "ERROR"
    Wait-ForExit
    exit 1
}

Write-Log "Fetching latest release data from GitHub..."
try {
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest"
    $Version = $Release.tag_name -replace '^(?:v|release-)', ''
    $Asset = $Release.assets | Where-Object { $_.name -match $InstallerAssetPattern } | Select-Object -First 1

    if (-not $Asset) {
        throw "Could not find the standard x64 Windows installer in the latest release."
    }

    $DownloadUrl = $Asset.browser_download_url
    $InstallerName = $Asset.name
    Write-Log "Latest version identified: $Version ($InstallerName)"
}
catch {
    Write-Log "Failed to fetch version info: $_" "ERROR"
    Wait-ForExit
    exit 1
}

$InstallerPath = Join-Path $RootDir $InstallerName
Write-Log "Downloading $InstallerName..."
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath
    Write-Log "Download complete."
}
catch {
    Write-Log "Download failed: $_" "ERROR"
    Remove-TempState -InstallerPath $InstallerPath
    Wait-ForExit
    exit 1
}

$SevenZip = Get-7ZipPath
if (-not $SevenZip) {
    Write-Log "7-Zip not found. Install it system-wide or place 7z.exe in the 7zip folder." "ERROR"
    Remove-TempState -InstallerPath $InstallerPath
    Wait-ForExit
    exit 1
}

if (Test-Path $TempDir) {
    Remove-Item -Path $TempDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TempDir | Out-Null

Write-Log "Extracting installer using 7-Zip..."
try {
    $Arguments = @(
        "x",
        "`"$InstallerPath`"",
        "-o`"$TempDir`"",
        "-y"
    )
    $Process = Start-Process -FilePath $SevenZip -ArgumentList ($Arguments -join ' ') -Wait -NoNewWindow -PassThru

    if ($Process.ExitCode -ne 0) {
        throw "7-Zip exited with code $($Process.ExitCode)"
    }

    Remove-NsisArtifacts -Directory $TempDir
}
catch {
    Write-Log "Extraction failed: $_" "ERROR"
    Remove-TempState -InstallerPath $InstallerPath -IncludeTempDir
    Wait-ForExit
    exit 1
}

if (Test-Path $AppDir) {
    Write-Log "Backing up current installation to $(Split-Path $BackupDir -Leaf)..."
    Copy-Item -Path $AppDir -Destination $BackupDir -Recurse
    Write-Log "Removing old application files..."
    Get-ChildItem -Path $AppDir | Where-Object { $_.Name -ne "profile" } | Remove-Item -Recurse -Force
} else {
    New-Item -ItemType Directory -Path $AppDir | Out-Null
}

Write-Log "Moving extracted files to app directory..."
try {
    Get-ChildItem -Path $TempDir | Move-Item -Destination $AppDir -Force
    Remove-NsisArtifacts -Directory $AppDir

    if (-not (Test-Path $ProfileDir)) {
        Write-Log "Creating profile directory for native portable mode..."
        New-Item -ItemType Directory -Path $ProfileDir | Out-Null
    }

    New-QBittorrentShortcut
    Write-Log "qBittorrent updated successfully to $Version." "SUCCESS"
}
catch {
    Write-Log "Failed to deploy files: $_" "ERROR"
    Write-Log "Attempting rollback..."

    if (Test-Path $BackupDir) {
        if (Test-Path $AppDir) {
            Remove-Item -Path $AppDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Move-Item -Path $BackupDir -Destination $AppDir
        Write-Log "Rollback complete."
    }

    Remove-TempState -InstallerPath $InstallerPath -IncludeTempDir
    Wait-ForExit
    exit 1
}

Write-Log "Cleaning up temporary files..."
Remove-TempState -InstallerPath $InstallerPath -IncludeTempDir

Get-ChildItem -Path $RootDir -Filter "app-backup-*" -Directory |
    Sort-Object CreationTime -Descending |
    Select-Object -Skip 1 |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Log "Update sequence finished."
Wait-ForExit
