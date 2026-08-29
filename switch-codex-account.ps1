#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# All switcher-owned files live beside this script, never inside .codex.
$ConfigFile = Join-Path $PSScriptRoot 'config.json'
$DataRoot = Join-Path $PSScriptRoot 'data'
$AccountRoot = Join-Path $DataRoot 'accounts'
$BackupRoot = Join-Path $DataRoot 'backups'
$StateFile = Join-Path $DataRoot 'state.json'

$CodexHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
$LiveAuthFile = Join-Path $CodexHome 'auth.json'
$AccountCount = $null
$PackageFamilyName = $null

function Write-Info([string] $Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success([string] $Message) {
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Read-Configuration {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        throw "Configuration file was not found: $ConfigFile"
    }

    try {
        $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Configuration file is not valid JSON: $ConfigFile`n$($_.Exception.Message)"
    }

    if ($config.PSObject.Properties.Name -notcontains 'AccountCount') {
        throw "Configuration is missing AccountCount: $ConfigFile"
    }
    if ($config.PSObject.Properties.Name -notcontains 'PackageFamilyName') {
        throw "Configuration is missing PackageFamilyName: $ConfigFile"
    }
    if ($config.AccountCount -isnot [int] -and $config.AccountCount -isnot [long]) {
        throw 'AccountCount must be an integer.'
    }
    if ($config.AccountCount -lt 2 -or $config.AccountCount -gt [int]::MaxValue) {
        throw 'AccountCount must be an integer of at least 2.'
    }

    $familyName = [string] $config.PackageFamilyName
    if ([string]::IsNullOrWhiteSpace($familyName) -or $familyName -notmatch '^[^!\\/:]+_[^!\\/:]+$') {
        throw "PackageFamilyName is invalid: '$familyName'"
    }

    $script:AccountCount = [int] $config.AccountCount
    $script:PackageFamilyName = $familyName
}

function Get-AccountAuthPath([int] $AccountNumber) {
    return Join-Path (Join-Path $AccountRoot $AccountNumber.ToString()) 'auth.json'
}

function Assert-ValidAuthFile([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }
    if ((Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "$Description is empty: $Path"
    }
    try {
        $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "$Description is not valid JSON: $Path`n$($_.Exception.Message)"
    }
}

function Copy-FileAtomically {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [string] $BackupPath
    )

    $destinationDirectory = Split-Path -Parent $Destination
    $null = New-Item -ItemType Directory -Path $destinationDirectory -Force
    $temporaryFile = Join-Path $destinationDirectory ('.tmp-' + [Guid]::NewGuid().ToString('N'))

    try {
        [System.IO.File]::Copy($Source, $temporaryFile, $false)
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            if ($BackupPath) {
                $backupDirectory = Split-Path -Parent $BackupPath
                $null = New-Item -ItemType Directory -Path $backupDirectory -Force
                [System.IO.File]::Replace($temporaryFile, $Destination, $BackupPath, $true)
            }
            else {
                [System.IO.File]::Move($temporaryFile, $Destination, $true)
            }
        }
        else {
            [System.IO.File]::Move($temporaryFile, $Destination)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
}

function Write-StateAtomically([hashtable] $State) {
    $null = New-Item -ItemType Directory -Path $DataRoot -Force
    $temporaryFile = Join-Path $DataRoot ('.state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $stateBackup = Join-Path $BackupRoot 'state-previous.json'

    try {
        $json = $State | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($temporaryFile, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
            $null = New-Item -ItemType Directory -Path $BackupRoot -Force
            [System.IO.File]::Replace($temporaryFile, $StateFile, $stateBackup, $true)
        }
        else {
            [System.IO.File]::Move($temporaryFile, $StateFile)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
}

function Read-SwitcherState {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "The switcher state file is invalid: $StateFile`n$($_.Exception.Message)"
    }
}

function Get-ChatGPTProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop)
}

function Get-CodexBackendProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" -ErrorAction Stop)
}

function Stop-AllCodexProcesses {
    $processes = @(Get-ChatGPTProcesses)
    $backendProcesses = @(Get-CodexBackendProcesses)
    if ($processes.Count -eq 0 -and $backendProcesses.Count -eq 0) {
        Write-Info 'Codex desktop is already closed.'
        return
    }

    Write-Info "Closing $($processes.Count) ChatGPT.exe process(es)..."
    foreach ($item in $processes) {
        try {
            $process = Get-Process -Id ([int] $item.ProcessId) -ErrorAction Stop
            if ($process.MainWindowHandle -ne 0) {
                $null = $process.CloseMainWindow()
            }
        }
        catch {
            # The process may have exited between discovery and this request.
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-ChatGPTProcesses)
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        Write-Info 'Graceful shutdown timed out; stopping remaining ChatGPT.exe processes.'
        foreach ($item in $remaining) {
            Stop-Process -Id ([int] $item.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }

    # The desktop app may leave its codex.exe backend alive briefly. It must not
    # be allowed to update auth.json during the switch.
    $backendProcesses = @(Get-CodexBackendProcesses)
    foreach ($item in $backendProcesses) {
        Stop-Process -Id ([int] $item.ProcessId) -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 500
    $remaining = @(
        Get-ChatGPTProcesses
        Get-CodexBackendProcesses
    )
    if ($remaining.Count -gt 0) {
        $ids = ($remaining.ProcessId -join ', ')
        throw "Could not close all ChatGPT/Codex processes. Remaining process IDs: $ids"
    }
    Write-Success 'All ChatGPT/Codex processes are closed.'
}

function Start-ChatGPT {
    $explorer = Join-Path $env:SystemRoot 'explorer.exe'
    if (-not (Test-Path -LiteralPath $explorer -PathType Leaf)) {
        throw "Windows Explorer was not found: $explorer"
    }

    # ChatGPT/Codex is an Appx application. Starting its executable directly
    # from WindowsApps can fail with Access Denied. The AppsFolder application
    # ID is stable across package updates and requires no executable path.
    $appTarget = "shell:AppsFolder\$PackageFamilyName!App"
    Start-Process -FilePath $explorer -ArgumentList $appTarget -ErrorAction Stop
    Write-Success 'Codex desktop launch requested through Windows AppsFolder.'
}

$mutex = $null
$hasMutex = $false
$exitCode = 0

try {
    Read-Configuration

    $mutex = [Threading.Mutex]::new($false, 'Local\CodexAuthAccountSwitcher')
    try {
        $hasMutex = $mutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $hasMutex = $true
    }
    if (-not $hasMutex) {
        throw 'Another account switch is already running.'
    }

    $state = Read-SwitcherState
    if ($null -eq $state) {
        if (-not (Test-Path -LiteralPath $LiveAuthFile -PathType Leaf)) {
            throw "First-run initialization requires an existing Codex login, but auth.json was not found: $LiveAuthFile. Sign in to the first configured account, then run the switcher again."
        }
        Assert-ValidAuthFile -Path $LiveAuthFile -Description 'Current Codex auth.json'

        $initialAuthFile = Get-AccountAuthPath 1
        if (-not (Test-Path -LiteralPath $initialAuthFile -PathType Leaf)) {
            Copy-FileAtomically -Source $LiveAuthFile -Destination $initialAuthFile
            Write-Success 'Saved the current auth.json for account 1.'
        }

        $state = [pscustomobject]@{ ActiveAccountNumber = 1 }
        Write-StateAtomically -State @{
            ActiveAccountNumber = $state.ActiveAccountNumber
        }
        Write-Info 'Initialized switcher state. Current account: 1.'
    }
    else {
        if (-not (Test-Path -LiteralPath $LiveAuthFile -PathType Leaf)) {
            $stateAccount = if ($state.PSObject.Properties.Name -contains 'ActiveAccountNumber') { $state.ActiveAccountNumber } else { 'unknown' }
            throw "Account $stateAccount still has no auth.json. Complete sign-in in Codex before switching again."
        }
        Assert-ValidAuthFile -Path $LiveAuthFile -Description 'Current Codex auth.json'
    }

    if ($state.PSObject.Properties.Name -notcontains 'ActiveAccountNumber') {
        throw "State does not contain ActiveAccountNumber. Remove the obsolete state file and run the switcher again: $StateFile"
    }
    try {
        $currentAccountNumber = [int] $state.ActiveAccountNumber
    }
    catch {
        throw "State contains an invalid ActiveAccountNumber. Fix or remove: $StateFile"
    }
    if ($currentAccountNumber -lt 1 -or $currentAccountNumber -gt $AccountCount) {
        throw "State refers to account $currentAccountNumber, but AccountCount is $AccountCount. Fix or remove: $StateFile"
    }

    $nextAccountNumber = ($currentAccountNumber % $AccountCount) + 1
    $currentStoredAuth = Get-AccountAuthPath $currentAccountNumber
    $nextStoredAuth = Get-AccountAuthPath $nextAccountNumber

    $nextAccountHasAuth = Test-Path -LiteralPath $nextStoredAuth -PathType Leaf
    if ($nextAccountHasAuth) {
        Assert-ValidAuthFile -Path $nextStoredAuth -Description "Stored auth.json for account $nextAccountNumber"
    }
    else {
        Write-Info "Account $nextAccountNumber has no saved auth.json yet. Codex will be started without an active auth.json so you can sign in."
    }

    Write-Info "Switching account $currentAccountNumber -> $nextAccountNumber."
    Stop-AllCodexProcesses

    # Re-read only after shutdown so no Codex process can update auth.json while
    # it is being saved.
    Assert-ValidAuthFile -Path $LiveAuthFile -Description 'Current Codex auth.json after shutdown'

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupSet = Join-Path $BackupRoot $timestamp
    $storedBackup = if (Test-Path -LiteralPath $currentStoredAuth -PathType Leaf) {
        Join-Path $backupSet "$currentAccountNumber-stored-auth-before-save.json"
    } else {
        $null
    }

    Copy-FileAtomically -Source $LiveAuthFile -Destination $currentStoredAuth -BackupPath $storedBackup
    Write-Success "Saved refreshed authorization for account $currentAccountNumber."

    $liveBackup = Join-Path $backupSet 'live-auth-before-switch.json'
    $liveAuthChanged = $false
    try {
        if ($nextAccountHasAuth) {
            Copy-FileAtomically -Source $nextStoredAuth -Destination $LiveAuthFile -BackupPath $liveBackup
            $liveAuthChanged = $true
        }
        else {
            # Keep a recoverable copy, then remove only auth.json. With no live
            # auth file Codex starts in the signed-out state for this account.
            Copy-FileAtomically -Source $LiveAuthFile -Destination $liveBackup
            Remove-Item -LiteralPath $LiveAuthFile -Force
            $liveAuthChanged = $true
        }

        Write-StateAtomically -State @{
            ActiveAccountNumber = $nextAccountNumber
        }
    }
    catch {
        $switchError = $_.Exception.Message
        if ($liveAuthChanged) {
            try {
                Copy-FileAtomically -Source $liveBackup -Destination $LiveAuthFile
            }
            catch {
                throw "Account activation failed and the previous live auth.json could not be restored. Original error: $switchError. Restore error: $($_.Exception.Message)"
            }
            throw "Account activation failed; the previous live auth.json was restored. $switchError"
        }
        throw "Account activation failed before the live auth.json was changed. $switchError"
    }

    if ($nextAccountHasAuth) {
        Write-Success "Active account is now $nextAccountNumber."
    }
    else {
        Write-Success "Switched to unsigned-in account $nextAccountNumber. Sign in after Codex opens; its new auth.json will be saved on the next switch."
    }
    Write-Info "Backup created in: $backupSet"
    Start-ChatGPT
}
catch {
    $exitCode = 1
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($hasMutex -and $mutex) {
        $mutex.ReleaseMutex()
    }
    if ($mutex) {
        $mutex.Dispose()
    }
}

exit $exitCode
