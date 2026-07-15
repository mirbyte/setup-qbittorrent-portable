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
$UpdaterMutexName = "Global\setup-qbittorrent-portable-updater"
$DownloadMaxAttempts = 3
$DownloadTimeoutSec = 300
$UpdaterMutex = $null
$UpdaterMutexAcquired = $false

# --- Helper Functions ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] ${Level}: $Message"

    if ($Level -eq "ERROR") {
        Write-Host $LogLine -ForegroundColor Red
    } elseif ($Level -eq "SUCCESS") {
        Write-Host $LogLine -ForegroundColor Green
    } elseif ($Level -eq "WARN") {
        Write-Host $LogLine -ForegroundColor Yellow
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

function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [string]$OperationName,
        [int]$MaxAttempts = $DownloadMaxAttempts
    )

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
        try {
            if ($Attempt -gt 1) {
                Write-Log "Retrying $OperationName ($Attempt of $MaxAttempts)..."
            }

            return & $Action
        }
        catch {
            if ($Attempt -eq $MaxAttempts) {
                throw
            }

            Start-Sleep -Seconds (2 * $Attempt)
        }
    }
}

function Test-ProfileDirectory {
    if (-not (Test-Path $ProfileDir)) { return }

    $ProfileItem = Get-Item -LiteralPath $ProfileDir -Force
    if (-not $ProfileItem.PSIsContainer) {
        throw "app\profile exists but is not a directory."
    }
}

function Test-DiskSpace {
    param([long]$RequiredBytes)

    $RootDrive = (Get-Item -LiteralPath $RootDir).PSDrive.Name
    $FreeBytes = (Get-PSDrive -Name $RootDrive).Free

    if ($FreeBytes -lt $RequiredBytes) {
        $RequiredMb = [math]::Round($RequiredBytes / 1MB)
        throw "Insufficient disk space on drive ${RootDrive}:. At least $RequiredMb MB required."
    }
}

function Test-UpdaterEnvironment {
    param([long]$RequiredBytes = 200MB)

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "A 64-bit edition of Windows is required."
    }

    $ProbePath = Join-Path $RootDir ".write-test"
    try {
        "test" | Set-Content -Path $ProbePath -Encoding ASCII
        Remove-Item -Path $ProbePath -Force
    }
    catch {
        throw "Repository directory is not writable: $RootDir"
    }

    Test-ProfileDirectory
    Test-DiskSpace -RequiredBytes $RequiredBytes
}

function Test-InstallerIntegrity {
    param(
        [string]$InstallerPath,
        [long]$ExpectedSize,
        [string]$ExpectedDigest
    )

    if (-not (Test-Path $InstallerPath)) {
        throw "Installer file not found."
    }

    $ActualSize = (Get-Item $InstallerPath).Length
    if ($ActualSize -ne $ExpectedSize) {
        throw "Installer size mismatch. Expected $ExpectedSize bytes, got $ActualSize bytes."
    }

    if ($ExpectedDigest -notmatch '^sha256:(?<hash>[a-fA-F0-9]{64})$') {
        throw "Unexpected digest format from release metadata."
    }

    $ExpectedHash = $Matches['hash'].ToLowerInvariant()
    $ActualHash = (Get-FileHash -Path $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($ActualHash -ne $ExpectedHash) {
        throw "Installer SHA-256 mismatch."
    }

    Write-Log "Installer integrity verified (SHA-256)."
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

    Get-ChildItem -Path $Directory -Filter '$PLUGINSDIR' -Directory -Force -ErrorAction SilentlyContinue |
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

    if ($InstallerPath) {
        Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$InstallerPath.partial" -Force -ErrorAction SilentlyContinue
    }

    if ($IncludeTempDir -and (Test-Path $TempDir)) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Enter-UpdaterLock {
    $script:UpdaterMutex = New-Object System.Threading.Mutex($false, $UpdaterMutexName)
    $script:UpdaterMutexAcquired = $script:UpdaterMutex.WaitOne(0, $false)

    if (-not $script:UpdaterMutexAcquired) {
        throw "Another updater instance is already running."
    }
}

function Exit-UpdaterLock {
    if (-not $script:UpdaterMutexAcquired -or -not $script:UpdaterMutex) { return }

    $script:UpdaterMutex.ReleaseMutex()
    $script:UpdaterMutex.Dispose()
    $script:UpdaterMutex = $null
    $script:UpdaterMutexAcquired = $false
}

function Invoke-InstallerDownload {
    param(
        [string]$Uri,
        [string]$DestinationPath
    )

    if ($Uri -notmatch '^https://') {
        throw "Unexpected download URL."
    }

    $PartialPath = "$DestinationPath.partial"
    Remove-Item -Path $PartialPath -Force -ErrorAction SilentlyContinue

    $Headers = @{ "User-Agent" = "setup-qbittorrent-portable" }

    Invoke-WithRetry -OperationName "download" -Action {
        try {
            Invoke-WebRequest `
                -Uri $Uri `
                -OutFile $PartialPath `
                -Headers $Headers `
                -UseBasicParsing `
                -TimeoutSec $DownloadTimeoutSec

            if (-not (Test-Path $PartialPath) -or (Get-Item $PartialPath).Length -eq 0) {
                throw "Downloaded file is empty."
            }

            if (Test-Path $DestinationPath) {
                Remove-Item -Path $DestinationPath -Force
            }

            Move-Item -Path $PartialPath -Destination $DestinationPath -Force
        }
        catch {
            Remove-Item -Path $PartialPath -Force -ErrorAction SilentlyContinue
            throw
        }
    }
}

function Test-ValidInstall {
    param([string]$Directory)

    return Test-Path (Join-Path $Directory "qbittorrent.exe")
}

function Get-ValidBackupDirectories {
    Get-ChildItem -Path $RootDir -Filter "app-backup-*" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-ValidInstall -Directory $_.FullName } |
        Sort-Object CreationTime -Descending
}

function Remove-StaleUpdaterArtifacts {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed stale extraction directory."
    }

    Get-ChildItem -Path $RootDir -Filter "qbittorrent_*_setup.exe" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Get-ChildItem -Path $RootDir -Filter "qbittorrent_*_setup.exe.partial" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Repair-IncompleteState {
    Remove-StaleUpdaterArtifacts

    if (-not (Test-Path $AppDir)) {
        return
    }

    if (Test-ValidInstall -Directory $AppDir) {
        return
    }

    $ValidBackups = @(Get-ValidBackupDirectories)
    if ($ValidBackups.Count -eq 0) {
        throw "Incomplete installation detected and no valid backup found. Remove or repair the app folder manually."
    }

    $RestoreBackup = $ValidBackups[0]
    $BrokenDirName = "app-broken-" + (Get-Date -Format "yyyy-MM-dd-HHmmss")

    Write-Log "Incomplete installation detected. Restoring from $($RestoreBackup.Name)..." "WARN"
    Rename-Item -Path $AppDir -NewName $BrokenDirName
    Rename-Item -Path $RestoreBackup.FullName -NewName "app"
    Write-Log "Recovery complete. Previous broken install moved to $BrokenDirName."
}

function Test-ExtractedPayload {
    param([string]$Directory)

    $ExecutablePath = Join-Path $Directory "qbittorrent.exe"
    if (-not (Test-Path $ExecutablePath)) {
        throw "Extracted payload is missing qbittorrent.exe."
    }
}

function Invoke-Rollback {
    param(
        [string]$BackupDirectory,
        [bool]$HadExistingInstall
    )

    if ($HadExistingInstall -and $BackupDirectory -and (Test-Path $BackupDirectory)) {
        if (Test-Path $AppDir) {
            Remove-Item -Path $AppDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Rename-Item -Path $BackupDirectory -NewName "app"
        Write-Log "Rollback complete."
        return
    }

    if (Test-Path $AppDir) {
        Remove-Item -Path $AppDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed incomplete first-time installation."
    }
}

function Remove-OldBackups {
    $ValidBackups = @(Get-ValidBackupDirectories)
    $KeepBackup = if ($ValidBackups.Count -gt 0) { $ValidBackups[0].FullName } else { $null }

    Get-ChildItem -Path $RootDir -Filter "app-backup-*" -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            if ($KeepBackup -and $_.FullName -eq $KeepBackup) {
                return $false
            }

            return $true
        } |
        ForEach-Object {
            if (Test-ValidInstall -Directory $_.FullName) {
                Write-Log "Removing old backup $(Split-Path $_.FullName -Leaf)."
            } else {
                Write-Log "Removing invalid backup $(Split-Path $_.FullName -Leaf)."
            }

            Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
}

# --- Main Logic ---
Write-Log "Updater started"

try {
    Enter-UpdaterLock
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    Wait-ForExit
    exit 1
}

try {
    if (Test-ProcessRunning "qbittorrent") {
        Write-Log "qbittorrent.exe is currently running. Close it before updating." "ERROR"
        Wait-ForExit
        exit 1
    }

    try {
        Repair-IncompleteState
    }
    catch {
        Write-Log "Recovery failed: $_" "ERROR"
        Wait-ForExit
        exit 1
    }

    Write-Log "Running environment checks..."
    try {
        Test-UpdaterEnvironment
        Write-Log "Environment checks passed."
    }
    catch {
        Write-Log "Environment check failed: $_" "ERROR"
        Wait-ForExit
        exit 1
    }

    Write-Log "Fetching latest release data from GitHub..."
    try {
        $Release = Invoke-WithRetry -OperationName "release metadata fetch" -Action {
            Invoke-RestMethod -Uri "https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest"
        }
        $Version = $Release.tag_name -replace '^(?:v|release-)', ''
        $Asset = $Release.assets | Where-Object { $_.name -match $InstallerAssetPattern } | Select-Object -First 1

        if (-not $Asset) {
            throw "Could not find the standard x64 Windows installer in the latest release."
        }

        if (-not $Asset.size -or -not $Asset.digest) {
            throw "Release asset is missing size or digest metadata."
        }

        $DownloadUrl = $Asset.browser_download_url
        $InstallerName = $Asset.name
        Write-Log "Latest version identified: $Version ($InstallerName)"

        Test-DiskSpace -RequiredBytes ($Asset.size + 200MB)
    }
    catch {
        Write-Log "Failed to fetch version info: $_" "ERROR"
        Wait-ForExit
        exit 1
    }

    $InstallerPath = Join-Path $RootDir $InstallerName
    Write-Log "Downloading $InstallerName..."
    try {
        Invoke-InstallerDownload -Uri $DownloadUrl -DestinationPath $InstallerPath
        Write-Log "Download complete."
    }
    catch {
        Write-Log "Download failed: $_" "ERROR"
        Remove-TempState -InstallerPath $InstallerPath
        Wait-ForExit
        exit 1
    }

    Write-Log "Verifying installer integrity..."
    try {
        Test-InstallerIntegrity -InstallerPath $InstallerPath -ExpectedSize $Asset.size -ExpectedDigest $Asset.digest
    }
    catch {
        Write-Log "Installer verification failed: $_" "ERROR"
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

    Write-Log "Validating extracted payload..."
    try {
        Test-ExtractedPayload -Directory $TempDir
    }
    catch {
        Write-Log "Payload validation failed: $_" "ERROR"
        Remove-TempState -InstallerPath $InstallerPath -IncludeTempDir
        Wait-ForExit
        exit 1
    }

    $HadExistingInstall = Test-Path $AppDir
    $DeploymentSucceeded = $false
    $ActiveBackupDir = $null

    try {
        if ($HadExistingInstall) {
            $ActiveBackupDir = $BackupDir
            Write-Log "Backing up current installation to $(Split-Path $ActiveBackupDir -Leaf)..."
            Rename-Item -Path $AppDir -NewName (Split-Path $ActiveBackupDir -Leaf)
        }

        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null

        Write-Log "Deploying extracted files to app directory..."
        Get-ChildItem -Path $TempDir -Force | Move-Item -Destination $AppDir -Force
        Remove-NsisArtifacts -Directory $AppDir

        $BackupProfileDir = if ($ActiveBackupDir) { Join-Path $ActiveBackupDir "profile" } else { $null }
        if ($BackupProfileDir -and (Test-Path $BackupProfileDir)) {
            Write-Log "Restoring profile from backup..."
            Copy-Item -Path $BackupProfileDir -Destination $ProfileDir -Recurse -Force
        } elseif (-not (Test-Path $ProfileDir)) {
            Write-Log "Creating profile directory for native portable mode..."
            New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
        }

        Write-Log "qBittorrent updated successfully to $Version." "SUCCESS"
        $DeploymentSucceeded = $true
    }
    catch {
        Write-Log "Failed to deploy files: $_" "ERROR"
        Write-Log "Attempting rollback..."
        Invoke-Rollback -BackupDirectory $ActiveBackupDir -HadExistingInstall $HadExistingInstall
        Wait-ForExit
        exit 1
    }
    finally {
        Write-Log "Cleaning up temporary files..."
        Remove-TempState -InstallerPath $InstallerPath -IncludeTempDir

        if ($DeploymentSucceeded) {
            Remove-OldBackups
        } elseif ($ActiveBackupDir -and (Test-Path $ActiveBackupDir)) {
            Write-Log "Backup retained at $(Split-Path $ActiveBackupDir -Leaf) for recovery."
        }
    }

    if ($DeploymentSucceeded) {
        try {
            New-QBittorrentShortcut
        }
        catch {
            Write-Log "Shortcut creation failed: $_" "WARN"
        }
    }

    Write-Log "Update sequence finished."
    Wait-ForExit
}
finally {
    Exit-UpdaterLock
}
