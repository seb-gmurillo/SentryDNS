# SentryDNS

![PowerShell](https://img.shields.io/badge/PowerShell-7+-blue)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)

SentryDNS is an adaptive DNS selection engine for Windows that continuously evaluates multiple DNS providers and automatically selects the most stable and lowest-latency resolver.

Instead of static DNS configuration or simple failover logic, SentryDNS uses statistical scoring, anomaly detection, and stability modeling to make controlled switching decisions while avoiding resolver flapping.

The result is a self-adjusting DNS controller optimized for **latency consistency and reliability**.

---

# Features

### Adaptive DNS Selection
SentryDNS continuously probes multiple DNS providers and dynamically selects the best resolver based on:

- Measured latency
- Latency variance
- Failure rate
- Stability score

The controller avoids rapid switching through configurable bias and hold intervals.

---

### Statistical Latency Modeling

SentryDNS uses a continuous-time Exponential Moving Average (EMA) model:

```
EMA_t = EMA_{t-1} + α (Latency - EMA_{t-1})
α = 1 - exp(-Δt / τ)
```

This allows the system to adapt smoothly to changing network conditions without overreacting to transient spikes.

---

### Online Variance Estimation

Latency stability is measured through an exponentially-weighted variance estimate:

```
Var_t = (1 - α) Var_{t-1} + α (Error²)
```

Variance directly influences the resolver stability score.

---

### Anomaly Detection

Latency spikes are detected using a Z-score model:

```
Z = |Error| / σ
```

When the Z-score exceeds a configurable threshold, anomaly counters are incremented and incorporated into the stability model.

---

### Composite Provider Scoring

Each provider receives a score based on weighted factors:

```
Score =
  w_latency   * EMA +
  w_variance  * variance_penalty +
  w_failure   * failure_penalty
```

The provider with the lowest score becomes the preferred resolver.

---

### Stability Index

Resolver stability is calculated from:

- Variance instability
- Failure pressure
- Anomaly frequency

This allows SentryDNS to avoid unstable providers even if their raw latency appears low.

---

### Controlled Switching

Resolver switching occurs only when:

- A better provider exists
- A configurable latency bias is exceeded
- A minimum hold interval has elapsed

This prevents oscillation between resolvers.

---

### Prometheus Metrics Endpoint

SentryDNS exposes runtime metrics via a local HTTP endpoint.

Default endpoint:

```
http://localhost:9787/
```

Metrics include:

```
sentrydns_uptime_seconds
sentrydns_switch_total
sentrydns_current_provider

sentrydns_provider_latency_ms
sentrydns_provider_variance
sentrydns_provider_failures
sentrydns_provider_stability
sentrydns_provider_backoff
```

This allows integration with Prometheus and monitoring dashboards.

---

# Installation

Run the installer as Administrator.

```
.\install.ps1
```

The installer will:

- Validate PowerShell 7
- Create the install directory
- Copy required files
- Register the HTTP metrics endpoint
- Create the Windows service
- Configure service restart policy
- Start the service

Install location:

```
C:\ProgramData\SentryDNS
```

---

# Uninstall

To completely remove SentryDNS:

```
.\uninstall.ps1
```

The uninstaller will:

- Stop the service
- Remove the Windows service
- Remove the HTTP URL ACL
- Delete installed files

---

# Configuration

Configuration is controlled through:

```
sentrydns.config.json
```

Key parameters include:

| Setting | Description |
|-------|-------------|
| probeIntervalSeconds | DNS probe interval |
| dnsTimeoutMs | DNS request timeout |
| hardFailMs | Latency threshold considered a failure |
| tauSeconds | EMA time constant |
| switchBiasMs | Minimum improvement required for switching |
| minHoldSeconds | Minimum time between switches |

Resolvers are defined in the `providers` section.

Example:

```json
{
  "name": "Cloudflare-Std",
  "v4": "1.1.1.1",
  "v6": "2606:4700:4700::1111"
}
```

---

# Repository Structure

```
SentryDNS/
│
├── SentryDNS.ps1
├── sentrydns.config.json
├── install.ps1
├── uninstall.ps1
└── README.md
```

---

# Requirements

- Windows 10 / Windows Server
- PowerShell 7+
- Administrator privileges (for installation)

---

# Design Goals

SentryDNS was designed with the following principles:

- deterministic behavior
- statistical decision making
- low resource overhead
- observable runtime state
- safe service execution
- minimal operational complexity

---

# Use Cases

SentryDNS is useful for environments where DNS latency consistency matters:

- gaming systems
- home labs
- unstable ISP routing
- latency-sensitive applications
- monitoring and observability experiments

---

# License

MIT License

---

# Author

Sebastian Garcia