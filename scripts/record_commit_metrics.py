#!/usr/bin/env python3
"""Append one commit-level CPG build measurement to a CSV file."""

import argparse
import csv
import json
import subprocess
from pathlib import Path


def path_size(path):
    if not path.exists():
        return 0
    if path.is_file():
        return path.stat().st_size
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--summary-json", type=Path, required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--language", default="")
    parser.add_argument("--status", required=True)
    parser.add_argument("--started-at-utc", required=True)
    parser.add_argument("--finished-at-utc", required=True)
    parser.add_argument("--total-seconds", type=float, required=True)
    parser.add_argument("--clone-seconds", type=float, required=True)
    parser.add_argument("--cpg-seconds", type=float, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--cpg-repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()

    docker = {
        "sample_count": 0,
        "avg_cpu_percent": 0,
        "max_cpu_percent": 0,
        "avg_memory_bytes": 0,
        "max_memory_bytes": 0,
        "max_memory_percent": 0,
        "network_rx_bytes": 0,
        "network_tx_bytes": 0,
        "block_read_bytes": 0,
        "block_write_bytes": 0,
        "max_pids": 0,
    }
    if args.summary_json.exists():
        docker.update(json.loads(args.summary_json.read_text()))
    inspected = subprocess.run(
        ["docker", "image", "inspect", "--format", "{{.Size}}", args.image],
        capture_output=True, text=True, check=False,
    )
    image_size = int(inspected.stdout.strip()) if inspected.returncode == 0 else 0

    row = {
        "project": args.project,
        "commit": args.commit,
        "language": args.language,
        "status": args.status,
        "started_at_utc": args.started_at_utc,
        "finished_at_utc": args.finished_at_utc,
        "total_commit_seconds": round(args.total_seconds, 3),
        "clone_checkout_seconds": round(args.clone_seconds, 3),
        "cpg_build_seconds": round(args.cpg_seconds, 3),
        **docker,
        "repo_size_bytes": path_size(args.repo),
        "cpg_toolchain_size_bytes": path_size(args.cpg_repo),
        "cpg_output_size_bytes": path_size(args.output),
        "output_dir_total_size_bytes": path_size(args.output_dir),
        "log_size_bytes": path_size(args.log),
        "docker_image_size_bytes": image_size,
    }
    fields = list(row)
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    write_header = not args.csv.exists() or args.csv.stat().st_size == 0
    with args.csv.open("a", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        if write_header:
            writer.writeheader()
        writer.writerow(row)


if __name__ == "__main__":
    main()
