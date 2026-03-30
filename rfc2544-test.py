#!/usr/bin/env python3
"""
RFC 2544 / RFC 6349 Fleet Network Performance Test Suite

Tests all hosts in hosts.txt and generates individual + fleet summary HTML/PDF reports.
Works on macOS and Linux. Requires iperf3 installed (brew install iperf3 / apt install iperf3).

Author: Dakota Cole
License: MIT

Usage:
    ./rfc2544-test.py --open
    ./rfc2544-test.py --site "My Network" --duration 60 --open
    ./rfc2544-test.py --single-host "Branch-1" --open
    ./rfc2544-test.py --skip-udp --skip-traceroute --open
"""

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from html import escape
from pathlib import Path

# ============================================================
# Helpers
# ============================================================

def find_iperf3(script_dir):
    """Find iperf3 binary."""
    candidates = [
        os.path.join(script_dir, "iperf3"),
        shutil.which("iperf3"),
    ]
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    # Check without execute bit (might just need chmod)
    local = os.path.join(script_dir, "iperf3")
    if os.path.isfile(local):
        os.chmod(local, 0o755)
        return local
    return None


def run_iperf3(iperf3_bin, arguments, timeout=240):
    """Run iperf3 with given arguments, return parsed result."""
    try:
        result = subprocess.run(
            [iperf3_bin] + arguments,
            capture_output=True, text=True, timeout=timeout
        )
        stdout = result.stdout
        if "-J" in arguments or "--json" in arguments:
            try:
                data = json.loads(stdout)
                if "error" in data:
                    return {"success": False, "error": data["error"]}
                return {"success": True, "data": data}
            except json.JSONDecodeError:
                return {"success": False, "error": "JSON parse failed"}
        return {"success": True, "raw": stdout}
    except subprocess.TimeoutExpired:
        return {"success": False, "error": f"Timeout after {timeout}s"}
    except Exception as e:
        return {"success": False, "error": str(e)}


def get_tcp_summary(data, reverse=False):
    """Extract TCP summary from iperf3 JSON."""
    try:
        end = data["end"]
        if reverse:
            s = end.get("sum_received", end.get("sum", {}))
        else:
            s = end.get("sum_sent", end.get("sum", {}))
        return {
            "mbps": round(s.get("bits_per_second", 0) / 1e6, 2),
            "bytes": s.get("bytes", 0),
            "retransmits": s.get("retransmits", 0),
        }
    except Exception:
        return {"mbps": None, "bytes": 0, "retransmits": 0, "error": "Parse failed"}


def get_udp_summary(data):
    """Extract UDP summary from iperf3 JSON."""
    try:
        s = data["end"]["sum"]
        return {
            "mbps": round(s.get("bits_per_second", 0) / 1e6, 2),
            "jitter_ms": round(s.get("jitter_ms", 0), 3),
            "lost_packets": s.get("lost_packets", 0),
            "total_packets": s.get("packets", 0),
            "loss_percent": round(s.get("lost_percent", 0), 2),
        }
    except Exception:
        return None


def run_ping(host, count=20, size=56):
    """Run ICMP ping test. Cross-platform (macOS/Linux)."""
    system = platform.system()
    cmd = ["ping"]
    if system == "Darwin":
        cmd += ["-c", str(count), "-s", str(size), "-W", "3000", host]
    else:  # Linux
        cmd += ["-c", str(count), "-s", str(size), "-W", "3", host]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=count * 5 + 10)
        output = result.stdout

        # Parse results
        # Match: "X packets transmitted, Y received, Z% packet loss"
        loss_match = re.search(r"(\d+)% packet loss", output)
        loss_pct = float(loss_match.group(1)) if loss_match else 100.0

        # Match: "min/avg/max/stddev = 1.0/2.0/3.0/0.5 ms" (or mdev on Linux)
        rtt_match = re.search(r"([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)\s*ms", output)
        if rtt_match:
            min_ms = round(float(rtt_match.group(1)), 1)
            avg_ms = round(float(rtt_match.group(2)), 1)
            max_ms = round(float(rtt_match.group(3)), 1)
        else:
            min_ms = avg_ms = max_ms = 0

        recv_match = re.search(r"(\d+)\s+(packets\s+)?received", output)
        received = int(recv_match.group(1)) if recv_match else 0

        return {
            "success": received > 0,
            "count": received,
            "sent": count,
            "loss_percent": loss_pct,
            "avg_ms": avg_ms,
            "min_ms": min_ms,
            "max_ms": max_ms,
        }
    except Exception:
        return {"success": False, "count": 0, "sent": count, "loss_percent": 100,
                "avg_ms": 0, "min_ms": 0, "max_ms": 0}


def run_traceroute(host):
    """Run traceroute. Uses traceroute on Linux, traceroute on macOS."""
    cmd = "traceroute"
    if not shutil.which(cmd):
        cmd = "tracepath"
        if not shutil.which(cmd):
            return {"success": False, "output": "traceroute not found"}
    try:
        result = subprocess.run(
            [cmd, "-n", "-w", "3", host],
            capture_output=True, text=True, timeout=120
        )
        return {"success": True, "output": result.stdout}
    except subprocess.TimeoutExpired:
        return {"success": False, "output": "Traceroute timed out"}
    except Exception as e:
        return {"success": False, "output": str(e)}


def parse_hosts_file(hosts_file, single_host=None):
    """Parse hosts.txt file."""
    hosts = []
    with open(hosts_file, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 3:
                print(f"  [WARN] Skipping malformed line: {line}")
                continue
            entry = {
                "name": parts[0],
                "ip": parts[1],
                "port": int(parts[2]),
                "notes": parts[3] if len(parts) >= 4 else "",
            }
            if single_host and entry["name"] != single_host:
                continue
            hosts.append(entry)
    return hosts


def create_sample_hosts(hosts_file):
    """Create a sample hosts.txt."""
    sample = """# ============================================================
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
# SETUP:
#   1. Edit this file with your target IPs
#   2. Start iperf3 -s on each remote host
#   3. Run: ./rfc2544-test.py --open
#
# ============================================================

# --- Example hosts (edit these!) ---
HQ-Server     | 10.0.0.1    | 5201 | Main office iperf3 server
Branch-1      | 10.10.1.1   | 5201 | Remote branch office
Branch-2      | 10.10.2.1   | 5201 | Secondary branch
Cabinet-7     | 10.10.7.1   | 5201 | Field cabinet
"""
    with open(hosts_file, "w") as f:
        f.write(sample)


# ============================================================
# Report HTML
# ============================================================

REPORT_CSS = """
body { font-family: -apple-system, 'Segoe UI', Tahoma, Arial, sans-serif; color: #333; font-size: 10pt; margin: 0; padding: 20px; }
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
.stats { display: flex; gap: 10px; margin: 14px 0; }
.stat { background: #f8f9fa; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px 18px; text-align: center; flex: 1; }
.stat .num { font-size: 22pt; font-weight: 700; }
.stat .lbl { font-size: 8pt; text-transform: uppercase; color: #6c757d; }
.stat.ok .num { color: #28a745; }
.stat.fail .num { color: #dc3545; }
a { color: #2e86c1; }
"""


def build_host_html(host, results, args, report_date):
    """Build per-host HTML report."""
    up = results.get("tcp_upload", {})
    dn = results.get("tcp_download", {})
    ps = results.get("ping_small", {})
    pl = results.get("ping_large", {})
    udp_list = results.get("udp", [])
    trace = results.get("traceroute", {})

    up_mbps = f"{up['mbps']} Mbps" if up.get("mbps") else "FAILED"
    dn_mbps = f"{dn['mbps']} Mbps" if dn.get("mbps") else "FAILED"

    udp_rows = ""
    for u in udp_list:
        if u.get("error"):
            udp_rows += f"<tr><td>{u['datalen']}</td><td colspan='5' style='color:red'>{escape(u['error'])}</td></tr>"
        else:
            lc = "color:red;font-weight:bold" if u["loss_percent"] > 1 else ("color:orange" if u["loss_percent"] > 0 else "color:green")
            udp_rows += (f"<tr><td>{u['datalen']} bytes</td><td>{u['mbps']} Mbps</td>"
                         f"<td>{u['jitter_ms']} ms</td><td>{u['lost_packets']}</td>"
                         f"<td>{u['total_packets']}</td><td style='{lc}'>{u['loss_percent']}%</td></tr>")

    udp_section = ""
    if udp_rows:
        udp_section = (f"<h2>UDP Frame Loss and Jitter</h2><table>"
                       f"<tr><th>Datagram</th><th>Throughput</th><th>Jitter</th><th>Lost</th><th>Total</th><th>Loss %</th></tr>"
                       f"{udp_rows}</table>")

    trace_section = ""
    if trace.get("success"):
        trace_section = f"<h2>Traceroute</h2><pre>{escape(trace['output'])}</pre>"

    notes_box = f"<div class='box'><div class='lbl'>Notes</div><div class='val'>{escape(host['notes'])}</div></div>" if host["notes"] else ""
    hostname = platform.node() or "unknown"

    return f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>{REPORT_CSS}</style></head><body>
<div class="hdr">
  <div class="brand">RFC2544 Test Suite</div>
  <h1>{escape(host['name'])} - Performance Report</h1>
  <div class="sub">RFC 2544 / RFC 6349 -- {escape(args.site)}</div>
</div>
<div class="grid">
  <div class="box"><div class="lbl">Host</div><div class="val">{host['ip']}:{host['port']}</div></div>
  <div class="box"><div class="lbl">Date</div><div class="val">{report_date}</div></div>
  <div class="box"><div class="lbl">Technician</div><div class="val">{escape(args.tech)}</div></div>
  <div class="box"><div class="lbl">Test From</div><div class="val">{hostname}</div></div>
  {notes_box}
</div>
<h2>TCP Throughput</h2>
<table>
<tr><th>Direction</th><th>Throughput</th><th>Retransmits</th><th>Duration</th><th>Streams</th></tr>
<tr><td>Upload (Client -&gt; Host)</td><td><strong>{up_mbps}</strong></td><td>{up.get('retransmits', 0)}</td><td>{args.duration}s</td><td>{args.parallel}</td></tr>
<tr><td>Download (Host -&gt; Client)</td><td><strong>{dn_mbps}</strong></td><td>{dn.get('retransmits', 0)}</td><td>{args.duration}s</td><td>{args.parallel}</td></tr>
</table>
<h2>Latency (ICMP)</h2>
<table>
<tr><th>Test</th><th>Avg</th><th>Min</th><th>Max</th><th>Loss</th><th>Packets</th></tr>
<tr><td>56 byte</td><td>{ps.get('avg_ms', 0)} ms</td><td>{ps.get('min_ms', 0)} ms</td><td>{ps.get('max_ms', 0)} ms</td><td>{ps.get('loss_percent', 100)}%</td><td>{ps.get('count', 0)}/{ps.get('sent', 0)}</td></tr>
<tr><td>1400 byte (DF)</td><td>{pl.get('avg_ms', 0)} ms</td><td>{pl.get('min_ms', 0)} ms</td><td>{pl.get('max_ms', 0)} ms</td><td>{pl.get('loss_percent', 100)}%</td><td>{pl.get('count', 0)}/{pl.get('sent', 0)}</td></tr>
</table>
{udp_section}
{trace_section}
<div class="ft">RFC2544 Test Suite -- {report_date} -- {hostname}</div>
</body></html>"""


def build_fleet_html(fleet_results, hosts_count, args, report_date, fleet_dir):
    """Build fleet summary HTML."""
    ok_count = sum(1 for r in fleet_results if r["status"] == "OK")
    fail_count = sum(1 for r in fleet_results if r["status"] != "OK")
    hostname = platform.node() or "unknown"

    rows = ""
    for r in fleet_results:
        sc = "color:green" if r["status"] == "OK" else "color:red"
        up_str = f"{r['tcp_up']:.2f}" if r["tcp_up"] is not None else "-"
        dn_str = f"{r['tcp_down']:.2f}" if r["tcp_down"] is not None else "-"
        ping_str = f"{r['ping_avg']}ms" if r["ping_avg"] is not None else "-"
        udp_str = f"{r['udp_best']}Mbps" if r["udp_best"] is not None else "-"
        jit_str = f"{r['udp_jitter']}ms" if r["udp_jitter"] is not None else "-"
        report_path = os.path.join(fleet_dir, r["name"], "report.html")
        link = f"<a href='{r['name']}/report.html'>View</a>" if os.path.exists(report_path) else "-"

        rows += (f"<tr><td><strong>{escape(r['name'])}</strong></td><td>{r['ip']}:{r['port']}</td>"
                 f"<td style='{sc};font-weight:bold'>{r['status']}</td>"
                 f"<td>{up_str}</td><td>{dn_str}</td>"
                 f"<td>{r.get('up_retrans', 0)} / {r.get('dn_retrans', 0)}</td>"
                 f"<td>{ping_str}</td><td>{r.get('ping_loss', '-')}%</td>"
                 f"<td>{udp_str}</td><td>{jit_str}</td>"
                 f"<td>{escape(r.get('notes', ''))}</td><td>{link}</td></tr>")

    return f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>{REPORT_CSS}</style></head><body>
<div class="hdr">
  <div class="brand">RFC2544 Test Suite</div>
  <h1>Fleet Performance Summary</h1>
  <div class="sub">{escape(args.site)} -- {report_date}</div>
</div>
<div class="stats">
  <div class="stat"><div class="num">{hosts_count}</div><div class="lbl">Total Hosts</div></div>
  <div class="stat ok"><div class="num">{ok_count}</div><div class="lbl">Passed</div></div>
  <div class="stat fail"><div class="num">{fail_count}</div><div class="lbl">Failed</div></div>
  <div class="stat"><div class="num">{escape(args.tech)}</div><div class="lbl">Technician</div></div>
</div>
<table>
<tr><th>Name</th><th>Endpoint</th><th>Status</th><th>TCP Up<br/>(Mbps)</th><th>TCP Down<br/>(Mbps)</th>
<th>Retrans<br/>(Up/Dn)</th><th>Ping<br/>Avg</th><th>Ping<br/>Loss</th><th>UDP<br/>Best</th>
<th>UDP<br/>Jitter</th><th>Notes</th><th>Report</th></tr>
{rows}
</table>
<div class="ft">RFC2544 Test Suite Fleet Test v1.0 -- {report_date} -- {hostname}</div>
</body></html>"""


# ============================================================
# Main
# ============================================================

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    parser = argparse.ArgumentParser(
        description="RFC 2544 / RFC 6349 Fleet Network Performance Test Suite",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --open
  %(prog)s --site "Production Network" --duration 60 --open
  %(prog)s --single-host "Branch-1" --open
  %(prog)s --skip-udp --skip-traceroute --open
  %(prog)s --udp-mbps 2000 --parallel 8 --open
"""
    )
    parser.add_argument("--hosts-file", default=os.path.join(script_dir, "hosts.txt"),
                        help="Path to hosts config file (default: hosts.txt in script dir)")
    parser.add_argument("--duration", type=int, default=30, help="iperf3 TCP test duration in seconds (default: 30)")
    parser.add_argument("--parallel", type=int, default=4, help="Parallel TCP streams (default: 4)")
    parser.add_argument("--udp-mbps", type=int, default=100, help="UDP target bandwidth in Mbps (default: 100)")
    parser.add_argument("--udp-duration", type=int, default=15, help="UDP test duration per datagram size (default: 15)")
    parser.add_argument("--ping-count", type=int, default=20, help="ICMP pings per test (default: 20)")
    parser.add_argument("--site", default="Network Test", help="Site/project name for report headers")
    parser.add_argument("--tech", default=os.environ.get("USER", os.environ.get("USERNAME", "unknown")),
                        help="Technician name (default: current user)")
    parser.add_argument("--open", action="store_true", help="Open report when done")
    parser.add_argument("--skip-udp", action="store_true", help="Skip UDP tests")
    parser.add_argument("--skip-traceroute", action="store_true", help="Skip traceroute")
    parser.add_argument("--single-host", default="", help="Test only one host by name from hosts.txt")
    parser.add_argument("--full", action="store_true",
                        help="Comprehensive test: 60s TCP, 8 streams, 2Gbps UDP, 30 pings, everything enabled")
    args = parser.parse_args()

    # -- Full mode overrides --
    if args.full:
        if args.duration == 30: args.duration = 60
        if args.parallel == 4: args.parallel = 8
        if args.udp_mbps == 100: args.udp_mbps = 2000
        if args.udp_duration == 15: args.udp_duration = 20
        if args.ping_count == 20: args.ping_count = 30
        args.skip_udp = False
        args.skip_traceroute = False

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    report_date = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    fleet_dir = os.path.join(script_dir, f"reports-{timestamp}")
    hostname = platform.node() or "unknown"

    # -- Find iperf3 --
    iperf3 = find_iperf3(script_dir)
    if not iperf3:
        print()
        print("\033[91m[ERROR] iperf3 not found!\033[0m")
        print(f"  Install it:")
        print(f"    macOS:  brew install iperf3")
        print(f"    Ubuntu: sudo apt install iperf3")
        print(f"    Or place the iperf3 binary in: {script_dir}")
        print()
        sys.exit(1)

    # -- Parse hosts --
    hosts_file = args.hosts_file
    if not os.path.exists(hosts_file):
        print()
        print("\033[93m[INFO] No hosts.txt found. Creating sample file...\033[0m")
        create_sample_hosts(hosts_file)
        print(f"  Created: {hosts_file}")
        print()
        print("  Edit hosts.txt with your target IPs, then re-run this script.")
        print()
        sys.exit(0)

    hosts = parse_hosts_file(hosts_file, args.single_host)
    if not hosts:
        if args.single_host:
            print(f"\033[91m[ERROR] Host '{args.single_host}' not found in {hosts_file}\033[0m")
        else:
            print(f"\033[91m[ERROR] No hosts found in {hosts_file}\033[0m")
        sys.exit(1)

    # -- Banner --
    print()
    print("\033[96m" + "=" * 60)
    print("  RFC 2544 Fleet Network Performance Test")
    print("=" * 60 + "\033[0m")
    print(f"  Site:       {args.site}")
    print(f"  Hosts:      {len(hosts)}{' (filtered: ' + args.single_host + ')' if args.single_host else ''}")
    print(f"  Config:     {hosts_file}")
    print(f"  Duration:   {args.duration}s per test | Streams: {args.parallel}")
    print(f"  UDP:        {'SKIPPED' if args.skip_udp else f'{args.udp_mbps}M target, {args.udp_duration}s'}")
    print(f"  Tech:       {args.tech}")
    print(f"  iperf3:     {iperf3}")
    print(f"  Output:     {fleet_dir}")
    print("\033[96m" + "=" * 60 + "\033[0m")
    print()

    os.makedirs(fleet_dir, exist_ok=True)

    # -- Test each host --
    fleet_results = []

    for i, h in enumerate(hosts, 1):
        h_name = h["name"]
        h_ip = h["ip"]
        h_port = h["port"]
        host_dir = os.path.join(fleet_dir, h_name)
        os.makedirs(host_dir, exist_ok=True)

        print()
        print("\033[36m" + "-" * 60)
        print(f"  [{i}/{len(hosts)}] {h_name} - {h_ip}:{h_port}")
        if h["notes"]:
            print(f"  {h['notes']}")
        print("-" * 60 + "\033[0m")

        # -- Connectivity --
        print("  [..] Checking connectivity...", end="", flush=True)
        quick = run_ping(h_ip, count=2, size=56)
        if not quick["success"]:
            print(f"\r  \033[91m[FAIL] Cannot reach {h_ip} - SKIPPED\033[0m")
            fleet_results.append({
                "name": h_name, "ip": h_ip, "port": h_port, "notes": h["notes"],
                "status": "UNREACHABLE",
                "tcp_up": None, "tcp_down": None, "up_retrans": None, "dn_retrans": None,
                "ping_avg": None, "ping_loss": None,
                "udp_best": None, "udp_jitter": None, "udp_loss": None,
            })
            continue
        print(f"\r  \033[92m[OK] Reachable ({quick['avg_ms']}ms)\033[0m        ")

        results = {}

        # -- Ping small --
        print("  [..] Ping test (small)...", end="", flush=True)
        ping_small = run_ping(h_ip, count=args.ping_count, size=56)
        print(f"\r  \033[92m[OK] Ping: {ping_small['avg_ms']}ms avg, {ping_small['loss_percent']}% loss\033[0m        ")
        results["ping_small"] = ping_small

        # -- Ping large --
        print("  [..] Ping test (1400 byte)...", end="", flush=True)
        ping_large = run_ping(h_ip, count=args.ping_count, size=1400)
        print(f"\r  \033[92m[OK] Ping 1400: {ping_large['avg_ms']}ms avg, {ping_large['loss_percent']}% loss\033[0m        ")
        results["ping_large"] = ping_large

        # -- Traceroute --
        if not args.skip_traceroute:
            print("  [..] Traceroute...", end="", flush=True)
            trace = run_traceroute(h_ip)
            if trace["success"]:
                hop_count = len([l for l in trace["output"].split("\n") if re.match(r"^\s*\d+\s", l)])
                print(f"\r  \033[92m[OK] Traceroute: {hop_count} hops\033[0m        ")
            else:
                print(f"\r  \033[93m[WARN] Traceroute failed\033[0m        ")
            results["traceroute"] = trace

        # -- TCP Upload --
        print(f"  [..] TCP Upload ({args.parallel} streams, {args.duration}s)...", end="", flush=True)
        tcp_up = run_iperf3(iperf3, ["-J", "-c", h_ip, "-p", str(h_port),
                                     "-t", str(args.duration), "-P", str(args.parallel)],
                            timeout=args.duration + 30)
        up_summary = get_tcp_summary(tcp_up["data"]) if tcp_up["success"] else {"mbps": None, "retransmits": 0, "error": tcp_up.get("error", "")}
        results["tcp_upload"] = up_summary
        if up_summary.get("mbps"):
            print(f"\r  \033[92m[OK] TCP Up: {up_summary['mbps']} Mbps ({up_summary['retransmits']} retrans)\033[0m        ")
        else:
            print(f"\r  \033[91m[FAIL] TCP Up: {up_summary.get('error', 'unknown')}\033[0m        ")

        # -- TCP Download --
        print(f"  [..] TCP Download ({args.parallel} streams, {args.duration}s)...", end="", flush=True)
        tcp_dn = run_iperf3(iperf3, ["-J", "-c", h_ip, "-p", str(h_port),
                                     "-t", str(args.duration), "-P", str(args.parallel), "-R"],
                            timeout=args.duration + 30)
        dn_summary = get_tcp_summary(tcp_dn["data"], reverse=True) if tcp_dn["success"] else {"mbps": None, "retransmits": 0, "error": tcp_dn.get("error", "")}
        results["tcp_download"] = dn_summary
        if dn_summary.get("mbps"):
            print(f"\r  \033[92m[OK] TCP Dn: {dn_summary['mbps']} Mbps ({dn_summary['retransmits']} retrans)\033[0m        ")
        else:
            print(f"\r  \033[91m[FAIL] TCP Dn: {dn_summary.get('error', 'unknown')}\033[0m        ")

        # -- UDP Profile --
        udp_results = []
        udp_best = None
        if not args.skip_udp:
            udp_lens = [64, 256, 512, 1024, 1470]
            for dlen in udp_lens:
                print(f"  [..] UDP len={dlen}...", end="", flush=True)
                udp_run = run_iperf3(iperf3, ["-J", "-u", "-c", h_ip, "-p", str(h_port),
                                              "-t", str(args.udp_duration), "-b", f"{args.udp_mbps}M",
                                              "--len", str(dlen)],
                                     timeout=args.udp_duration + 30)
                if udp_run["success"]:
                    us = get_udp_summary(udp_run["data"])
                    if us:
                        us["datalen"] = dlen
                        udp_results.append(us)
                        color = "\033[91m" if us["loss_percent"] > 1 else ("\033[93m" if us["loss_percent"] > 0 else "\033[92m")
                        print(f"\r  {color}[OK] UDP {dlen}: {us['mbps']}Mbps, jitter {us['jitter_ms']}ms, loss {us['loss_percent']}%\033[0m        ")
                        if not udp_best or (us["mbps"] > udp_best["mbps"] and us["loss_percent"] <= 1):
                            udp_best = us
                else:
                    print(f"\r  \033[91m[FAIL] UDP {dlen}: {udp_run.get('error', 'unknown')}\033[0m        ")
                    udp_results.append({"datalen": dlen, "error": udp_run.get("error", "unknown")})
        results["udp"] = udp_results
        results["udp_best"] = udp_best

        # -- Save per-host JSON --
        with open(os.path.join(host_dir, "results.json"), "w") as f:
            json.dump(results, f, indent=2, default=str)

        # -- Per-host HTML --
        host_html = build_host_html(h, results, args, report_date)
        with open(os.path.join(host_dir, "report.html"), "w") as f:
            f.write(host_html)

        # -- Fleet result --
        fleet_results.append({
            "name": h_name, "ip": h_ip, "port": h_port, "notes": h["notes"],
            "status": "OK",
            "tcp_up": up_summary.get("mbps"),
            "tcp_down": dn_summary.get("mbps"),
            "up_retrans": up_summary.get("retransmits", 0),
            "dn_retrans": dn_summary.get("retransmits", 0),
            "ping_avg": ping_small.get("avg_ms"),
            "ping_loss": ping_small.get("loss_percent"),
            "udp_best": udp_best["mbps"] if udp_best else None,
            "udp_jitter": udp_best["jitter_ms"] if udp_best else None,
            "udp_loss": udp_best["loss_percent"] if udp_best else None,
        })

    # -- Fleet summary HTML --
    fleet_html = build_fleet_html(fleet_results, len(hosts), args, report_date, fleet_dir)
    fleet_html_path = os.path.join(fleet_dir, "fleet-summary.html")
    with open(fleet_html_path, "w") as f:
        f.write(fleet_html)

    with open(os.path.join(fleet_dir, "fleet-results.json"), "w") as f:
        json.dump(fleet_results, f, indent=2, default=str)

    # -- Console summary --
    ok_count = sum(1 for r in fleet_results if r["status"] == "OK")
    fail_count = sum(1 for r in fleet_results if r["status"] != "OK")

    print()
    print("\033[92m" + "=" * 60)
    print("  FLEET TEST COMPLETE")
    print("=" * 60 + "\033[0m")
    print(f"  Hosts: {len(hosts)} tested | {ok_count} passed | {fail_count} failed")
    print()
    for r in fleet_results:
        icon = "PASS" if r["status"] == "OK" else "FAIL"
        color = "\033[92m" if r["status"] == "OK" else "\033[91m"
        up_str = f"{r['tcp_up']:>8.0f}M" if r["tcp_up"] else "     ---"
        dn_str = f"{r['tcp_down']:>8.0f}M" if r["tcp_down"] else "     ---"
        ping_str = f"{r['ping_avg']}ms" if r["ping_avg"] is not None else "-"
        print(f"  {color}[{icon}] {r['name']:<20} Up: {up_str}  Dn: {dn_str}  Ping: {ping_str}\033[0m")
    print()
    print(f"  Reports: {fleet_dir}")
    print(f"  Summary: {fleet_html_path}")
    print("\033[92m" + "=" * 60 + "\033[0m")
    print()

    if args.open:
        if sys.platform == "darwin":
            subprocess.Popen(["open", fleet_html_path])
        elif sys.platform.startswith("linux"):
            subprocess.Popen(["xdg-open", fleet_html_path], stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
