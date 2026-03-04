# ==========================================
# SentryDNS.ps1
# Optimized Adaptive DNS Controller
# Final Audited GitHub Edition
# ==========================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# LOAD CONFIG
# -----------------------------

$ConfigPath = Join-Path $PSScriptRoot "sentrydns.config.json"

if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# -----------------------------
# GLOBAL STATE
# -----------------------------

$ServiceStartTime = Get-Date
$StopRequested = $false
$SwitchCount = 0

$ProbeInterval = [int]$Config.network.probeIntervalSeconds
$NextProbeTime = Get-Date

# -----------------------------
# LOGGING
# -----------------------------

$LogPath = $Config.service.logPath
$LogDir = Split-Path $LogPath

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts][$Level] $Message"

    try { Add-Content -Path $LogPath -Value $line } catch {}
}

# -----------------------------
# STATE MODEL
# -----------------------------

$Providers = $Config.providers
$State = @{}

foreach ($p in $Providers) {
    $State[$p.name] = @{
        v4 = @{
            EMA = $null
            Variance = 0.0
            FailCount = 0
            Backoff = 1
            LastSampleUtc = $null
            AnomalyCount = 0
            Stability = 1.0
        }
        v6 = @{
            EMA = $null
            Variance = 0.0
            FailCount = 0
            Backoff = 1
            LastSampleUtc = $null
            AnomalyCount = 0
            Stability = 1.0
        }
    }
}

$Current = @{
    v4 = @{ Name = $null; EMA = $null; LastSwitch = [datetime]::MinValue }
    v6 = @{ Name = $null; EMA = $null; LastSwitch = [datetime]::MinValue }
}

# -----------------------------
# CONTINUOUS ALPHA
# -----------------------------

function Get-Alpha {
    param(
        [double]$DeltaSeconds,
        [double]$Tau
    )
    return 1 - [Math]::Exp(-$DeltaSeconds / $Tau)
}

# -----------------------------
# DNS PROBE
# -----------------------------

function Test-DnsLatency {
    param([string]$Server)

    try {
        $endpoint = [System.Net.IPEndPoint]::new(
            [System.Net.IPAddress]::Parse($Server), 53
        )

        $client = [System.Net.Sockets.UdpClient]::new()
        $client.Client.SendTimeout    = $Config.network.dnsTimeoutMs
        $client.Client.ReceiveTimeout = $Config.network.dnsTimeoutMs

        $query = [byte[]](0xAA,0xAA,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00)
        $query += [byte]6
        $query += [byte[]][char[]]'google'
        $query += [byte]3
        $query += [byte[]][char[]]'com'
        $query += [byte]0
        $query += [byte[]](0x00,0x01,0x00,0x01)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $client.Send($query,$query.Length,$endpoint) | Out-Null
        $null = $client.Receive([ref]$endpoint)
        $sw.Stop()
        $client.Close()

        return [double]$sw.Elapsed.TotalMilliseconds
    }
    catch {
        return $null
    }
}

# -----------------------------
# UPDATE METRICS
# -----------------------------

function Update-Metrics {
    param(
        [string]$Provider,
        [string]$Stack,
        [double]$Latency
    )

    $m = $State[$Provider][$Stack]
    $now = Get-Date

    if (-not $Latency -or $Latency -ge $Config.network.hardFailMs) {
        $m.FailCount++
        $m.Backoff = [Math]::Min($m.Backoff * 2, $Config.network.backoffCap)
        if ($m.FailCount -ge $Config.network.maxConsecutiveFails) {
            $m.EMA = $null
        }
        return
    }

    $delta = if ($m.LastSampleUtc) {
        ($now - $m.LastSampleUtc).TotalSeconds
    } else {
        $ProbeInterval
    }

    $alpha = Get-Alpha -DeltaSeconds $delta -Tau $Config.control.tauSeconds

    if (-not $m.EMA) {
        $m.EMA = $Latency
        $m.Variance = 0
    }
    else {
        $err = $Latency - $m.EMA
        $m.EMA += $alpha * $err
        $m.Variance = (1 - $alpha) * $m.Variance + $alpha * ($err * $err)

        if ($Config.anomaly.enabled -and $m.Variance -gt 0) {
            $std = [Math]::Sqrt($m.Variance)
            $z = [Math]::Abs($err) / ($std + $Config.control.epsilon)

            if ($z -ge $Config.anomaly.zThreshold) {
                $m.AnomalyCount++
            }
            elseif ($m.AnomalyCount -gt 0) {
                $m.AnomalyCount--
            }
        }
    }

    $m.FailCount = 0
    $m.Backoff = 1
    $m.LastSampleUtc = $now

    Update-Stability -Provider $Provider -Stack $Stack
}

# -----------------------------
# STABILITY INDEX
# -----------------------------

function Update-Stability {
    param(
        [string]$Provider,
        [string]$Stack
    )

    $m = $State[$Provider][$Stack]
    $w = $Config.stability.weights

    $varianceScore = [Math]::Min(1, $m.Variance / 400)
    $failureScore  = [Math]::Min(1, $m.FailCount / 5)
    $anomalyScore  = [Math]::Min(1, $m.AnomalyCount / $Config.anomaly.maxAnomalies)

    $instability =
        ($w.variance * $varianceScore) +
        ($w.failure  * $failureScore) +
        ($w.anomaly  * $anomalyScore)

    $m.Stability = 1 - $instability
}

# -----------------------------
# PROVIDER SCORING
# -----------------------------

function Measure-ProviderScore {
    param(
        [string]$Provider,
        [string]$Stack
    )

    $m = $State[$Provider][$Stack]
    if (-not $m.EMA) { return [double]::PositiveInfinity }

    $w = $Config.scoring.weights

    $variancePenalty = [Math]::Min(1, $m.Variance / 400)
    $failurePenalty  = [Math]::Min(1, $m.FailCount / 5)

    return
        ($w.latency  * $m.EMA) +
        ($w.variance * 100 * $variancePenalty) +
        ($w.failure  * 100 * $failurePenalty)
}

# -----------------------------
# HTTP METRICS
# -----------------------------

$HttpListener = $null

if ($Config.http.enabled) {
    $HttpListener = New-Object System.Net.HttpListener
    $HttpListener.Prefixes.Add("http://localhost:$($Config.http.port)/")
    $HttpListener.Start()
    Write-Log "Metrics endpoint started on port $($Config.http.port)"
}

function Invoke-MetricsRequest {
    param($Context)

    $sb = New-Object System.Text.StringBuilder
    $uptime = (Get-Date) - $ServiceStartTime

    $sb.AppendLine("sentrydns_uptime_seconds $([int]$uptime.TotalSeconds)") | Out-Null
    $sb.AppendLine("sentrydns_switch_total $SwitchCount") | Out-Null

    foreach ($stack in @("v4","v6")) {
        $cur = $Current[$stack]
        if ($cur.Name) {
            $sb.AppendLine("sentrydns_current_provider{name=`"$($cur.Name)`",stack=`"$stack`"} 1") | Out-Null
        }
    }

    foreach ($p in $Providers) {
        foreach ($stack in @("v4","v6")) {
            $m = $State[$p.name][$stack]

            if ($m.EMA) {
                $sb.AppendLine("sentrydns_provider_latency_ms{name=`"$($p.name)`",stack=`"$stack`"} $([Math]::Round($m.EMA,2))") | Out-Null
            }

            $sb.AppendLine("sentrydns_provider_variance{name=`"$($p.name)`",stack=`"$stack`"} $([Math]::Round($m.Variance,2))") | Out-Null
            $sb.AppendLine("sentrydns_provider_failures{name=`"$($p.name)`",stack=`"$stack`"} $($m.FailCount)") | Out-Null
            $sb.AppendLine("sentrydns_provider_stability{name=`"$($p.name)`",stack=`"$stack`"} $([Math]::Round($m.Stability,3))") | Out-Null
            $sb.AppendLine("sentrydns_provider_backoff{name=`"$($p.name)`",stack=`"$stack`"} $($m.Backoff)") | Out-Null
        }
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $Context.Response.Close()
}

# -----------------------------
# MAIN LOOP
# -----------------------------

Register-EngineEvent PowerShell.Exiting -Action {
    $global:StopRequested = $true
}

Write-Log "SentryDNS started."

while (-not $StopRequested) {

    $now = Get-Date

    try {

        # Handle metrics
        if ($HttpListener -and $HttpListener.IsListening -and $HttpListener.Pending()) {
            $ctx = $HttpListener.GetContext()
            Invoke-MetricsRequest -Context $ctx
        }

        # Time-based probing
        if ($now -ge $NextProbeTime) {

            $route = Get-NetRoute -DestinationPrefix 0.0.0.0/0 |
                Sort-Object RouteMetric |
                Select-Object -First 1

            if ($route) {

                foreach ($p in $Providers) {
                    foreach ($stack in @("v4","v6")) {

                        $m = $State[$p.name][$stack]

                        if ((Get-Random -Minimum 0 -Maximum $m.Backoff) -ne 0) {
                            continue
                        }

                        $lat = Test-DnsLatency $p.$stack
                        Update-Metrics -Provider $p.name -Stack $stack -Latency $lat
                    }
                }

                foreach ($stack in @("v4","v6")) {

                    $bestScore = [double]::PositiveInfinity
                    $bestProvider = $null

                    foreach ($p in $Providers) {
                        $score = Measure-ProviderScore -Provider $p.name -Stack $stack
                        if ($score -lt $bestScore) {
                            $bestScore = $score
                            $bestProvider = $p
                        }
                    }

                    if ($bestProvider) {

                        $cur = $Current[$stack]
                        $elapsed = ((Get-Date) - $cur.LastSwitch).TotalSeconds
                        $bestEMA = $State[$bestProvider.name][$stack].EMA

                        if (-not $cur.Name -or
                            ($elapsed -ge $Config.network.minHoldSeconds -and
                            ($bestEMA + $Config.control.switchBiasMs) -lt $cur.EMA)) {

                            Set-DnsClientServerAddress `
                                -InterfaceIndex $route.InterfaceIndex `
                                -ServerAddresses @($bestProvider.$stack)

                            $Current[$stack] = @{
                                Name       = $bestProvider.name
                                EMA        = $bestEMA
                                LastSwitch = Get-Date
                            }

                            $SwitchCount++
                            Write-Log "SWITCH [$stack] -> $($bestProvider.name)"
                        }
                    }
                }
            }

            $NextProbeTime = $now.AddSeconds($ProbeInterval)
        }

    }
    catch {
        Write-Log "Main loop error: $_" "ERROR"
    }

    Start-Sleep -Milliseconds 200
}

Write-Log "SentryDNS stopped."