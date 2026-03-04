# ==========================================
# uninstall.ps1
# SentryDNS Uninstaller (Production-Grade)
# ==========================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# REQUIRE ADMIN
# -----------------------------

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Uninstaller must be run as Administrator."
}

# -----------------------------
# CONFIGURATION
# -----------------------------

$ServiceName = "SentryDNS"
$InstallRoot = "C:\ProgramData\SentryDNS"
$ConfigPath  = Join-Path $InstallRoot "sentrydns.config.json"

# -----------------------------
# STOP SERVICE (IF EXISTS)
# -----------------------------

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($service) {

    if ($service.Status -ne "Stopped") {
        Write-Host "Stopping service..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Write-Host "Removing service..."
    sc.exe delete $ServiceName | Out-Null
}
else {
    Write-Host "Service not found."
}

# -----------------------------
# REMOVE HTTP URL ACL
# -----------------------------

if (Test-Path $ConfigPath) {

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $port = $config.http.port
    $url = "http://localhost:$port/"

    $existingAcl = netsh http show urlacl | Select-String $url

    if ($existingAcl) {
        Write-Host "Removing HTTP URL ACL for $url"
        netsh http delete urlacl url=$url | Out-Null
    }
    else {
        Write-Host "HTTP URL ACL not found."
    }
}
else {
    Write-Host "Configuration not found. Skipping URL ACL removal."
}

# -----------------------------
# REMOVE INSTALL DIRECTORY
# -----------------------------

if (Test-Path $InstallRoot) {
    Write-Host "Removing install directory..."
    Remove-Item -Path $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "Install directory not found."
}

Write-Host "SentryDNS successfully uninstalled."