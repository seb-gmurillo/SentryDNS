# ==========================================
# install.ps1
# SentryDNS Installer (Production-Grade)
# ==========================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# REQUIRE ADMIN
# -----------------------------

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Installer must be run as Administrator."
}

# -----------------------------
# CONFIGURATION
# -----------------------------

$ServiceName = "SentryDNS"
$InstallRoot = "C:\ProgramData\SentryDNS"
$SourceRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoreSource  = Join-Path $SourceRoot "SentryDNS.ps1"
$ConfigSource = Join-Path $SourceRoot "sentrydns.config.json"
$CoreTarget  = Join-Path $InstallRoot "SentryDNS.ps1"
$ConfigTarget = Join-Path $InstallRoot "sentrydns.config.json"

# -----------------------------
# VALIDATE FILES
# -----------------------------

if (-not (Test-Path $CoreSource)) {
    throw "SentryDNS.ps1 not found in source directory."
}

if (-not (Test-Path $ConfigSource)) {
    throw "sentrydns.config.json not found in source directory."
}

# -----------------------------
# RESOLVE POWERSHELL 7
# -----------------------------

$pwshCommand = Get-Command pwsh -ErrorAction Stop
$PwshPath = $pwshCommand.Source

$pwshVersion = & $PwshPath -NoProfile -Command '$PSVersionTable.PSVersion.Major'

if ($pwshVersion -lt 7) {
    throw "PowerShell 7 or greater is required."
}

Write-Host "Using PowerShell: $PwshPath"

# -----------------------------
# CREATE INSTALL DIRECTORY
# -----------------------------

if (-not (Test-Path $InstallRoot)) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
}

# -----------------------------
# COPY FILES
# -----------------------------

Copy-Item -Path $CoreSource -Destination $CoreTarget -Force
Copy-Item -Path $ConfigSource -Destination $ConfigTarget -Force

Write-Host "Files copied to $InstallRoot"

# -----------------------------
# REGISTER HTTP URL ACL
# -----------------------------

$config = Get-Content $ConfigTarget -Raw | ConvertFrom-Json
$port = $config.http.port
$url = "http://localhost:$port/"

$existingAcl = netsh http show urlacl | Select-String $url

if (-not $existingAcl) {
    Write-Host "Registering HTTP URL ACL for $url"
    netsh http add urlacl url=$url user=Everyone | Out-Null
}
else {
    Write-Host "HTTP URL ACL already exists."
}

# -----------------------------
# REMOVE EXISTING SERVICE
# -----------------------------

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($existingService) {

    Write-Host "Stopping existing service..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

    Write-Host "Removing existing service..."
    sc.exe delete $ServiceName | Out-Null

    Start-Sleep -Seconds 2
}

# -----------------------------
# CREATE SERVICE
# -----------------------------

$BinaryPath = "`"$PwshPath`" -NoProfile -ExecutionPolicy Bypass -File `"$CoreTarget`""

New-Service `
    -Name $ServiceName `
    -BinaryPathName $BinaryPath `
    -DisplayName "SentryDNS Adaptive DNS Controller" `
    -Description "Adaptive DNS selection engine with statistical scoring." `
    -StartupType AutomaticDelayedStart

Write-Host "Service created."

# -----------------------------
# CONFIGURE RECOVERY
# -----------------------------

sc.exe failure $ServiceName reset=86400 actions=restart/5000/restart/5000/restart/10000 | Out-Null

Write-Host "Recovery policy configured."

# -----------------------------
# START SERVICE
# -----------------------------

Start-Service -Name $ServiceName

Write-Host "SentryDNS installation complete."