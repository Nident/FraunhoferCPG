#!/usr/bin/env python3
"""Sample `docker stats` for one container and write CSV plus a JSON summary."""

import argparse
import csv
import json
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


UNITS = {
    "b": 1,
    "kb": 1_000,
    "mb": 1_000_000,
    "gb": 1_000_000_000,
    "tb": 1_000_000_000_000,
    "kib": 1024,
    "mib": 1024**2,
    "gib": 1024**3,
    "tib": 1024**4,
}


def size_bytes(value):
    match = re.match(r"\s*([0-9.]+)\s*([a-zA-Z]+)", value or "")
    return int(float(match.group(1)) * UNITS[match.group(2).lower()]) if match else 0


def pair_bytes(value):
    parts = (value or "").split("/")
    return tuple(size_bytes(part) for part in parts[:2]) if len(parts) >= 2 else (0, 0)


def percent(value):
    try:
        return float((value or "0").strip().rstrip("%"))
    except ValueError:
        return 0.0


def docker(*args):
    return subprocess.run(
        ["docker", *args], capture_output=True, text=True, check=False
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--samples-csv", type=Path, required=True)
    parser.add_argument("--summary-json", type=Path, required=True)
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()

    if args.interval <= 0:
        raise SystemExit("--interval must be greater than zero")

    args.samples_csv.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "timestamp_utc", "project", "commit", "container", "cpu_percent",
        "memory_used_bytes", "memory_limit_bytes", "memory_percent",
        "network_rx_bytes", "network_tx_bytes", "block_read_bytes",
        "block_write_bytes", "pids",
    ]
    rows = []
    seen_container = False
    deadline = time.monotonic() + 30

    while True:
        inspection = docker("inspect", "--format", "{{.State.Running}}", args.container)
        if inspection.returncode != 0:
            if seen_container or time.monotonic() >= deadline:
                break
            time.sleep(0.1)
            continue

        seen_container = True
        if inspection.stdout.strip() != "true":
            break

        result = docker("stats", "--no-stream", "--format", "{{json .}}", args.container)
        if result.returncode == 0 and result.stdout.strip():
            stat = json.loads(result.stdout.splitlines()[-1])
            mem_used, mem_limit = pair_bytes(stat.get("MemUsage"))
            net_rx, net_tx = pair_bytes(stat.get("NetIO"))
            block_read, block_write = pair_bytes(stat.get("BlockIO"))
            row = {
                "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                "project": args.project,
                "commit": args.commit,
                "container": args.container,
                "cpu_percent": percent(stat.get("CPUPerc")),
                "memory_used_bytes": mem_used,
                "memory_limit_bytes": mem_limit,
                "memory_percent": percent(stat.get("MemPerc")),
                "network_rx_bytes": net_rx,
                "network_tx_bytes": net_tx,
                "block_read_bytes": block_read,
                "block_write_bytes": block_write,
                "pids": int(stat.get("PIDs") or 0),
            }
            rows.append(row)
            write_header = not args.samples_csv.exists() or args.samples_csv.stat().st_size == 0
            with args.samples_csv.open("a", newline="", encoding="utf-8") as output:
                writer = csv.DictWriter(output, fieldnames=fields)
                if write_header:
                    writer.writeheader()
                writer.writerow(row)

        time.sleep(args.interval)

    def average(field):
        return sum(row[field] for row in rows) / len(rows) if rows else 0

    def maximum(field):
        return max((row[field] for row in rows), default=0)

    summary = {
        "sample_count": len(rows),
        "avg_cpu_percent": round(average("cpu_percent"), 3),
        "max_cpu_percent": maximum("cpu_percent"),
        "avg_memory_bytes": round(average("memory_used_bytes")),
        "max_memory_bytes": maximum("memory_used_bytes"),
        "max_memory_percent": maximum("memory_percent"),
        "network_rx_bytes": maximum("network_rx_bytes"),
        "network_tx_bytes": maximum("network_tx_bytes"),
        "block_read_bytes": maximum("block_read_bytes"),
        "block_write_bytes": maximum("block_write_bytes"),
        "max_pids": maximum("pids"),
    }
    args.summary_json.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
