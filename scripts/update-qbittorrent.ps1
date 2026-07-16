<#
.SYNOPSIS
    Install or update qBittorrent in native portable mode.
.DESCRIPTION
    Fetches the latest qBittorrent Windows x64 release from GitHub, downloads it,
    extracts it with 7-Zip, deploys it to the local app folder, and keeps user
    data in app\profile.
.PARAMETER NonInteractive
    Skip the final "Press Enter" prompts. Useful for automation.
.VERSION
    1.0.0
#>

param(
    [switch]$NonInteractive
)

$ScriptVersion = '1.0.0'

$ErrorActionPreference = "Stop"
$RootDir = Split-Path $PSScriptRoot -Parent

# --- Configuration ---
$LogFile = Join-Path $RootDir "updater_events.log"
$AppDir = Join-Path $RootDir "app"
$ProfileDir = Join-Path $AppDir "profile"
$TempDir = Join-Path $RootDir "portable-temp"
$ShortcutPath = Join-Path $RootDir "qBittorrent Portable.lnk"
$InstallerVariantMarkerName = ".installer-variant"
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

function Assert-QBittorrentNotRunning {
    if (Test-ProcessRunning "qbittorrent") {
        throw "qbittorrent.exe is currently running. Close it before updating."
    }
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

    try {
        $script:UpdaterMutexAcquired = $script:UpdaterMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $script:UpdaterMutexAcquired = $true
        Write-Log "Recovered updater lock from a previous crashed instance." "WARN"
    }

    if (-not $script:UpdaterMutexAcquired) {
        $script:UpdaterMutex.Dispose()
        $script:UpdaterMutex = $null
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

function Test-AppPlaceholder {
    if (-not (Test-Path $AppDir)) { return $false }
    if (Test-ValidInstall -Directory $AppDir) { return $false }

    $Items = @(Get-ChildItem -Path $AppDir -Force -ErrorAction SilentlyContinue)
    if ($Items.Count -eq 0) { return $true }
    if ($Items.Count -eq 1 -and $Items[0].Name -eq '.gitkeep') { return $true }

    return $false
}

function Test-ProfileHasData {
    param([string]$Directory)

    if (-not (Test-Path $Directory)) { return $false }

    return [bool](Get-ChildItem -Path $Directory -Force -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-ProfileMetrics {
    param([string]$Directory)

    if (-not (Test-Path $Directory)) {
        return @{
            FileCount = 0
            ByteSize = [long]0
        }
    }

    $Files = @(Get-ChildItem -Path $Directory -Force -Recurse -File -ErrorAction SilentlyContinue)
    $ByteSize = ($Files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $ByteSize) { $ByteSize = 0 }

    return @{
        FileCount = $Files.Count
        ByteSize = [long]$ByteSize
    }
}

function Assert-DeploySucceeded {
    param([hashtable]$ExpectedProfileMetrics = $null)

    if (-not (Test-ValidInstall -Directory $AppDir)) {
        throw "Deploy verification failed: qbittorrent.exe is missing."
    }

    if (-not (Test-Path $ProfileDir)) {
        throw "Deploy verification failed: profile directory is missing."
    }

    $ProfileItem = Get-Item -LiteralPath $ProfileDir -Force
    if (-not $ProfileItem.PSIsContainer) {
        throw "Deploy verification failed: app\profile is not a directory."
    }

    if ($ExpectedProfileMetrics) {
        $ActualMetrics = Get-ProfileMetrics -Directory $ProfileDir

        if ($ActualMetrics.FileCount -ne $ExpectedProfileMetrics.FileCount) {
            throw "Deploy verification failed: profile file count mismatch (expected $($ExpectedProfileMetrics.FileCount), got $($ActualMetrics.FileCount))."
        }

        if ($ActualMetrics.ByteSize -ne $ExpectedProfileMetrics.ByteSize) {
            throw "Deploy verification failed: profile size mismatch (expected $($ExpectedProfileMetrics.ByteSize) bytes, got $($ActualMetrics.ByteSize) bytes)."
        }

        Write-Log "Profile verified ($($ActualMetrics.FileCount) files, $($ActualMetrics.ByteSize) bytes)."
    }

    Write-Log "Deploy verification passed."
}

function Get-UniqueDirectoryName {
    param([string]$Prefix)

    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        $Suffix = (Get-Date -Format "yyyy-MM-dd-HHmmss-fff")
        if ($Attempt -gt 0) {
            $Suffix = "$Suffix-$Attempt"
        }

        $Name = "$Prefix$Suffix"
        if (-not (Test-Path (Join-Path $RootDir $Name))) {
            return $Name
        }
    }

    throw "Could not allocate a unique directory name for prefix '$Prefix'."
}

function New-BackupDirectoryPath {
    return Join-Path $RootDir (Get-UniqueDirectoryName -Prefix "app-backup-")
}

function Restore-ProfileFromBackup {
    param(
        [array]$ValidBackups,
        [string]$DestinationProfileDir
    )

    if (Test-ProfileHasData -Directory $DestinationProfileDir) { return }

    foreach ($Backup in $ValidBackups) {
        $BackupProfileDir = Join-Path $Backup.FullName "profile"
        if (-not (Test-ProfileHasData -Directory $BackupProfileDir)) { continue }

        Write-Log "Profile missing or empty. Restoring from $($Backup.Name)..." "WARN"
        if (Test-Path $DestinationProfileDir) {
            Remove-Item -Path $DestinationProfileDir -Recurse -Force
        }

        Copy-Item -Path $BackupProfileDir -Destination $DestinationProfileDir -Recurse -Force
        return
    }
}

function Move-ProfileFromBackup {
    param(
        [string]$SourceProfileDir,
        [string]$DestinationProfileDir
    )

    if (-not (Test-Path $SourceProfileDir)) {
        throw "Source profile directory not found."
    }

    $ParentDir = Split-Path $DestinationProfileDir -Parent
    if (-not (Test-Path $ParentDir)) {
        New-Item -ItemType Directory -Path $ParentDir -Force | Out-Null
    }

    if (Test-Path $DestinationProfileDir) {
        if (Test-ProfileHasData -Directory $DestinationProfileDir) {
            throw "Cannot restore profile: destination already contains data."
        }

        Remove-Item -Path $DestinationProfileDir -Recurse -Force
    }

    try {
        Move-Item -LiteralPath $SourceProfileDir -Destination $ParentDir -Force
        Write-Log "Profile moved into app directory."
        return $true
    }
    catch {
        Write-Log "Profile move failed ($($_.Exception.Message)). Falling back to staged copy..." "WARN"
    }

    $StagingDir = "$DestinationProfileDir.new"
    if (Test-Path $StagingDir) {
        Remove-Item -Path $StagingDir -Recurse -Force
    }

    Copy-Item -Path $SourceProfileDir -Destination $StagingDir -Recurse -Force

    if (-not (Test-Path $StagingDir)) {
        throw "Profile copy fallback failed."
    }

    Move-Item -LiteralPath $StagingDir -Destination $DestinationProfileDir -Force
    Write-Log "Profile restored via staged copy."
    return $false
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

    $ValidBackups = @(Get-ValidBackupDirectories)

    if (-not (Test-Path $AppDir)) {
        if ($ValidBackups.Count -gt 0) {
            Write-Log "App directory missing. Restoring from $($ValidBackups[0].Name)..." "WARN"
            Rename-Item -Path $ValidBackups[0].FullName -NewName "app"
        }

        return
    }

    if (Test-ValidInstall -Directory $AppDir) {
        Restore-ProfileFromBackup -ValidBackups $ValidBackups -DestinationProfileDir $ProfileDir
        return
    }

    if (Test-AppPlaceholder) {
        if ($ValidBackups.Count -gt 0) {
            Write-Log "Placeholder app directory found. Restoring from $($ValidBackups[0].Name)..." "WARN"
            Remove-Item -Path $AppDir -Recurse -Force
            Rename-Item -Path $ValidBackups[0].FullName -NewName "app"
        } else {
            Write-Log "Removing placeholder app directory for first-time install."
            Remove-Item -Path $AppDir -Recurse -Force
        }

        return
    }

    if ($ValidBackups.Count -eq 0) {
        throw "Incomplete installation detected and no valid backup found. Remove or repair the app folder manually."
    }

    $RestoreBackup = $ValidBackups[0]
    $BrokenDirName = Get-UniqueDirectoryName -Prefix "app-broken-"

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
        [bool]$HadExistingInstall,
        [bool]$ProfileMovedFromBackup = $false
    )

    try {
        if ($HadExistingInstall -and $BackupDirectory -and (Test-Path $BackupDirectory)) {
            $BackupProfileDir = Join-Path $BackupDirectory "profile"

            if ($ProfileMovedFromBackup -and (Test-Path $AppDir)) {
                $AppProfileDir = Join-Path $AppDir "profile"
                if ((Test-Path $AppProfileDir) -and -not (Test-Path $BackupProfileDir)) {
                    Write-Log "Returning profile to backup before rollback..."
                    Move-Item -LiteralPath $AppProfileDir -Destination $BackupDirectory -Force
                }
            }

            $BrokenDirPath = $null

            if (Test-Path $AppDir) {
                $BrokenDirName = Get-UniqueDirectoryName -Prefix "app-broken-"
                $BrokenDirPath = Join-Path $RootDir $BrokenDirName
                Rename-Item -Path $AppDir -NewName $BrokenDirName -ErrorAction Stop
            }

            try {
                Rename-Item -Path $BackupDirectory -NewName "app" -ErrorAction Stop
            }
            catch {
                if ($BrokenDirPath -and (Test-Path $BrokenDirPath) -and -not (Test-Path $AppDir)) {
                    Rename-Item -Path $BrokenDirPath -NewName "app" -ErrorAction SilentlyContinue
                }

                throw
            }

            Write-Log "Rollback complete."
            return $true
        }

        if (Test-Path $AppDir) {
            Remove-Item -Path $AppDir -Recurse -Force -ErrorAction Stop
            Write-Log "Removed incomplete first-time installation."
        }

        return $true
    }
    catch {
        Write-Log "Rollback failed: $_" "ERROR"
        return $false
    }
}

function Get-PreferredInstallerVariant {
    $MarkerPath = Join-Path $AppDir $InstallerVariantMarkerName
    if (-not (Test-Path $MarkerPath)) { return $null }

    $Variant = (Get-Content -Path $MarkerPath -Raw).Trim().ToLowerInvariant()
    if ($Variant -eq "lt20" -or $Variant -eq "standard") {
        return $Variant
    }

    return $null
}

function Get-InstallerReleaseAsset {
    param($ReleaseAssets)

    $MatchingAssets = @(
        $ReleaseAssets | Where-Object { $_.name -match '^qbittorrent_\d+\.\d+\.\d+(_lt20)?_x64_setup\.exe$' }
    )

    if ($MatchingAssets.Count -eq 0) { return $null }

    $PreferredVariant = Get-PreferredInstallerVariant

    if ($PreferredVariant -eq "lt20") {
        $Selected = $MatchingAssets | Where-Object { $_.name -match '_lt20_' } | Select-Object -First 1
        if ($Selected) { return $Selected }
    }
    elseif ($PreferredVariant -eq "standard") {
        $Selected = $MatchingAssets | Where-Object { $_.name -notmatch '_lt20_' } | Select-Object -First 1
        if ($Selected) { return $Selected }
    }

    $Lt20Asset = $MatchingAssets | Where-Object { $_.name -match '_lt20_' } | Select-Object -First 1
    if ($Lt20Asset) { return $Lt20Asset }

    return $MatchingAssets | Where-Object { $_.name -notmatch '_lt20_' } | Select-Object -First 1
}

function Set-InstallerVariantMarker {
    param([string]$InstallerName)

    $Variant = if ($InstallerName -match '_lt20_') { "lt20" } else { "standard" }
    Set-Content -Path (Join-Path $AppDir $InstallerVariantMarkerName) -Value $Variant -Encoding ASCII -NoNewline
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

function Remove-OldBrokenInstalls {
    Get-ChildItem -Path $RootDir -Filter "app-broken-*" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Log "Removing broken install snapshot $(Split-Path $_.FullName -Leaf)."
            Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
}

# --- Main Logic ---
Write-Log "Updater v$ScriptVersion started"

try {
    Enter-UpdaterLock
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    Wait-ForExit
    exit 1
}

try {
    try {
        Assert-QBittorrentNotRunning
    }
    catch {
        Write-Log $_.Exception.Message "ERROR"
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
        $Asset = Get-InstallerReleaseAsset -ReleaseAssets $Release.assets

        if (-not $Asset) {
            throw "Could not find an x64 Windows installer in the latest release."
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

    Write-Log "Extracting installer using 7-Zip..."
    try {
        if (Test-Path $TempDir) {
            Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $TempDir) {
                throw "Could not remove stale extraction directory. Close any programs using portable-temp."
            }
        }

        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

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
    $PreserveInstaller = $false
    $ProfileMovedFromBackup = $false

    try {
        Assert-QBittorrentNotRunning

        if ($HadExistingInstall) {
            $ActiveBackupDir = New-BackupDirectoryPath
            Write-Log "Backing up current installation to $(Split-Path $ActiveBackupDir -Leaf)..."
            Rename-Item -Path $AppDir -NewName (Split-Path $ActiveBackupDir -Leaf)
        }

        Assert-QBittorrentNotRunning

        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null

        Write-Log "Deploying extracted files to app directory..."
        Get-ChildItem -Path $TempDir -Force | Move-Item -Destination $AppDir -Force
        Remove-NsisArtifacts -Directory $AppDir

        Assert-QBittorrentNotRunning

        $BackupProfileDir = if ($ActiveBackupDir) { Join-Path $ActiveBackupDir "profile" } else { $null }
        $ExpectedProfileMetrics = $null
        if ($BackupProfileDir -and (Test-Path $BackupProfileDir)) {
            $ExpectedProfileMetrics = Get-ProfileMetrics -Directory $BackupProfileDir
            Write-Log "Restoring profile from backup ($($ExpectedProfileMetrics.FileCount) files, $($ExpectedProfileMetrics.ByteSize) bytes)..."
            $ProfileMovedFromBackup = Move-ProfileFromBackup `
                -SourceProfileDir $BackupProfileDir `
                -DestinationProfileDir $ProfileDir
        } elseif (-not (Test-Path $ProfileDir)) {
            Write-Log "Creating profile directory for native portable mode..."
            New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
        }

        Set-InstallerVariantMarker -InstallerName $InstallerName

        Assert-DeploySucceeded -ExpectedProfileMetrics $ExpectedProfileMetrics

        Write-Log "qBittorrent updated successfully to $Version." "SUCCESS"
        $DeploymentSucceeded = $true
    }
    catch {
        Write-Log "Failed to deploy files: $_" "ERROR"
        Write-Log "Attempting rollback..."
        $RollbackSucceeded = Invoke-Rollback `
            -BackupDirectory $ActiveBackupDir `
            -HadExistingInstall $HadExistingInstall `
            -ProfileMovedFromBackup $ProfileMovedFromBackup
        if (-not $RollbackSucceeded) {
            Write-Log "Automatic rollback could not complete. Manual recovery may be required." "ERROR"
            $PreserveInstaller = $true
        }

        Wait-ForExit
        exit 1
    }
    finally {
        Write-Log "Cleaning up temporary files..."
        $InstallerToRemove = if ($PreserveInstaller) { $null } else { $InstallerPath }
        Remove-TempState -InstallerPath $InstallerToRemove -IncludeTempDir

        if ($DeploymentSucceeded) {
            Remove-OldBackups
            Remove-OldBrokenInstalls
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
