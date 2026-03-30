# RFC 2544 Fleet Network Test Suite

A self-contained PowerShell script that runs RFC 2544 / RFC 6349 network performance tests against multiple hosts and generates professional HTML/PDF reports.

## What It Tests

For each host in your `hosts.txt`:

| Test | What It Measures |
|------|-----------------|
| **ICMP Ping** (56 byte + 1400 byte DF) | Latency, jitter, packet loss, MTU path |
| **TCP Upload** | Multi-stream throughput (client -> server) |
| **TCP Download** | Multi-stream throughput (server -> client) |
| **UDP Profile** | Throughput, jitter, and packet loss at multiple datagram sizes |
| **Traceroute** | Layer 3 path analysis |

## Quick Start

1. **Download** this repo (or just grab `rfc2544-test.ps1`)
2. **Get iperf3** for Windows from [iperf.fr](https://iperf.fr/iperf-download.php#windows) - place `iperf3.exe` and `cygwin1.dll` in the same folder
3. **Edit `hosts.txt`** with your target hosts (auto-created on first run)
4. **Start iperf3** on each remote host: `iperf3 -s`
5. **Run the test:**

```powershell
.\rfc2544-test.ps1 -Open
```

## hosts.txt Format

```
# One host per line: NAME | IP | PORT | NOTES
HQ-Server     | 10.0.0.1    | 5201 | Main office
Branch-1      | 10.10.1.1   | 5201 | Remote office
Switch-Cab-7  | 10.10.7.1   | 5201 | Field cabinet
```

## Command Options

```powershell
# Basic run with report auto-open
.\rfc2544-test.ps1 -Open

# Custom site name and longer tests
.\rfc2544-test.ps1 -SiteName "Production Network" -Duration 60 -Open

# Test a 2Gbps circuit
.\rfc2544-test.ps1 -UDPMbps 2000 -Parallel 8 -Open

# Quick test - skip UDP and traceroute
.\rfc2544-test.ps1 -SkipUDP -SkipTraceroute -Open

# Re-test just one host
.\rfc2544-test.ps1 -SingleHost "Branch-1" -Open
```

### All Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-HostsFile` | `hosts.txt` (same dir) | Path to host list |
| `-Duration` | `30` | Seconds per TCP test |
| `-Parallel` | `4` | Parallel TCP streams |
| `-UDPMbps` | `100` | UDP target bandwidth (Mbps) |
| `-UDPDuration` | `15` | Seconds per UDP test |
| `-PingCount` | `20` | ICMP pings per test |
| `-SiteName` | `Network Test` | Report header name |
| `-TechName` | Windows username | Technician name |
| `-Open` | off | Open report when done |
| `-SkipUDP` | off | Skip UDP tests |
| `-SkipTraceroute` | off | Skip traceroute |
| `-SingleHost` | all | Test only one host by name |

## Output

Each run creates a timestamped folder:

```
reports-20260330-140000/
  fleet-summary.html      <- Fleet overview (start here)
  fleet-results.json      <- Machine-readable results
  HQ-Server/
    report.html           <- Detailed host report
    report.pdf            <- PDF version (if Edge/Chrome available)
    results.json          <- Raw test data
  Branch-1/
    report.html
    report.pdf
    results.json
```

The fleet summary links to each individual host report.

## Requirements

- Windows 10/11 with PowerShell 5.1+
- [iperf3](https://iperf.fr/iperf-download.php#windows) (`iperf3.exe` + `cygwin1.dll`)
- iperf3 running on each target host (`iperf3 -s`)
- Microsoft Edge or Google Chrome (optional, for PDF generation)

## Troubleshooting

| Error | Fix |
|-------|-----|
| `iperf3.exe not found` | Place iperf3.exe in the same folder as the script |
| `Cannot reach <host>` | Check network connectivity and firewall |
| `unable to connect to server` | Start iperf3 on remote host: `iperf3 -s` |
| `the server is busy` | Another test is running; wait or use a different port |
| Script won't run | Run: `Set-ExecutionPolicy Bypass -Scope Process` |

## Based On

- [RFC 2544](https://tools.ietf.org/html/rfc2544) - Benchmarking Methodology for Network Interconnect Devices
- [RFC 6349](https://tools.ietf.org/html/rfc6349) - Framework for TCP Throughput Testing

> **Note:** This is a host-based test suite using iperf3. Exact RFC 2544 compliance requires dedicated test equipment. These results validate end-to-end TCP/UDP performance per RFC 6349 guidelines.

## License

MIT
