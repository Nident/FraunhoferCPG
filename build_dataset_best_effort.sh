#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT"
ENV_FILE="${ENV_FILE:-$ROOT/config/.env}"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./build_dataset_best_effort.sh [DATASET.jsonl]

Environment:
  DATASET                dataset path when positional argument is omitted
  DATASET_TARGET         vuln, task, or both. Default: vuln
  DATASET_COMMIT_FIELDS  comma-separated vuln_commit,safe_commit,last_commit. Default: vuln_commit,safe_commit
  DATASET_START          1-based unique record start. Default: 1
  DATASET_LIMIT          max unique records to build, 0 means all. Default: 0
  RUN_ID                 output run id. Default: dataset_best_effort
  DRY_RUN                parse records only. Default: 0
  SKIP_EXISTING          skip non-empty output JSON files. Default: 1

Best-effort options are passed through:
  PRECHECK_FILES         Default: 1
  SOURCE_GLOB            Default: ./*/src/main/java/*.java
  MAX_RETRIES            Default: 5
  STATS_INTERVAL_SECONDS Default: 1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -le 1 ]] || { usage; exit 2; }
[[ -f "$ENV_FILE" ]] || { echo "Missing env file: $ENV_FILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

DATASET="${1:-${DATASET:-}}"
[[ -n "$DATASET" ]] || { echo "Missing DATASET. Pass DATASET.jsonl or set DATASET in config/.env" >&2; exit 2; }
[[ -f "$DATASET" ]] || { echo "Dataset does not exist: $DATASET" >&2; exit 2; }
DATASET="$(cd "$(dirname "$DATASET")" && pwd)/$(basename "$DATASET")"

DATASET_TARGET="${DATASET_TARGET:-vuln}"
DATASET_COMMIT_FIELDS="${DATASET_COMMIT_FIELDS:-vuln_commit,safe_commit}"
DATASET_START="${DATASET_START:-1}"
DATASET_LIMIT="${DATASET_LIMIT:-0}"
RUN_ID="${RUN_ID:-dataset_best_effort}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_EXISTING="${SKIP_EXISTING:-1}"
PRECHECK_FILES="${PRECHECK_FILES:-1}"
SOURCE_GLOB="${SOURCE_GLOB:-./*/src/main/java/*.java}"
MAX_RETRIES="${MAX_RETRIES:-5}"
STATS_INTERVAL_SECONDS="${STATS_INTERVAL_SECONDS:-1}"

[[ "$DATASET_TARGET" =~ ^(vuln|task|both)$ ]] || { echo "DATASET_TARGET must be vuln, task, or both" >&2; exit 2; }
[[ "$DATASET_COMMIT_FIELDS" =~ ^(vuln_commit|safe_commit|last_commit)(,(vuln_commit|safe_commit|last_commit))*$ ]] || { echo "Invalid DATASET_COMMIT_FIELDS" >&2; exit 2; }
[[ "$DATASET_START" =~ ^[1-9][0-9]*$ ]] || { echo "DATASET_START must be a positive integer" >&2; exit 2; }
[[ "$DATASET_LIMIT" =~ ^[0-9]+$ ]] || { echo "DATASET_LIMIT must be a non-negative integer" >&2; exit 2; }
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "RUN_ID contains invalid characters" >&2; exit 2; }
[[ "$DRY_RUN" =~ ^(0|1)$ ]] || { echo "DRY_RUN must be 0 or 1" >&2; exit 2; }
[[ "$SKIP_EXISTING" =~ ^(0|1)$ ]] || { echo "SKIP_EXISTING must be 0 or 1" >&2; exit 2; }

run_dir="$ROOT/cpg-output/$RUN_ID.dataset"
manifest="$run_dir/manifest.tsv"
summary="$run_dir/summary.csv"
metrics_csv="$run_dir/commit_metrics.csv"
docker_samples_csv="$run_dir/docker_samples.csv"
mkdir -p "$run_dir"

python3 - "$DATASET" "$DATASET_TARGET" "$DATASET_COMMIT_FIELDS" "$DATASET_START" "$DATASET_LIMIT" > "$manifest" <<'PY'
import json
import pathlib
import re
import sys

dataset = pathlib.Path(sys.argv[1])
target = sys.argv[2]
commit_fields = sys.argv[3].split(",")
start = int(sys.argv[4])
limit = int(sys.argv[5])

project_re = re.compile(r"[^/\s]+/[^/\s]+")
commit_re = re.compile(r"[0-9a-fA-F]{7,64}")

def clean(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("_")

def objects(row):
    if target in {"vuln", "both"}:
        yield "vuln", row.get("vuln")
    if target in {"task", "both"}:
        yield "task", row.get("task")

seen = set()
unique_index = 0
included = 0
for row_number, line in enumerate(dataset.open(encoding="utf-8"), start=1):
    if not line.strip():
        continue
    row = json.loads(line)
    for kind, obj in objects(row):
        if not isinstance(obj, dict):
            continue
        project = obj.get("project")
        if not isinstance(project, str) or not project_re.fullmatch(project):
            continue
        for field in commit_fields:
            commit = obj.get(field)
            if not isinstance(commit, str) or not commit_re.fullmatch(commit):
                continue
            key = (kind, project, field, commit)
            if key in seen:
                continue
            seen.add(key)
            unique_index += 1
            if unique_index < start:
                continue
            if limit and included >= limit:
                continue
            included += 1
            record_id = f"{kind}__{field}__{clean(project.replace('/', '__'))}__{commit[:12]}"
            print(record_id, kind, project, field, commit, row_number, sep="\t")
PY

record_count="$(wc -l < "$manifest" | tr -d ' ')"
echo "Run=$RUN_ID dataset=$DATASET records=$record_count target=$DATASET_TARGET commit_fields=$DATASET_COMMIT_FIELDS start=$DATASET_START limit=$DATASET_LIMIT"
echo "Best-effort: PRECHECK_FILES=$PRECHECK_FILES SOURCE_GLOB=$SOURCE_GLOB MAX_RETRIES=$MAX_RETRIES"
echo "Manifest: $manifest"
echo "Metrics: $metrics_csv"
echo "Docker samples: $docker_samples_csv"

if [[ "$record_count" -eq 0 ]]; then
  echo "No records selected" >&2
  exit 1
fi

if [[ "$DRY_RUN" == 1 ]]; then
  sed -n '1,20p' "$manifest"
  exit 0
fi

if [[ ! -f "$summary" ]]; then
  printf 'record_id,kind,project,commit_field,commit,status,output_json,excluded_file_count\n' > "$summary"
fi

while IFS=$'\t' read -r record_id kind project commit_field commit row_number; do
  out_file="$run_dir/$record_id.json"
  status="failed"
  excluded_count=0

  if [[ "$SKIP_EXISTING" == 1 && -s "$out_file" ]]; then
    status="skipped_existing"
    excluded_file="$run_dir/$record_id.best-effort/excluded_files.txt"
    [[ -f "$excluded_file" ]] && excluded_count="$(wc -l < "$excluded_file" | tr -d ' ')"
    echo "Skip existing: $record_id"
  else
    echo "Build: $record_id ($project@$commit)"
    if PRECHECK_FILES="$PRECHECK_FILES" SOURCE_GLOB="$SOURCE_GLOB" MAX_RETRIES="$MAX_RETRIES" \
      STATS_INTERVAL_SECONDS="$STATS_INTERVAL_SECONDS" \
      METRICS_CSV="$metrics_csv" DOCKER_SAMPLES_CSV="$docker_samples_csv" \
      RECORD_ID="$record_id" COMMIT_LABEL="$commit#$kind#$commit_field#$record_id" \
      "$ROOT/build_fraunhofer_cpg_best_effort.sh" "$project" "$commit" "$out_file"; then
      status="success"
    fi
    excluded_file="$run_dir/$record_id.best-effort/excluded_files.txt"
    [[ -f "$excluded_file" ]] && excluded_count="$(wc -l < "$excluded_file" | tr -d ' ')"
  fi

  python3 - "$summary" "$record_id" "$kind" "$project" "$commit_field" "$commit" "$status" "$out_file" "$excluded_count" <<'PY'
import csv
import sys

path, *row = sys.argv[1:]
with open(path, "a", encoding="utf-8", newline="") as f:
    csv.writer(f).writerow(row)
PY

  if [[ "$status" == "failed" ]]; then
    echo "Failed: $record_id" >&2
  fi
done < "$manifest"

echo "Done: $run_dir"
echo "Summary: $summary"
