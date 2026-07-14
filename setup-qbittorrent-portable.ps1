<#
.SYNOPSIS
    qBittorrent Portable Updater script
.DESCRIPTION
    Fetches the latest qBittorrent release from GitHub, downloads it,
    extracts it using 7-Zip, and configures native portable mode.
#>

$ErrorActionPreference = "Stop"

# --- Configuration ---
$LogFile = "updater_events.log"
$AppDir = Join-Path $PSScriptRoot "app"
$ProfileDir = Join-Path $AppDir "profile"
$TempDir = Join-Path $PSScriptRoot "portable-temp"
$BackupDir = Join-Path $PSScriptRoot ("app-backup-" + (Get-Date -Format "yyyy-MM-dd-HHmmss"))

# --- Helper Functions ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] $Level: $Message"
    
    if ($Level -eq "ERROR") {
        Write-Host $LogLine -ForegroundColor Red
    } elseif ($Level -eq "SUCCESS") {
        Write-Host $LogLine -ForegroundColor Green
    } else {
        Write-Host $LogLine -ForegroundColor Cyan
    }
    
    Add-Content -Path $LogFile -Value $LogLine
}

function Test-ProcessRunning {
    param([string]$ProcessName)
    $isRunning = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    return [bool]$isRunning
}

function Get-7ZipPath {
    # Check common system paths first, then fall back to local folder like your Python script
    $paths = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        (Join-Path $PSScriptRoot "7zip\7z.exe")
    )
    foreach ($path in $paths) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

# --- Main Logic ---
Write-Log "Updater started"

# 1. Process Check
if (Test-ProcessRunning "qbittorrent") {
    Write-Log "qbittorrent.exe is currently running. Please close it before updating." "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

# 2. Get Latest Version via GitHub API
Write-Log "Fetching latest release data from GitHub..."
try {
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest"
    $Version = $Release.tag_name.TrimStart('v', 'release-')
    
    # Find the standard x64 Windows installer asset
    $Asset = $Release.assets | Where-Object { $_.name -match "qbittorrent_.*_x64_setup\.exe$" } | Select-Object -First 1
    
    if (-not $Asset) { throw "Could not find x64 installer asset in the latest release." }
    
    $DownloadUrl = $Asset.browser_download_url
    $InstallerName = $Asset.name
    Write-Log "Latest version identified: $Version"
}
catch {
    Write-Log "Failed to fetch version info: $_" "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

# 3. Download Installer
$InstallerPath = Join-Path $PSScriptRoot $InstallerName
Write-Log "Downloading $InstallerName..."
try {
    # Invoke-WebRequest automatically shows a progress bar in modern PowerShell
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath
    Write-Log "Download complete."
}
catch {
    Write-Log "Download failed: $_" "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

# 4. Check 7-Zip Dependency
$SevenZip = Get-7ZipPath
if (-not $SevenZip) {
    Write-Log "7-Zip not found. Please install it or place it in a '7zip' subfolder." "ERROR"
    Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue
    Read-Host "Press Enter to exit"
    exit 1
}

# 5. Extract Installer
if (Test-Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
New-Item -ItemType Directory -Path $TempDir | Out-Null

Write-Log "Extracting installer using 7-Zip..."
try {
    # The -y flag assumes yes to all prompts
    $Arguments = "x `"$InstallerPath`" -o`"$TempDir`" -y"
    $Process = Start-Process -FilePath $SevenZip -ArgumentList $Arguments -Wait -NoNewWindow -PassThru
    
    if ($Process.ExitCode -ne 0) { throw "7-Zip exited with code $($Process.ExitCode)" }
}
catch {
    Write-Log "Extraction failed: $_" "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

# 6. Backup and Deploy
if (Test-Path $AppDir) {
    Write-Log "Backing up current installation to $(Split-Path $BackupDir -Leaf)..."
    Copy-Item -Path $AppDir -Destination $BackupDir -Recurse
    
    Write-Log "Removing old application files..."
    # We remove files to avoid leaving deprecated DLLs behind, but preserve the profile folder
    Get-ChildItem -Path $AppDir | Where-Object { $_.Name -ne "profile" } | Remove-Item -Recurse -Force
} else {
    New-Item -ItemType Directory -Path $AppDir | Out-Null
}

Write-Log "Moving extracted files to app directory..."
try {
    # Move extracted files to the app directory
    Get-ChildItem -Path $TempDir | Move-Item -Destination $AppDir -Force
    
    # 7. Enable Portable Mode
    if (-not (Test-Path $ProfileDir)) {
        Write-Log "Creating native 'profile' directory to enforce portable mode..."
        New-Item -ItemType Directory -Path $ProfileDir | Out-Null
    }
    
    Write-Log "qBittorrent updated successfully to $Version." "SUCCESS"
}
catch {
    Write-Log "Failed to move files: $_" "ERROR"
    Write-Log "Attempting rollback..."
    if (Test-Path $BackupDir) {
        Remove-Item -Path $AppDir -Recurse -Force -ErrorAction SilentlyContinue
        Rename-Item -Path $BackupDir -NewName (Split-Path $AppDir -Leaf)
        Write-Log "Rollback complete." "INFO"
    }
    Read-Host "Press Enter to exit"
    exit 1
}

# 8. Cleanup
Write-Log "Cleaning up temporary files..."
Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue

# Keep only the newest backup, remove older ones to save space
Get-ChildItem -Path $PSScriptRoot -Filter "app-backup-*" -Directory | 
    Sort-Object CreationTime -Descending | 
    Select-Object -Skip 1 | 
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Log "Update sequence finished."
Write-Host "`nPress Enter to exit..."
Read-Host