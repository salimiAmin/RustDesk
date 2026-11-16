
# ============================================================
# Sepidyar RustDesk - Windows x64 Automatic Installer
# Install + Self-hosted Server + Permanent Password
# ============================================================

$ErrorActionPreference = "Stop"

# ---------------- CONFIGURATION ----------------

$ServerHost = "support.sepidyar.me"

$PublicKey = "vkFECZelMETmubPjiBbGtEMhzVqEQuvSPhSLYiAJa1o="

$PermanentPassword = "P@ssw0rd"

# ------------------------------------------------

# Run as Administrator
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    if (-not $PSCommandPath) {
        throw "Save this script as a .ps1 file before running it."
    }

    Start-Process powershell.exe -Verb RunAs -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

    exit
}

try {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "       SEPIDYAR RUSTDESK SETUP" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # --------------------------------------------------------
    # 1. Find existing RustDesk installation
    # --------------------------------------------------------

    Write-Host "[1/7] Checking RustDesk installation..." -ForegroundColor Yellow

    $possiblePaths = @(
        "$env:ProgramFiles\RustDesk\rustdesk.exe",
        "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe",
        "$env:LOCALAPPDATA\Programs\RustDesk\rustdesk.exe"
    )

    $rustDeskExe = $possiblePaths |
        Where-Object { Test-Path $_ -PathType Leaf } |
        Select-Object -First 1

    # --------------------------------------------------------
    # 2. Download and install RustDesk
    # --------------------------------------------------------

    if (-not $rustDeskExe) {

        Write-Host "RustDesk not found. Downloading official version..." -ForegroundColor Yellow

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" `
            -Headers @{
                "User-Agent" = "Sepidyar-RustDesk-Installer"
            }

        $asset = $release.assets |
            Where-Object {
                $_.name -match '^rustdesk-.*-x86_64\.msi$'
            } |
            Select-Object -First 1

        if (-not $asset) {
            throw "Official Windows x64 MSI not found."
        }

        $tempDir = Join-Path $env:TEMP "SepidyarRustDeskSetup"

        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $msiPath = Join-Path $tempDir $asset.name

        Write-Host "Downloading $($release.tag_name)..." -ForegroundColor Yellow

        Invoke-WebRequest `
            -Uri $asset.browser_download_url `
            -OutFile $msiPath

        Write-Host "Installing RustDesk..." -ForegroundColor Yellow

        $install = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList "/i `"$msiPath`" /qn /norestart" `
            -Wait -PassThru

        if ($install.ExitCode -notin @(0, 3010)) {
            throw "Installation failed. Exit code: $($install.ExitCode)"
        }

        Start-Sleep -Seconds 5

        $rustDeskExe = $possiblePaths |
            Where-Object { Test-Path $_ -PathType Leaf } |
            Select-Object -First 1

        if (-not $rustDeskExe) {
            throw "RustDesk executable not found after installation."
        }

        Write-Host "RustDesk installed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "RustDesk is already installed." -ForegroundColor Green
        Write-Host "Path: $rustDeskExe"
    }

    # --------------------------------------------------------
    # 3. Find RustDesk Windows service
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "[2/7] Checking RustDesk service..." -ForegroundColor Yellow

    $service = $null

    for ($i = 0; $i -lt 20; $i++) {

        $service = Get-Service |
            Where-Object { $_.Name -match "rustdesk" } |
            Select-Object -First 1

        if ($service) {
            break
        }

        Start-Sleep -Seconds 2
    }

    if (-not $service) {
        throw "RustDesk Windows service was not found. Check the MSI installation."
    }

    $serviceInfo = Get-CimInstance Win32_Service `
        -Filter "Name='$($service.Name)'"

    Write-Host "Service: $($service.Name)" -ForegroundColor Green

    # Stop service before updating configuration
    if ($service.Status -eq "Running") {
        Stop-Service -Name $service.Name -Force
        Start-Sleep -Seconds 3
    }

    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue |
        Stop-Process -Force

    # --------------------------------------------------------
    # 4. Prepare RustDesk configuration
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "[3/7] Configuring Sepidyar server..." -ForegroundColor Yellow

    $configContent = @"
rendezvous_server = '${ServerHost}:21116'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '${ServerHost}'
relay-server = '${ServerHost}:21117'
key = '${PublicKey}'
approve-mode = 'password'
verification-method = 'use-permanent-password'
"@

    # Current Windows user configuration
    $userConfigDir = Join-Path $env:APPDATA "RustDesk\config"

    # RustDesk service profile configuration
    $serviceProfile = $null

    switch -Regex ($serviceInfo.StartName) {

        "LocalService" {
            $serviceProfile = "$env:WINDIR\ServiceProfiles\LocalService\AppData\Roaming"
        }

        "NetworkService" {
            $serviceProfile = "$env:WINDIR\ServiceProfiles\NetworkService\AppData\Roaming"
        }

        "LocalSystem|SYSTEM" {
            $serviceProfile = "$env:WINDIR\System32\config\systemprofile\AppData\Roaming"
        }
    }

    $configDirs = @($userConfigDir)

    if ($serviceProfile) {
        $configDirs += Join-Path $serviceProfile "RustDesk\config"
    }

    $configDirs = $configDirs | Select-Object -Unique

    foreach ($dir in $configDirs) {

        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $configPath = Join-Path $dir "RustDesk2.toml"

        [System.IO.File]::WriteAllText(
            $configPath,
            $configContent,
            [System.Text.UTF8Encoding]::new($false)
        )

        Write-Host "Configuration saved: $configPath" -ForegroundColor Green
    }

    # --------------------------------------------------------
    # 5. Configure Windows service
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "[4/7] Configuring Windows service..." -ForegroundColor Yellow

    Set-Service -Name $service.Name -StartupType Automatic

    Start-Service -Name $service.Name

    Start-Sleep -Seconds 5

    $service.Refresh()

    if ($service.Status -ne "Running") {
        throw "RustDesk service failed to start."
    }

    Write-Host "RustDesk service is running." -ForegroundColor Green

    # --------------------------------------------------------
    # 6. Set permanent password
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "[5/7] Setting permanent access password..." -ForegroundColor Yellow

    $passwordProcess = Start-Process `
        -FilePath $rustDeskExe `
        -ArgumentList @("--password", $PermanentPassword) `
        -Wait -PassThru -NoNewWindow

    if ($passwordProcess.ExitCode -ne 0) {
        throw "Failed to set permanent password. Exit code: $($passwordProcess.ExitCode)"
    }

    Write-Host "Permanent password command completed." -ForegroundColor Green

    # --------------------------------------------------------
    # 7. Start RustDesk client
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "[6/7] Starting RustDesk client..." -ForegroundColor Yellow

    Start-Process -FilePath $rustDeskExe

    Start-Sleep -Seconds 3

    # --------------------------------------------------------
    # Completion
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "       SETUP COMPLETED" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host ""
    Write-Host "ID Server: $ServerHost"
    Write-Host "Relay Server: $ServerHost`:21117"
    Write-Host "API Server: Not used (OSS)"
    Write-Host "Public Key: Configured"
    Write-Host "Permanent Password: Configured"
    Write-Host "Approval Mode: Password only"
    Write-Host "Verification: Permanent password only"
    Write-Host "Windows Service: Automatic"
    Write-Host ""

    Write-Host "[7/7] Please test remote connection." -ForegroundColor Cyan

    Read-Host "Press Enter to close"

}
catch {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "             SETUP ERROR" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red

    Write-Host $_.Exception.Message -ForegroundColor Red

    Read-Host "Press Enter to close"

    exit 1
}
