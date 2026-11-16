#requires -version 5.1
<#
    Sepidyar RustDesk deployment for Windows x64
    - Installs RustDesk if missing
    - Configures the interactive user's profile and the service profile
    - Sets a permanent password using the documented RustDesk CLI
    - Writes server and security options into RustDesk2.toml for both profiles
    - Verifies the resulting configuration and writes a log
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------- Sepidyar settings ----------------
$ServerHost = 'support.sepidyar.me'
$RelayServer = "$ServerHost`:21117"
$PublicKey = 'vkFECZelMETmubPjiBbGtEMhzVvEQuvSPhSLYiAJa1o='
$PlainPassword = 'P@ssw0rd'
# ---------------------------------------------------

$LogDir = Join-Path $env:ProgramData 'Sepidyar\RustDesk'
$LogFile = Join-Path $LogDir 'Install-Sepidyar-RustDesk.log'
$TranscriptStarted = $false
$ServiceNameForRecovery = $null

function Write-Step {
    param([string]$Message)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Invoke-RustDesk {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$Description = 'RustDesk command'
    )

    Write-Host "  -> $Description"
    # Start-Process provides a real process exit code. $LASTEXITCODE can be empty
    # when RustDesk exits through its Windows GUI/IPC command path.
    $argumentLine = ($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' }
        else { $value }
    }) -join ' '
    $process = Start-Process -FilePath $script:RustDeskExe -ArgumentList $argumentLine -WorkingDirectory (Split-Path $script:RustDeskExe -Parent) -PassThru -Wait -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "$Description failed. Exit code: $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Backup-Config {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        Write-Host "  Backup: $backup" -ForegroundColor DarkGray
    }
}

function Test-ConfigValue {
    param(
        [string]$Content,
        [string]$Key,
        [string]$Expected
    )
    $pattern = '(?im)^\s*' + [regex]::Escape($Key) + '\s*=\s*[''\"]' + [regex]::Escape($Expected) + '[''\"]\s*$'
    return [regex]::IsMatch($Content, $pattern)
}

try {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    Start-Transcript -Path $LogFile -Append | Out-Null
    $TranscriptStarted = $true

    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host '          SEPIDYAR RUSTDESK DEPLOYMENT' -ForegroundColor Cyan
    Write-Host '====================================================' -ForegroundColor Cyan

    # Elevate if necessary. A later SID check prevents configuring the wrong profile
    # if UAC credentials for a different administrator account are supplied.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if (-not $PSCommandPath) { throw 'Save this script as a .ps1 file before running it.' }
        Write-Host 'Requesting administrator privileges...' -ForegroundColor Yellow
        $elevatedProcess = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
        )
        if ($elevatedProcess.ExitCode -ne 0) {
            throw "Elevated deployment process failed with exit code $($elevatedProcess.ExitCode)."
        }
        return
    }

    # Identify the actual interactive desktop user (the owner of Explorer).
    Write-Step 'Identifying the interactive Windows user'
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" |
        Select-Object -First 1
    if (-not $explorer) {
        throw 'No interactive Explorer session was found. Sign in to the target Windows account and run the installer again.'
    }
    $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
    if ($owner.ReturnValue -ne 0) {
        throw 'Could not identify the interactive Windows user.'
    }
    $interactiveName = "$($owner.Domain)\$($owner.User)"
    $interactiveSid = (New-Object Security.Principal.NTAccount($interactiveName)).Translate([Security.Principal.SecurityIdentifier]).Value
    $currentSid = $identity.User.Value

    Write-Host "Interactive user: $interactiveName"
    Write-Host "Elevated process: $($identity.Name)"
    if ($interactiveSid -ne $currentSid) {
        throw "This elevated PowerShell belongs to a different account than the logged-in desktop user ($interactiveName). Re-run the BAT and approve UAC using the same account, or run PowerShell as that user with administrator privileges. No user-profile settings were changed."
    }

    $profile = Get-CimInstance Win32_UserProfile -Filter "SID='$interactiveSid'" | Select-Object -First 1
    if (-not $profile -or -not $profile.LocalPath) {
        throw "Could not resolve the profile path for $interactiveName."
    }
    $userProfilePath = $profile.LocalPath
    $userConfigDir = Join-Path $userProfilePath 'AppData\Roaming\RustDesk\config'
    $userConfigPath = Join-Path $userConfigDir 'RustDesk2.toml'
    Write-Host "Target user profile: $userProfilePath"

    # Locate existing install.
    Write-Step 'Checking RustDesk installation'
    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'RustDesk\RustDesk.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\RustDesk\RustDesk.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
    $script:RustDeskExe = $candidatePaths | Select-Object -First 1

    if (-not $script:RustDeskExe) {
        Write-Host 'RustDesk not found. Downloading the official Windows x64 release...' -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -Headers @{ 'User-Agent' = 'Sepidyar-RustDesk-Installer' }
        $asset = $release.assets | Where-Object { $_.name -match '^rustdesk-.*-x86_64\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw 'Official RustDesk Windows x64 installer was not found in the latest release.' }
        $downloadDir = Join-Path $env:TEMP 'SepidyarRustDeskSetup'
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        $installerPath = Join-Path $downloadDir $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath
        $signature = Get-AuthenticodeSignature -FilePath $installerPath
        if ($signature.Status -ne 'Valid') {
            throw "Downloaded installer signature is not valid (status: $($signature.Status)). Installation aborted."
        }
        $installOutput = @(& $installerPath --silent-install 2>&1)
        $installExit = $LASTEXITCODE
        if ($installExit -ne 0) { throw "RustDesk silent installation failed. Exit code: $installExit" }
        Start-Sleep -Seconds 8
        $script:RustDeskExe = @(
            (Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'RustDesk\RustDesk.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if (-not $script:RustDeskExe) { throw 'RustDesk installer completed but RustDesk.exe was not found.' }
    }
    Write-Host "RustDesk executable: $script:RustDeskExe" -ForegroundColor Green

    # Ensure service is installed.
    Write-Step 'Checking and installing the Windows service'
    $service = Get-CimInstance Win32_Service | Where-Object { $_.Name -match '^RustDesk$' -or $_.DisplayName -match 'RustDesk' } | Select-Object -First 1
    if (-not $service) {
        Invoke-RustDesk -Arguments @('--install-service') -Description 'Install RustDesk service' | Out-Null
        Start-Sleep -Seconds 4
        $service = Get-CimInstance Win32_Service | Where-Object { $_.Name -match '^RustDesk$' -or $_.DisplayName -match 'RustDesk' } | Select-Object -First 1
    }
    if (-not $service) { throw 'RustDesk Windows service was not created.' }

    $serviceName = $service.Name
    $ServiceNameForRecovery = $serviceName
    $serviceStartName = $service.StartName
    Write-Host "Service: $serviceName | Account: $serviceStartName"

    # RustDesk's installed Windows service reads its machine-wide config from
    # the LocalService profile. The SCM StartName can report LocalSystem on
    # some builds while the RustDesk service worker stores its state under
    # LocalService. The user's own logs/files confirmed this exact location.
    $serviceRoaming = Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Roaming'
    $serviceConfigDir = Join-Path $serviceRoaming 'RustDesk\config'
    $serviceConfigPath = Join-Path $serviceConfigDir 'RustDesk2.toml'

    # Stop service and all client processes before changing config.
    Write-Step 'Stopping RustDesk processes before configuration'
    $svcNow = Get-Service -Name $serviceName
    if ($svcNow.Status -ne 'Stopped') { Stop-Service -Name $serviceName -Force }
    $svcNow.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Back up existing files.
    New-Item -ItemType Directory -Path $userConfigDir -Force | Out-Null
    New-Item -ItemType Directory -Path $serviceConfigDir -Force | Out-Null
    Backup-Config -Path $userConfigPath
    if ($serviceConfigPath -ne $userConfigPath) { Backup-Config -Path $serviceConfigPath }

    # Write the network and security settings directly to both active profiles.
    # Do not call --import-config here: it is intended for importing the RustDesk
    # exported config format and is not needed when deploying a prepared TOML file.
    Write-Step 'Writing the Sepidyar server configuration to user and service profiles'
    $configContent = @"
rendezvous_server = '$ServerHost`:21116'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '$ServerHost'
relay-server = '$RelayServer'
key = '$PublicKey'
approve-mode = 'password'
verification-method = 'use-permanent-password'
"@
    [IO.File]::WriteAllText($userConfigPath, $configContent, (New-Object System.Text.UTF8Encoding($false)))
    if ($serviceConfigPath -ne $userConfigPath) {
        [IO.File]::WriteAllText($serviceConfigPath, $configContent, (New-Object System.Text.UTF8Encoding($false)))
    }

    # Start the service first. The --password command talks to the running RustDesk
    # daemon over IPC; it is not a TOML option and must not be written as plain text.
    Write-Step 'Starting RustDesk service'
    Set-Service -Name $serviceName -StartupType Automatic
    Start-Service -Name $serviceName
    (Get-Service -Name $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Start-Sleep -Seconds 3

    # Apply the requested fixed permanent password. RustDesk stores the
    # password material in RustDesk.toml under the LocalService profile.
    Write-Step 'Setting the configured permanent RustDesk password'
    $servicePasswordConfigPath = Join-Path $serviceConfigDir 'RustDesk.toml'
    $passwordConfigExisted = Test-Path -LiteralPath $servicePasswordConfigPath -PathType Leaf
    $passwordConfigBefore = if ($passwordConfigExisted) { (Get-Item -LiteralPath $servicePasswordConfigPath).LastWriteTimeUtc } else { [DateTime]::MinValue }
    Invoke-RustDesk -Arguments @('--password', $PlainPassword) -Description 'Set permanent password on the running RustDesk service' | Out-Null
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath $servicePasswordConfigPath -PathType Leaf)) {
        throw "RustDesk did not create the LocalService password store: $servicePasswordConfigPath"
    }
    $passwordConfigAfter = Get-Item -LiteralPath $servicePasswordConfigPath
    if ($passwordConfigExisted -and $passwordConfigAfter.LastWriteTimeUtc -le $passwordConfigBefore) {
        throw 'The service password store was not updated by RustDesk. The permanent password cannot be confirmed.'
    }
    if ($passwordConfigAfter.Length -le 0) {
        throw 'The service password store is empty; permanent password setup cannot be confirmed.'
    }
    Write-Host '  OK: Service permanent-password store updated (password value not displayed).' -ForegroundColor Green

    # Validate both network/security TOML files. Password material is stored separately
    # by RustDesk in RustDesk.toml and is never copied or exposed by this script.
    Write-Step 'Verifying user configuration'
    if (-not (Test-Path -LiteralPath $userConfigPath)) { throw 'User RustDesk2.toml was not created.' }
    $userConfig = Get-Content -LiteralPath $userConfigPath -Raw
    $checks = @(
        @{ Key = 'custom-rendezvous-server'; Value = $ServerHost },
        @{ Key = 'relay-server'; Value = $RelayServer },
        @{ Key = 'key'; Value = $PublicKey },
        @{ Key = 'approve-mode'; Value = 'password' },
        @{ Key = 'verification-method'; Value = 'use-permanent-password' }
    )
    foreach ($check in $checks) {
        if (-not (Test-ConfigValue -Content $userConfig -Key $check.Key -Expected $check.Value)) {
            throw "Verification failed for '$($check.Key)' in user config. The script will not report success."
        }
        Write-Host "  OK: $($check.Key)" -ForegroundColor Green
    }

    # Verify the service profile independently; it was written before the daemon started.
    Write-Step 'Verifying the service profile'
    $serviceConfig = Get-Content -LiteralPath $serviceConfigPath -Raw
    foreach ($check in $checks) {
        if (-not (Test-ConfigValue -Content $serviceConfig -Key $check.Key -Expected $check.Value)) {
            throw "Verification failed for '$($check.Key)' in service config."
        }
    }

    # Restart service so it reloads the synchronized service-profile configuration.
    Write-Step 'Restarting service and launching the client'
    Restart-Service -Name $serviceName -Force
    (Get-Service -Name $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Start-Process -FilePath $script:RustDeskExe -WorkingDirectory (Split-Path $script:RustDeskExe -Parent)
    Start-Sleep -Seconds 5

    $finalService = Get-Service -Name $serviceName
    if ($finalService.Status -ne 'Running') { throw 'RustDesk service is not running after restart.' }
    $finalUserConfig = Get-Content -LiteralPath $userConfigPath -Raw
    $finalServiceConfig = Get-Content -LiteralPath $serviceConfigPath -Raw
    foreach ($check in $checks) {
        if (-not (Test-ConfigValue -Content $finalUserConfig -Key $check.Key -Expected $check.Value)) {
            throw "Post-start verification failed in user profile for '$($check.Key)'."
        }
        if (-not (Test-ConfigValue -Content $finalServiceConfig -Key $check.Key -Expected $check.Value)) {
            throw "Post-start verification failed in service profile for '$($check.Key)'."
        }
    }

    $idOutput = @(& $script:RustDeskExe --get-id 2>&1)
    $rustDeskId = ($idOutput | Where-Object { "$_" -match '^[A-Za-z0-9]+$' } | Select-Object -First 1)

    Write-Host "`n====================================================" -ForegroundColor Green
    Write-Host '       CONFIGURATION VERIFIED' -ForegroundColor Green
    Write-Host '====================================================' -ForegroundColor Green
    Write-Host "ID Server       : $ServerHost"
    Write-Host "Relay Server    : $RelayServer"
    Write-Host "Public Key      : Applied"
    Write-Host 'Approval Mode   : Password'
    Write-Host 'Password Type   : Permanent password only'
    Write-Host "Service         : $($finalService.Status) / Automatic"
    Write-Host "User Config     : $userConfigPath"
    Write-Host "Service Config  : $serviceConfigPath"
    Write-Host "Password Store  : $servicePasswordConfigPath (updated)"
    if ($rustDeskId) { Write-Host "RustDesk ID     : $rustDeskId" }
    Write-Host "Log             : $LogFile"
    Write-Host "`nNOTE: The password itself is not displayed or written to the log." -ForegroundColor Yellow
}
catch {
    Write-Host "`n====================================================" -ForegroundColor Red
    Write-Host '       DEPLOYMENT FAILED' -ForegroundColor Red
    Write-Host '====================================================' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Log: $LogFile" -ForegroundColor Yellow
    if ($ServiceNameForRecovery) {
        try {
            $recoverService = Get-Service -Name $ServiceNameForRecovery -ErrorAction Stop
            if ($recoverService.Status -ne 'Running') {
                Start-Service -Name $ServiceNameForRecovery -ErrorAction Stop
                (Get-Service -Name $ServiceNameForRecovery).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                Write-Host 'RustDesk service was restarted after the failure.' -ForegroundColor Yellow
            }
        } catch {
            Write-Host "WARNING: Could not recover RustDesk service: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if ($TranscriptStarted) { Stop-Transcript | Out-Null; $TranscriptStarted = $false }
    Read-Host 'Press Enter to close'
    exit 1
}
finally {
    $PlainPassword = $null
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
}

Read-Host "`nDeployment finished. Press Enter to close"
