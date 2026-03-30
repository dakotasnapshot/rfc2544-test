# RFC 2544 Fleet Network Test Suite

A self-contained network performance test suite that runs RFC 2544 / RFC 6349 tests against multiple hosts and generates professional HTML/PDF reports.

**Windows (PowerShell)** and **macOS/Linux (Python)** versions included - same features, same report format.

## What It Tests

For each host in your `hosts.txt`:

| Test | What It Measures |
|------|-----------------|
| **ICMP Ping** (56 byte + 1400 byte DF) | Latency, jitter, packet loss |
| **MTU / Jumbo Frame Discovery** | Path MTU via DF-bit probes (1500 → 9000 bytes) |
| **TCP Upload** | Multi-stream throughput (client → server) |
| **TCP Download** | Multi-stream throughput (server → client) |
| **UDP Profile** | Throughput, jitter, and packet loss at multiple datagram sizes (+ 8972-byte jumbo if path supports it) |
| **Traceroute** | Layer 3 path analysis |

## Quick Start

### Windows (PowerShell)

1. Get [iperf3 for Windows](https://iperf.fr/iperf-download.php#windows) - place `iperf3.exe` and `cygwin1.dll` in the same folder
2. Run it once to create `hosts.txt`: `.\rfc2544-test.ps1`
3. Edit `hosts.txt` with your target IPs
4. Start `iperf3 -s` on each remote host
5. Run: `.\rfc2544-test.ps1 -Open`

### macOS / Linux (Python)

1. Install iperf3: `brew install iperf3` (macOS) or `sudo apt install iperf3` (Ubuntu)
2. Run it once to create `hosts.txt`: `python3 rfc2544-test.py`
3. Edit `hosts.txt` with your target IPs
4. Start `iperf3 -s` on each remote host
5. Run: `python3 rfc2544-test.py --open`

## hosts.txt Format

```
# One host per line: NAME | IP | PORT | NOTES
HQ-Server     | 10.0.0.1    | 5201 | Main office
Branch-1      | 10.10.1.1   | 5201 | Remote office
Switch-Cab-7  | 10.10.7.1   | 5201 | Field cabinet
```

## Usage

### Run Everything (One Command)

The `-Full` / `--full` flag runs a comprehensive test with aggressive settings - TCP throughput at 60s with 8 streams, UDP at 2Gbps, 30 pings, full traceroute. One command, all tests, one report:

```powershell
# Windows
.\rfc2544-test.ps1 -Full -SiteName "Production Network" -Open
```

```bash
# macOS / Linux
python3 rfc2544-test.py --full --site "Production Network" --open
```

### Individual Options

```powershell
# Windows - basic run
.\rfc2544-test.ps1 -Open

# Custom duration and streams
.\rfc2544-test.ps1 -SiteName "My Network" -Duration 60 -Parallel 8 -Open

# High-bandwidth UDP test
.\rfc2544-test.ps1 -UDPMbps 2000 -Open

# Quick test (no UDP, no traceroute)
.\rfc2544-test.ps1 -SkipUDP -SkipTraceroute -Open

# Re-test just one host
.\rfc2544-test.ps1 -SingleHost "Branch-1" -Open
```

```bash
# macOS/Linux equivalents
python3 rfc2544-test.py --open
python3 rfc2544-test.py --site "My Network" --duration 60 --parallel 8 --open
python3 rfc2544-test.py --udp-mbps 2000 --open
python3 rfc2544-test.py --skip-udp --skip-traceroute --open
python3 rfc2544-test.py --single-host "Branch-1" --open
```

### All Parameters

| PowerShell | Python | Default | Description |
|-----------|--------|---------|-------------|
| `-HostsFile` | `--hosts-file` | `hosts.txt` | Path to host list |
| `-Duration` | `--duration` | `30` | Seconds per TCP test |
| `-Parallel` | `--parallel` | `4` | Parallel TCP streams |
| `-UDPMbps` | `--udp-mbps` | `100` | UDP target bandwidth (Mbps) |
| `-UDPDuration` | `--udp-duration` | `15` | Seconds per UDP datagram test |
| `-PingCount` | `--ping-count` | `20` | ICMP pings per test |
| `-SiteName` | `--site` | `Network Test` | Report header name |
| `-TechName` | `--tech` | Current user | Technician name |
| `-Open` | `--open` | off | Open report when done |
| `-SkipUDP` | `--skip-udp` | off | Skip UDP tests |
| `-SkipTraceroute` | `--skip-traceroute` | off | Skip traceroute |
| `-SingleHost` | `--single-host` | all | Test only one host |
| `-Full` | `--full` | off | Run everything with aggressive settings |

### Full Mode Settings

When `-Full` / `--full` is used (values override defaults unless you specify them explicitly):

| Setting | Default | Full Mode |
|---------|---------|-----------|
| TCP Duration | 30s | 60s |
| Parallel Streams | 4 | 8 |
| UDP Bandwidth | 100 Mbps | 2000 Mbps |
| UDP Duration | 15s | 20s |
| Ping Count | 20 | 30 |
| UDP Tests | on | forced on |
| Traceroute | on | forced on |

## Output

Each run creates a timestamped folder:

```
reports-20260330-140000/
  fleet-summary.html      <-- Start here (links to all hosts)
  fleet-results.json      <-- Machine-readable results
  HQ-Server/
    report.html           <-- Detailed host report
    report.pdf            <-- PDF (Windows only, needs Edge/Chrome)
    results.json          <-- Raw test data
  Branch-1/
    ...
```

## Requirements

**Windows:**
- PowerShell 5.1+ (built into Windows 10/11)
- [iperf3](https://iperf.fr/iperf-download.php#windows) (`iperf3.exe` + `cygwin1.dll`)
- Edge or Chrome (optional, for PDF generation)

**macOS:**
- Python 3.6+
- iperf3 (`brew install iperf3`)

**Linux:**
- Python 3.6+
- iperf3 (`sudo apt install iperf3`)

**All platforms:** iperf3 must be running on each target host (`iperf3 -s`)

## Troubleshooting

| Error | Fix |
|-------|-----|
| `iperf3 not found` | Install it or place binary in script folder |
| `Cannot reach <host>` | Check network connectivity and firewall |
| `unable to connect to server` | Start iperf3 on remote host: `iperf3 -s` |
| `the server is busy` | Another test is running; wait or use different port |
| Script won't run (Windows) | `Set-ExecutionPolicy Bypass -Scope Process` |

## References

- [RFC 2544](https://tools.ietf.org/html/rfc2544) - Benchmarking Methodology for Network Interconnect Devices
- [RFC 6349](https://tools.ietf.org/html/rfc6349) - Framework for TCP Throughput Testing

> **Note:** This is a host-based test suite using iperf3. Exact RFC 2544 compliance requires dedicated test equipment. These results validate end-to-end TCP/UDP performance per RFC 6349 guidelines.

## License

MIT - Dakota Cole
