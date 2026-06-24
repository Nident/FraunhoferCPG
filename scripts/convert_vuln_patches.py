#!/usr/bin/env python3
"""Convert vuln_patches.jsonl to the compact input accepted by the CPG builder."""

import argparse
import json
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="Source vuln_patches.jsonl")
    parser.add_argument("output", type=Path, help="Destination JSON file")
    parser.add_argument("--start", type=int, default=1,
                        help="First non-empty JSONL row to include, 1-based (default: 1)")
    parser.add_argument("--end", type=int, default=None,
                        help="Last non-empty JSONL row to include, inclusive (default: EOF)")
    parser.add_argument("-n", "--limit", type=int, default=None,
                        help="Maximum number of selected rows to convert (default: all)")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.start < 1:
        raise SystemExit("--start must be a positive integer")
    if args.end is not None and args.end < args.start:
        raise SystemExit("--end must be greater than or equal to --start")
    if args.limit is not None and args.limit < 1:
        raise SystemExit("--limit must be a positive integer")

    records = []
    row_number = 0
    with args.input.open(encoding="utf-8") as source:
        for source_line, line in enumerate(source, 1):
            if not line.strip():
                continue
            row_number += 1
            if row_number < args.start:
                continue
            if args.end is not None and row_number > args.end:
                break
            if args.limit is not None and len(records) >= args.limit:
                break

            item = json.loads(line)
            project = item["project"]
            results = []
            for index, state in enumerate(item.get("states", [])):
                commit = state.get("commit")
                if commit:
                    results.append({
                        "project": project,
                        "commit": commit,
                        "state": "vulnerable" if index == 0 else "fixed",
                    })

            if results:
                records.append({
                    "project": project,
                    "source_line": source_line,
                    "source_row": row_number,
                    "results": results,
                    "dataset_record": {
                        "language": item.get("language", ""),
                        "cve_ids": item.get("cve_ids", []),
                        "cwe_ids": item.get("cwe_ids", []),
                    },
                })

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps({"records": records}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Converted {len(records)} records to {args.output}")


if __name__ == "__main__":
    main()
