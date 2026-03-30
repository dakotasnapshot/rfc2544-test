<#
.SYNOPSIS
    RFC 2544 / RFC 6349 Fleet Network Performance Test Suite (Self-Contained)
    Tests all hosts in hosts.txt and generates individual + fleet summary reports.

    Author: Dakota Cole
    License: MIT

.DESCRIPTION
    Reads hosts.txt from the same directory, runs iperf3/ping/tracert tests against
    each host, and generates HTML/PDF reports. No external scripts required.

    Place iperf3.exe (+ cygwin1.dll if needed) in the same folder as this script.

.PARAMETER HostsFile
    Path to hosts config file. Default: hosts.txt in script directory.

.PARAMETER Duration
    iperf3 test duration per host in seconds. Default: 30

.PARAMETER Parallel
    Parallel TCP streams. Default: 4

.PARAMETER UDPMbps
    UDP target bandwidth in Mbps. Default: 100

.PARAMETER UDPDuration
    UDP test duration per datagram size in seconds. Default: 15

.PARAMETER PingCount
    ICMP ping count per test. Default: 20

.PARAMETER SiteName
    Site/project name for report headers.

.PARAMETER TechName
    Technician name. Default: current Windows username.

.PARAMETER Open
    Open fleet summary report when done.

.PARAMETER SkipUDP
    Skip all UDP tests (faster).

.PARAMETER SkipTraceroute
    Skip traceroute tests.

.PARAMETER SingleHost
    Test only one host by name (from hosts.txt). Useful for re-testing a single node.

.PARAMETER Full
    Run a comprehensive test with aggressive settings: 60s TCP, 8 streams, 2Gbps UDP,
    30 pings, full UDP + traceroute. One command, everything in one report.

.EXAMPLE
    .\rfc2544-test.ps1 -Open
    .\rfc2544-test.ps1 -SiteName "My Network" -Duration 60 -Open
    .\rfc2544-test.ps1 -SingleHost "Branch-1" -Open
    .\rfc2544-test.ps1 -Full -SiteName "Production Network" -Open
#>

param(
    [string]$HostsFile = "",
    [int]$Duration = 30,
    [int]$Parallel = 4,
    [int]$UDPMbps = 100,
    [int]$UDPDuration = 15,
    [int]$PingCount = 20,
    [string]$SiteName = "Network Test",
    [string]$TechName = $env:USERNAME,
    [switch]$Open,
    [switch]$SkipUDP,
    [switch]$SkipTraceroute,
    [switch]$Full,
    [string]$SingleHost = ""
)

# -- Full mode overrides --
if ($Full) {
    if ($Duration -eq 30) { $Duration = 60 }
    if ($Parallel -eq 4) { $Parallel = 8 }
    if ($UDPMbps -eq 100) { $UDPMbps = 2000 }
    if ($UDPDuration -eq 15) { $UDPDuration = 20 }
    if ($PingCount -eq 20) { $PingCount = 30 }
    $SkipUDP = $false
    $SkipTraceroute = $false
}

$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = Get-Location }
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$fleetDir = Join-Path $scriptDir "reports-$timestamp"

# ============================================================
# Find iperf3
# ============================================================
$iperf3 = $null
$candidates = @(
    (Join-Path $scriptDir "iperf3.exe"),
    (Get-Command iperf3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    "C:\iperf3\iperf3.exe",
    "C:\Program Files\iperf3\iperf3.exe",
    "C:\tools\iperf3\iperf3.exe"
)
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c -ErrorAction SilentlyContinue)) {
        $iperf3 = $c; break
    }
}
if (-not $iperf3) {
    Write-Host ""
    Write-Host "[ERROR] iperf3.exe not found!" -ForegroundColor Red
    Write-Host "  Place iperf3.exe in the same folder as this script:" -ForegroundColor Yellow
    Write-Host "  $scriptDir" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Download: https://iperf.fr/iperf-download.php#windows" -ForegroundColor Yellow
    Write-Host "  Extract iperf3.exe and cygwin1.dll into this folder." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# ============================================================
# Parse hosts.txt
# ============================================================
if (-not $HostsFile) { $HostsFile = Join-Path $scriptDir "hosts.txt" }

if (-not (Test-Path $HostsFile)) {
    Write-Host ""
    Write-Host "[INFO] No hosts.txt found. Creating sample file..." -ForegroundColor Yellow
    
    $sample = @"
# ============================================================
# RFC 2544 Fleet Test - Host Configuration
# ============================================================
#
# FORMAT:  NAME | IP_ADDRESS | PORT | NOTES
#
# - One host per line
# - Lines starting with # are comments
# - PORT is the iperf3 port (usually 5201)
# - Each host must be running: iperf3 -s -p PORT
#
# EXAMPLE SETUP:
#   1. Copy this folder to your test laptop
#   2. Edit hosts.txt with your target IPs
#   3. Start iperf3 -s on each remote host
#   4. Run: .\rfc2544-fleet-standalone.ps1 -Open
#
# ============================================================

# --- Example hosts (edit these!) ---
HQ-Server     | 10.0.0.1    | 5201 | Main office iperf3 server
Hut-14        | 10.10.14.1  | 5201 | Stillwater fiber hut
Hut-22        | 10.10.22.1  | 5201 | Perkins fiber hut
Cabinet-7     | 10.10.7.1   | 5201 | Yale Rd cabinet
"@
    $sample | Out-File -FilePath $HostsFile -Encoding ASCII
    Write-Host "  Created: $HostsFile" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Edit hosts.txt with your target IPs, then re-run this script." -ForegroundColor White
    Write-Host ""
    exit 0
}

$hosts = @()
Get-Content $HostsFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { return }
    
    $parts = $line -split "\|" | ForEach-Object { $_.Trim() }
    if ($parts.Count -lt 3) {
        Write-Host "[WARN] Skipping malformed line: $line" -ForegroundColor Yellow
        return
    }
    
    $entry = @{
        Name  = $parts[0]
        IP    = $parts[1]
        Port  = [int]$parts[2]
        Notes = if ($parts.Count -ge 4) { $parts[3] } else { "" }
    }
    
    # Filter to single host if specified
    if ($SingleHost -and $entry.Name -ne $SingleHost) { return }
    
    $hosts += $entry
}

if ($hosts.Count -eq 0) {
    if ($SingleHost) {
        Write-Host "[ERROR] Host '$SingleHost' not found in $HostsFile" -ForegroundColor Red
    } else {
        Write-Host "[ERROR] No hosts found in $HostsFile" -ForegroundColor Red
    }
    exit 1
}

# ============================================================
# Core Test Functions
# ============================================================
function Run-Iperf3Test {
    param([string[]]$Arguments, [int]$Timeout = 240, [string]$TmpDir = ".")
    try {
        $stdoutFile = Join-Path $TmpDir "iperf_stdout.tmp"
        $stderrFile = Join-Path $TmpDir "iperf_stderr.tmp"
        $proc = Start-Process -FilePath $iperf3 -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $finished = $proc.WaitForExit($Timeout * 1000)
        if (-not $finished) { 
            $proc.Kill()
            return @{ Success = $false; Error = "Timeout after ${Timeout}s" }
        }
        $stdout = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
        Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        
        if ($Arguments -contains "-J") {
            try {
                $json = $stdout | ConvertFrom-Json
                if ($json.error) {
                    return @{ Success = $false; Error = $json.error }
                }
                return @{ Success = $true; Data = $json }
            } catch {
                return @{ Success = $false; Error = "JSON parse failed" }
            }
        }
        return @{ Success = $true; Raw = $stdout }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Get-TcpSummary($data, [bool]$Reverse = $false) {
    try {
        $end = $data.end
        $sum = if ($Reverse) {
            if ($end.sum_received) { $end.sum_received } else { $end.sum }
        } else {
            if ($end.sum_sent) { $end.sum_sent } else { $end.sum }
        }
        return @{
            Mbps = [math]::Round([double]$sum.bits_per_second / 1e6, 2)
            Bytes = [long]$sum.bytes
            Retransmits = if ($sum.retransmits) { [int]$sum.retransmits } else { 0 }
        }
    } catch { return @{ Mbps = $null; Bytes = 0; Retransmits = 0; Error = "Parse failed" } }
}

function Get-UdpSummary($data) {
    try {
        $sum = $data.end.sum
        return @{
            Mbps = [math]::Round([double]$sum.bits_per_second / 1e6, 2)
            JitterMs = [math]::Round([double]$sum.jitter_ms, 3)
            LostPackets = [int]$sum.lost_packets
            TotalPackets = [int]$sum.packets
            LossPercent = [math]::Round([double]$sum.lost_percent, 2)
        }
    } catch { return $null }
}

function Run-PingTest {
    param([string]$TargetHost, [int]$Count = 20, [int]$Size = 32, [switch]$DontFragment)
    $result = Test-Connection -ComputerName $TargetHost -Count $Count -BufferSize $Size -ErrorAction SilentlyContinue
    if ($result) {
        $stats = $result | Measure-Object -Property ResponseTime -Average -Minimum -Maximum
        return @{
            Success = $true
            Count = $result.Count
            Sent = $Count
            LossPercent = [math]::Round(($Count - $result.Count) / $Count * 100, 1)
            AvgMs = [math]::Round($stats.Average, 1)
            MinMs = [math]::Round($stats.Minimum, 1)
            MaxMs = [math]::Round($stats.Maximum, 1)
        }
    }
    return @{ Success = $false; Count = 0; Sent = $Count; LossPercent = 100; AvgMs = 0; MinMs = 0; MaxMs = 0 }
}

# ============================================================
# Banner
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  RFC 2544 Fleet Network Performance Test" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Site:       $SiteName"
Write-Host "  Hosts:      $($hosts.Count) $(if($SingleHost){"(filtered: $SingleHost)"})"
Write-Host "  Config:     $HostsFile"
Write-Host "  Duration:   ${Duration}s per test | Streams: $Parallel"
Write-Host "  UDP:        $(if($SkipUDP){'SKIPPED'}else{"${UDPMbps}M target, ${UDPDuration}s"})"
Write-Host "  Tech:       $TechName"
Write-Host "  iperf3:     $iperf3"
Write-Host "  Output:     $fleetDir"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Path $fleetDir -Force | Out-Null

# ============================================================
# Test Each Host
# ============================================================
$fleetResults = @()
$hostNum = 0

foreach ($h in $hosts) {
    $hostNum++
    $hName = $h.Name
    $hIP = $h.IP
    $hPort = $h.Port
    $hostDir = Join-Path $fleetDir $hName
    New-Item -ItemType Directory -Path $hostDir -Force | Out-Null
    
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  [$hostNum/$($hosts.Count)] $hName - $hIP`:$hPort" -ForegroundColor Cyan
    if ($h.Notes) { Write-Host "  $($h.Notes)" -ForegroundColor DarkGray }
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    
    # -- Connectivity Check --
    Write-Host "  [..] Checking connectivity..." -NoNewline
    $quickPing = Test-Connection -ComputerName $hIP -Count 2 -ErrorAction SilentlyContinue
    if (-not $quickPing) {
        Write-Host "`r  [FAIL] Cannot reach $hIP - SKIPPED" -ForegroundColor Red
        $fleetResults += @{
            Name = $hName; IP = $hIP; Port = $hPort; Notes = $h.Notes
            Status = "UNREACHABLE"
            TcpUp = $null; TcpDown = $null; UpRetrans = $null; DnRetrans = $null
            PingAvg = $null; PingLoss = $null
            UdpBest = $null; UdpJitter = $null; UdpLoss = $null
        }
        continue
    }
    $quickLatency = ($quickPing | Measure-Object -Property ResponseTime -Average).Average
    Write-Host "`r  [OK] Reachable (${quickLatency}ms)        " -ForegroundColor Green
    
    $result = @{}
    
    # -- Ping Tests --
    Write-Host "  [..] Ping test (small)..." -NoNewline
    $pingSmall = Run-PingTest -TargetHost $hIP -Count $PingCount -Size 56
    Write-Host "`r  [OK] Ping: $($pingSmall.AvgMs)ms avg, $($pingSmall.LossPercent)% loss        " -ForegroundColor Green
    $result["PingSmall"] = $pingSmall
    
    Write-Host "  [..] Ping test (1400 byte, DF)..." -NoNewline
    $pingLarge = Run-PingTest -TargetHost $hIP -Count $PingCount -Size 1400 -DontFragment
    Write-Host "`r  [OK] Ping DF: $($pingLarge.AvgMs)ms avg, $($pingLarge.LossPercent)% loss        " -ForegroundColor Green
    $result["PingLarge"] = $pingLarge
    
    # -- Traceroute --
    if (-not $SkipTraceroute) {
        Write-Host "  [..] Traceroute..." -NoNewline
        try {
            $trOutput = tracert -d -w 3000 $hIP 2>&1 | Out-String
            $result["Traceroute"] = $trOutput
            $hopCount = ($trOutput -split "`n" | Where-Object { $_ -match "^\s+\d+" }).Count
            Write-Host "`r  [OK] Traceroute: $hopCount hops        " -ForegroundColor Green
        } catch {
            $result["Traceroute"] = "Failed: $($_.Exception.Message)"
            Write-Host "`r  [WARN] Traceroute failed        " -ForegroundColor Yellow
        }
    }
    
    # -- TCP Upload --
    Write-Host "  [..] TCP Upload ($Parallel streams, ${Duration}s)..." -NoNewline
    $tcpUp = Run-Iperf3Test -Arguments @("-J", "-c", $hIP, "-p", "$hPort", "-t", "$Duration", "-P", "$Parallel") -Timeout ($Duration + 30) -TmpDir $hostDir
    $upSummary = if ($tcpUp.Success) { Get-TcpSummary $tcpUp.Data -Reverse $false } else { @{ Mbps = $null; Retransmits = 0; Error = $tcpUp.Error } }
    $result["TcpUpload"] = $upSummary
    if ($upSummary.Mbps) {
        Write-Host "`r  [OK] TCP Up: $($upSummary.Mbps) Mbps ($($upSummary.Retransmits) retrans)        " -ForegroundColor Green
    } else {
        Write-Host "`r  [FAIL] TCP Up: $($upSummary.Error)        " -ForegroundColor Red
    }
    
    # -- TCP Download --
    Write-Host "  [..] TCP Download ($Parallel streams, ${Duration}s)..." -NoNewline
    $tcpDn = Run-Iperf3Test -Arguments @("-J", "-c", $hIP, "-p", "$hPort", "-t", "$Duration", "-P", "$Parallel", "-R") -Timeout ($Duration + 30) -TmpDir $hostDir
    $dnSummary = if ($tcpDn.Success) { Get-TcpSummary $tcpDn.Data -Reverse $true } else { @{ Mbps = $null; Retransmits = 0; Error = $tcpDn.Error } }
    $result["TcpDownload"] = $dnSummary
    if ($dnSummary.Mbps) {
        Write-Host "`r  [OK] TCP Dn: $($dnSummary.Mbps) Mbps ($($dnSummary.Retransmits) retrans)        " -ForegroundColor Green
    } else {
        Write-Host "`r  [FAIL] TCP Dn: $($dnSummary.Error)        " -ForegroundColor Red
    }
    
    # -- UDP Profile --
    $udpResults = @()
    $udpBest = $null
    if (-not $SkipUDP) {
        $udpLens = @(64, 256, 512, 1024, 1470)
        foreach ($dlen in $udpLens) {
            Write-Host "  [..] UDP len=$dlen..." -NoNewline
            $udpRun = Run-Iperf3Test -Arguments @("-J", "-u", "-c", $hIP, "-p", "$hPort", "-t", "$UDPDuration", "-b", "${UDPMbps}M", "--len", "$dlen") -Timeout ($UDPDuration + 30) -TmpDir $hostDir
            if ($udpRun.Success) {
                $us = Get-UdpSummary $udpRun.Data
                if ($us) {
                    $us["DataLen"] = $dlen
                    $udpResults += $us
                    $lossColor = if ($us.LossPercent -gt 1) { "Red" } elseif ($us.LossPercent -gt 0) { "Yellow" } else { "Green" }
                    Write-Host "`r  [OK] UDP $dlen`: $($us.Mbps)Mbps, jitter $($us.JitterMs)ms, loss $($us.LossPercent)%        " -ForegroundColor $lossColor
                    if ((-not $udpBest) -or ($us.Mbps -gt $udpBest.Mbps -and $us.LossPercent -le 1)) {
                        $udpBest = $us
                    }
                }
            } else {
                Write-Host "`r  [FAIL] UDP $dlen`: $($udpRun.Error)        " -ForegroundColor Red
            }
        }
    }
    $result["UDP"] = $udpResults
    $result["UDPBest"] = $udpBest
    
    # -- Save per-host JSON --
    $result | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $hostDir "results.json") -Encoding UTF8
    
    # -- Generate per-host HTML --
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    
    $udpRowsHtml = ""
    foreach ($u in $udpResults) {
        $lc = if ($u.LossPercent -gt 1) { "color:red;font-weight:bold" } elseif ($u.LossPercent -gt 0) { "color:orange" } else { "color:green" }
        $udpRowsHtml += "<tr><td>$($u.DataLen) bytes</td><td>$($u.Mbps) Mbps</td><td>$($u.JitterMs) ms</td><td>$($u.LostPackets)</td><td>$($u.TotalPackets)</td><td style='$lc'>$($u.LossPercent)%</td></tr>"
    }
    
    $traceHtml = ""
    if ($result["Traceroute"]) {
        try { $trEncoded = [System.Web.HttpUtility]::HtmlEncode($result["Traceroute"]) } catch { $trEncoded = $result["Traceroute"] }
        $traceHtml = "<h2>Traceroute</h2><pre>$trEncoded</pre>"
    }
    
    $hostHtml = @"
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body { font-family: 'Segoe UI', Tahoma, Arial, sans-serif; color: #333; font-size: 10pt; margin: 0; padding: 20px; }
.hdr { background: linear-gradient(135deg, #1a5276, #2e86c1); color: white; padding: 18px 24px; margin: -20px -20px 16px -20px; }
.hdr h1 { margin: 0; font-size: 18pt; }
.hdr .sub { font-size: 9pt; opacity: 0.8; }
.hdr .brand { float: right; font-size: 9pt; opacity: 0.7; }
.grid { display: flex; gap: 8px; flex-wrap: wrap; margin: 10px 0; }
.box { background: #f8f9fa; border: 1px solid #dee2e6; border-radius: 5px; padding: 8px 12px; flex: 1; min-width: 120px; }
.box .lbl { font-size: 7pt; text-transform: uppercase; color: #6c757d; font-weight: 600; }
.box .val { font-size: 11pt; font-weight: 600; margin-top: 2px; }
table { width: 100%; border-collapse: collapse; margin: 10px 0; font-size: 9pt; }
th { background: #1a5276; color: white; padding: 7px 10px; text-align: left; }
td { padding: 6px 10px; border-bottom: 1px solid #dee2e6; }
tr:nth-child(even) { background: #f8f9fa; }
h2 { color: #1a5276; border-bottom: 2px solid #2e86c1; padding-bottom: 4px; margin: 18px 0 8px; font-size: 12pt; }
pre { background: #f7f7f9; padding: 8px; border: 1px solid #eee; font-size: 8pt; overflow-x: auto; white-space: pre-wrap; }
.ft { margin-top: 20px; border-top: 1px solid #dee2e6; padding-top: 8px; font-size: 7pt; color: #999; text-align: center; }
</style></head><body>
<div class="hdr">
  <div class="brand">RFC2544 Test Suite</div>
  <h1>$hName - Performance Report</h1>
  <div class="sub">RFC 2544 / RFC 6349 -- $SiteName</div>
</div>
<div class="grid">
  <div class="box"><div class="lbl">Host</div><div class="val">$hIP`:$hPort</div></div>
  <div class="box"><div class="lbl">Date</div><div class="val">$reportDate</div></div>
  <div class="box"><div class="lbl">Technician</div><div class="val">$TechName</div></div>
  <div class="box"><div class="lbl">Test From</div><div class="val">$env:COMPUTERNAME</div></div>
  $(if($h.Notes){"<div class='box'><div class='lbl'>Notes</div><div class='val'>$($h.Notes)</div></div>"})
</div>
<h2>TCP Throughput</h2>
<table>
<tr><th>Direction</th><th>Throughput</th><th>Retransmits</th><th>Duration</th><th>Streams</th></tr>
<tr><td>Upload (Client -> Host)</td><td><strong>$(if($upSummary.Mbps){"$($upSummary.Mbps) Mbps"}else{"FAILED"})</strong></td><td>$($upSummary.Retransmits)</td><td>${Duration}s</td><td>$Parallel</td></tr>
<tr><td>Download (Host -> Client)</td><td><strong>$(if($dnSummary.Mbps){"$($dnSummary.Mbps) Mbps"}else{"FAILED"})</strong></td><td>$($dnSummary.Retransmits)</td><td>${Duration}s</td><td>$Parallel</td></tr>
</table>
<h2>Latency (ICMP)</h2>
<table>
<tr><th>Test</th><th>Avg</th><th>Min</th><th>Max</th><th>Loss</th><th>Packets</th></tr>
<tr><td>56 byte</td><td>$($pingSmall.AvgMs) ms</td><td>$($pingSmall.MinMs) ms</td><td>$($pingSmall.MaxMs) ms</td><td>$($pingSmall.LossPercent)%</td><td>$($pingSmall.Count)/$($pingSmall.Sent)</td></tr>
<tr><td>1400 byte (DF)</td><td>$($pingLarge.AvgMs) ms</td><td>$($pingLarge.MinMs) ms</td><td>$($pingLarge.MaxMs) ms</td><td>$($pingLarge.LossPercent)%</td><td>$($pingLarge.Count)/$($pingLarge.Sent)</td></tr>
</table>
$(if($udpResults.Count -gt 0){"<h2>UDP Frame Loss and Jitter</h2><table><tr><th>Datagram</th><th>Throughput</th><th>Jitter</th><th>Lost</th><th>Total</th><th>Loss %</th></tr>$udpRowsHtml</table>"})
$traceHtml
<div class="ft">RFC2544 Test Suite RFC 2544 Test Suite -- $reportDate -- $env:COMPUTERNAME</div>
</body></html>
"@
    $hostHtml | Out-File -FilePath (Join-Path $hostDir "report.html") -Encoding UTF8
    
    # -- Try PDF --
    $browser = $null
    if (Test-Path "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe") { $browser = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" }
    elseif (Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe") { $browser = "C:\Program Files\Google\Chrome\Application\chrome.exe" }
    if ($browser) {
        $absH = (Resolve-Path (Join-Path $hostDir "report.html")).Path
        $absP = Join-Path (Resolve-Path $hostDir).Path "report.pdf"
        & $browser --headless --disable-gpu --no-sandbox --print-to-pdf="$absP" "file:///$($absH.Replace('\','/'))" 2>$null
        Start-Sleep -Seconds 2
    }
    
    # -- Collect fleet result --
    $fleetResults += @{
        Name = $hName; IP = $hIP; Port = $hPort; Notes = $h.Notes
        Status = "OK"
        TcpUp = $upSummary.Mbps; TcpDown = $dnSummary.Mbps
        UpRetrans = $upSummary.Retransmits; DnRetrans = $dnSummary.Retransmits
        PingAvg = $pingSmall.AvgMs; PingLoss = $pingSmall.LossPercent
        UdpBest = if ($udpBest) { $udpBest.Mbps } else { $null }
        UdpJitter = if ($udpBest) { $udpBest.JitterMs } else { $null }
        UdpLoss = if ($udpBest) { $udpBest.LossPercent } else { $null }
    }
}

# ============================================================
# Fleet Summary
# ============================================================
$okCount = ($fleetResults | Where-Object { $_.Status -eq "OK" }).Count
$failCount = ($fleetResults | Where-Object { $_.Status -ne "OK" }).Count

$summaryRows = ""
foreach ($r in $fleetResults) {
    $sc = if ($r.Status -eq "OK") { "color:green" } else { "color:red" }
    $upStr = if ($r.TcpUp) { "{0:N2}" -f $r.TcpUp } else { "-" }
    $dnStr = if ($r.TcpDown) { "{0:N2}" -f $r.TcpDown } else { "-" }
    $pingStr = if ($r.PingAvg) { "$($r.PingAvg)ms" } else { "-" }
    $udpStr = if ($r.UdpBest) { "$($r.UdpBest)Mbps" } else { "-" }
    $jitStr = if ($r.UdpJitter) { "$($r.UdpJitter)ms" } else { "-" }
    $linkStr = if (Test-Path (Join-Path $fleetDir "$($r.Name)\report.html") -ErrorAction SilentlyContinue) {
        "<a href='$($r.Name)/report.html'>View</a>"
    } else { "-" }
    
    $summaryRows += "<tr><td><strong>$($r.Name)</strong></td><td>$($r.IP):$($r.Port)</td>"
    $summaryRows += "<td style='$sc;font-weight:bold'>$($r.Status)</td>"
    $summaryRows += "<td>$upStr</td><td>$dnStr</td>"
    $summaryRows += "<td>$($r.UpRetrans) / $($r.DnRetrans)</td>"
    $summaryRows += "<td>$pingStr</td><td>$($r.PingLoss)%</td>"
    $summaryRows += "<td>$udpStr</td><td>$jitStr</td>"
    $summaryRows += "<td>$($r.Notes)</td><td>$linkStr</td></tr>"
}

$fleetHtml = @"
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body { font-family: 'Segoe UI', Tahoma, Arial, sans-serif; color: #333; font-size: 10pt; margin: 0; padding: 20px; }
.hdr { background: linear-gradient(135deg, #1a5276, #2e86c1); color: white; padding: 18px 24px; margin: -20px -20px 16px -20px; }
.hdr h1 { margin: 0; font-size: 20pt; }
.hdr .sub { font-size: 9pt; opacity: 0.8; }
.hdr .brand { float: right; font-size: 9pt; opacity: 0.7; }
.stats { display: flex; gap: 10px; margin: 14px 0; }
.stat { background: #f8f9fa; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px 18px; text-align: center; flex: 1; }
.stat .num { font-size: 22pt; font-weight: 700; }
.stat .lbl { font-size: 8pt; text-transform: uppercase; color: #6c757d; }
.stat.ok .num { color: #28a745; }
.stat.fail .num { color: #dc3545; }
table { width: 100%; border-collapse: collapse; margin: 12px 0; font-size: 9pt; }
th { background: #1a5276; color: white; padding: 7px 8px; text-align: left; font-size: 8pt; }
td { padding: 6px 8px; border-bottom: 1px solid #dee2e6; }
tr:nth-child(even) { background: #f8f9fa; }
a { color: #2e86c1; }
.ft { margin-top: 20px; border-top: 1px solid #dee2e6; padding-top: 8px; font-size: 7pt; color: #999; text-align: center; }
</style></head><body>
<div class="hdr">
  <div class="brand">RFC2544 Test Suite<br/></div>
  <h1>Fleet Performance Summary</h1>
  <div class="sub">$SiteName -- $reportDate</div>
</div>
<div class="stats">
  <div class="stat"><div class="num">$($hosts.Count)</div><div class="lbl">Total Hosts</div></div>
  <div class="stat ok"><div class="num">$okCount</div><div class="lbl">Passed</div></div>
  <div class="stat fail"><div class="num">$failCount</div><div class="lbl">Failed</div></div>
  <div class="stat"><div class="num">$TechName</div><div class="lbl">Technician</div></div>
</div>
<table>
<tr><th>Name</th><th>Endpoint</th><th>Status</th><th>TCP Up<br/>(Mbps)</th><th>TCP Down<br/>(Mbps)</th><th>Retrans<br/>(Up/Dn)</th><th>Ping<br/>Avg</th><th>Ping<br/>Loss</th><th>UDP<br/>Best</th><th>UDP<br/>Jitter</th><th>Notes</th><th>Report</th></tr>
$summaryRows
</table>
<div class="ft">RFC2544 Test Suite RFC 2544 Fleet Test v1.0 -- $reportDate -- $env:COMPUTERNAME</div>
</body></html>
"@

$fleetHtmlPath = Join-Path $fleetDir "fleet-summary.html"
$fleetHtml | Out-File -FilePath $fleetHtmlPath -Encoding UTF8
$fleetResults | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $fleetDir "fleet-results.json") -Encoding UTF8

# ============================================================
# Console Summary
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  FLEET TEST COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Hosts: $($hosts.Count) tested | $okCount passed | $failCount failed"
Write-Host ""
foreach ($r in $fleetResults) {
    $icon = if ($r.Status -eq "OK") { "PASS" } else { "FAIL" }
    $color = if ($r.Status -eq "OK") { "Green" } else { "Red" }
    $upStr = if ($r.TcpUp) { "{0:N0}M" -f $r.TcpUp } else { "---" }
    $dnStr = if ($r.TcpDown) { "{0:N0}M" -f $r.TcpDown } else { "---" }
    Write-Host ("  [{0}] {1,-20} Up: {2,8}  Dn: {3,8}  Ping: {4}ms" -f $icon, $r.Name, $upStr, $dnStr, $r.PingAvg) -ForegroundColor $color
}
Write-Host ""
Write-Host "  Reports: $fleetDir"
Write-Host "  Summary: $fleetHtmlPath"
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

if ($Open) { Start-Process $fleetHtmlPath }
