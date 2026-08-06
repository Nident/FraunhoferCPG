#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT"
ENV_FILE="${ENV_FILE:-$ROOT/config/.env}"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./build_fraunhofer_cpg_best_effort.sh OWNER/REPO COMMIT [OUT.json]

Environment:
  MAX_RETRIES       Maximum number of failed files to skip during combined CPG retries. Default: 5
  CLONE_RETRIES     Maximum clone/fetch attempts for transient network failures. Default: 3
  PRECHECK_FILES    Run CPG once per file first and skip files that fail. Default: 0
  SOURCE_GLOB       find(1) path glob for source files. Default: ./*.java
  METRICS_CSV       Optional old-format commit metrics CSV
  DOCKER_SAMPLES_CSV Optional old-format docker stats samples CSV

Example:
  ./build_fraunhofer_cpg_best_effort.sh apache/zookeeper 6a0e0ea09bae7d07d98b58a647d25afef2a8988f
EOF
}

[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
PROJECT="$1"
COMMIT="$2"
OUT_FILE_ARG="${3:-}"

[[ "$PROJECT" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || { echo "Invalid project: $PROJECT" >&2; exit 2; }
[[ "$COMMIT" =~ ^[0-9a-fA-F]{7,64}$ ]] || { echo "Invalid commit: $COMMIT" >&2; exit 2; }
[[ -f "$ENV_FILE" ]] || { echo "Missing env file: $ENV_FILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

require() { [[ -n "${!1:-}" ]] || { echo "Missing required variable: $1" >&2; exit 2; }; }
for name in REPOS_DIR CPG_REPO_DIR OUT_DIR DOCKER_IMAGE JEP_LIBRARY_PATH JEP_PYTHON_PATH; do
  require "$name"
done

MAX_RETRIES="${MAX_RETRIES:-5}"
PRECHECK_FILES="${PRECHECK_FILES:-0}"
SOURCE_GLOB="${SOURCE_GLOB:-./*.java}"
METRICS_CSV="${METRICS_CSV:-}"
DOCKER_SAMPLES_CSV="${DOCKER_SAMPLES_CSV:-}"
STATS_INTERVAL_SECONDS="${STATS_INTERVAL_SECONDS:-1}"
CLONE_RETRIES="${CLONE_RETRIES:-3}"
[[ "$MAX_RETRIES" =~ ^[0-9]+$ ]] || { echo "MAX_RETRIES must be a non-negative integer" >&2; exit 2; }
[[ "$CLONE_RETRIES" =~ ^[1-9][0-9]*$ ]] || { echo "CLONE_RETRIES must be a positive integer" >&2; exit 2; }
[[ "$PRECHECK_FILES" =~ ^(0|1)$ ]] || { echo "PRECHECK_FILES must be 0 or 1" >&2; exit 2; }
[[ "$SOURCE_GLOB" != *$'\n'* ]] || { echo "SOURCE_GLOB must be one line" >&2; exit 2; }
python3 - "$STATS_INTERVAL_SECONDS" <<'PY' || { echo "STATS_INTERVAL_SECONDS must be a positive number" >&2; exit 2; }
import sys
assert float(sys.argv[1]) > 0
PY
if [[ -n "$METRICS_CSV" || -n "$DOCKER_SAMPLES_CSV" ]]; then
  [[ -n "$METRICS_CSV" && -n "$DOCKER_SAMPLES_CSV" ]] || { echo "METRICS_CSV and DOCKER_SAMPLES_CSV must be set together" >&2; exit 2; }
  [[ -x "$ROOT/scripts/monitor_docker_stats.py" ]] || { echo "Missing $ROOT/scripts/monitor_docker_stats.py" >&2; exit 2; }
  [[ -x "$ROOT/scripts/record_commit_metrics.py" ]] || { echo "Missing $ROOT/scripts/record_commit_metrics.py" >&2; exit 2; }
fi

command -v docker >/dev/null || { echo "Missing command: docker" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 2; }
docker run --rm "$DOCKER_IMAGE" true >/dev/null 2>&1 || { echo "Cannot run image $DOCKER_IMAGE; run ./init.sh" >&2; exit 2; }

CPG_BIN="$CPG_REPO_DIR/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j"
[[ -x "$CPG_BIN" ]] || { echo "Missing $CPG_BIN; run ./init.sh" >&2; exit 2; }

safe_project="${PROJECT//\//__}"
short_commit="${COMMIT:0:12}"
record_id="${safe_project}__${short_commit}"
RECORD_ID="${RECORD_ID:-$record_id}"
COMMIT_LABEL="${COMMIT_LABEL:-$COMMIT#$RECORD_ID}"
repo_dir="$REPOS_DIR/$record_id"

if [[ -n "$OUT_FILE_ARG" ]]; then
  mkdir -p "$(dirname "$OUT_FILE_ARG")"
  OUT_FILE="$(cd "$(dirname "$OUT_FILE_ARG")" && pwd)/$(basename "$OUT_FILE_ARG")"
else
  mkdir -p "$OUT_DIR"
  OUT_FILE="$OUT_DIR/$record_id.best-effort.json"
fi

out_dir="$(dirname "$OUT_FILE")"
out_base="$(basename "$OUT_FILE")"
state_dir="$out_dir/$record_id.best-effort"
all_sources="$state_dir/all_sources.txt"
active_sources="$state_dir/active_sources.txt"
excluded_sources="$state_dir/excluded_files.txt"
log_file="$state_dir/latest.log"
attempt_log_dir="$state_dir/attempts"
precheck_log_dir="$state_dir/precheck"
docker_summary_dir="$state_dir/docker_summaries"
docker_summary_aggregate="$state_dir/docker_summary.aggregate.json"

mkdir -p "$repo_dir" "$out_dir" "$state_dir" "$attempt_log_dir" "$precheck_log_dir" "$docker_summary_dir"
: > "$excluded_sources"
find "$docker_summary_dir" -type f -name '*.json' -delete

started="$(python3 -c 'import time; print(time.time())')"
started_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
metrics_status="failed"
metrics_recorded=0

record_metrics() {
  [[ -n "$METRICS_CSV" ]] || return 0
  [[ "$metrics_recorded" == 0 ]] || return 0
  metrics_recorded=1
  local status="$1"
  local finished finished_utc total clone cpg
  finished="$(python3 -c 'import time; print(time.time())')"
  finished_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  python3 - "$docker_summary_dir" "$docker_summary_aggregate" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
summaries = []
for path in source.glob("*.json"):
    try:
        summaries.append(json.loads(path.read_text()))
    except Exception:
        pass
sample_count = sum(item.get("sample_count", 0) for item in summaries)

def weighted_average(field):
    if not sample_count:
        return 0
    return round(
        sum(item.get(field, 0) * item.get("sample_count", 0) for item in summaries)
        / sample_count,
        3,
    )

def maximum(field):
    return max((item.get(field, 0) for item in summaries), default=0)

summary = {
    "sample_count": sample_count,
    "avg_cpu_percent": weighted_average("avg_cpu_percent"),
    "max_cpu_percent": maximum("max_cpu_percent"),
    "avg_memory_bytes": round(weighted_average("avg_memory_bytes")),
    "max_memory_bytes": maximum("max_memory_bytes"),
    "max_memory_percent": maximum("max_memory_percent"),
    "network_rx_bytes": maximum("network_rx_bytes"),
    "network_tx_bytes": maximum("network_tx_bytes"),
    "block_read_bytes": maximum("block_read_bytes"),
    "block_write_bytes": maximum("block_write_bytes"),
    "max_pids": maximum("max_pids"),
}
target.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY
  read -r total clone cpg < <(python3 - "$started" "$cloned" "$finished" <<'PY'
import sys
a, b, c = map(float, sys.argv[1:])
print(c - a, b - a, c - b)
PY
  )
  python3 "$ROOT/scripts/record_commit_metrics.py" --csv "$METRICS_CSV" --summary-json "$docker_summary_aggregate" \
    --project "$PROJECT" --commit "$COMMIT_LABEL" --language java --status "$status" \
    --started-at-utc "$started_utc" --finished-at-utc "$finished_utc" \
    --total-seconds "$total" --clone-seconds "$clone" --cpg-seconds "$cpg" \
    --repo "$repo_dir" --cpg-repo "$CPG_REPO_DIR" --output "$OUT_FILE" \
    --output-dir "$out_dir" --log "$log_file" --image "$DOCKER_IMAGE"
}

echo "[1/3] Clone and checkout: https://github.com/$PROJECT.git@$COMMIT"
clone_exit=0
for clone_attempt in $(seq 1 "$CLONE_RETRIES"); do
  clone_exit=0
  docker run --rm \
    -e PROJECT="$PROJECT" -e COMMIT="$COMMIT" \
    -v "$repo_dir:/repo" \
    "$DOCKER_IMAGE" bash -lc '
      set -euo pipefail
      git config --global --add safe.directory /repo
      if ! git -C /repo rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        find /repo -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        git clone "https://github.com/$PROJECT.git" /repo
      fi
      git -C /repo fetch --all --tags --prune
      git -C /repo checkout --force "$COMMIT"
      git -C /repo clean -fdx
    ' || clone_exit=$?
  if [[ "$clone_exit" -eq 0 ]]; then
    break
  fi
  if [[ "$clone_attempt" -lt "$CLONE_RETRIES" ]]; then
    echo "Clone attempt $clone_attempt/$CLONE_RETRIES failed; retrying in 10s" >&2
    sleep 10
  fi
done
if [[ "$clone_exit" -ne 0 ]]; then
  echo "Clone failed after $CLONE_RETRIES attempts" >&2
  cloned="$(python3 -c 'import time; print(time.time())')"
  record_metrics failed
  exit "$clone_exit"
fi
cloned="$(python3 -c 'import time; print(time.time())')"

echo "[2/3] Build source list: $SOURCE_GLOB"
docker run --rm \
  -e SOURCE_GLOB="$SOURCE_GLOB" \
  -v "$repo_dir:/src:ro" \
  -v "$state_dir:/state" \
  "$DOCKER_IMAGE" bash -lc '
    set -euo pipefail
    cd /src
    find . -type f -path "$SOURCE_GLOB" -print | sed "s#^\./#/src/#" | sort > /state/all_sources.txt
  '
cp "$all_sources" "$active_sources"
source_count="$(wc -l < "$active_sources" | tr -d ' ')"
if [[ "$source_count" -eq 0 ]]; then
  echo "No source files matched SOURCE_GLOB=$SOURCE_GLOB" >&2
  record_metrics failed
  exit 2
fi
echo "Sources: $source_count"

if [[ "$PRECHECK_FILES" == 1 ]]; then
  echo "[precheck] Running one-file CPG checks"
  precheck_tmp="$out_dir/$record_id.precheck.tmp.json"
  precheck_index=1
  : > "$excluded_sources"

  while IFS= read -r source_file; do
    printf '[precheck] %s/%s %s\n' "$precheck_index" "$source_count" "$source_file"
    rm -f "$precheck_tmp"
    precheck_log="$precheck_log_dir/precheck_${precheck_index}.log"
    container_name="cpg-precheck-${record_id:0:36}-${precheck_index}-$$"
    docker_summary="$docker_summary_dir/precheck_${precheck_index}.json"
    exit_code=0
    docker run --rm --name "$container_name" \
      -e JEP_LIBRARY_PATH -e JEP_PYTHON_PATH \
      -e SOURCE_FILE="$source_file" \
      -v "$CPG_REPO_DIR:/cpg:ro" \
      -v "$repo_dir:/src:ro" \
      -v "$out_dir:/out" \
      "$DOCKER_IMAGE" bash -lc '
        set -euo pipefail
        export LD_LIBRARY_PATH="${JEP_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
        export PYTHONPATH="${JEP_PYTHON_PATH}:${PYTHONPATH:-}"
        export JAVA_OPTS="${JAVA_OPTS:-} -Djava.library.path=${JEP_LIBRARY_PATH}"
        /cpg/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j \
          --no-neo4j \
          --top-level=/src \
          --export-json="/out/'"$(basename "$precheck_tmp")"'" \
          "$SOURCE_FILE"
      ' > "$precheck_log" 2>&1 &
    analysis_pid=$!
    monitor_pid=""
    if [[ -n "$DOCKER_SAMPLES_CSV" ]]; then
      python3 "$ROOT/scripts/monitor_docker_stats.py" --container "$container_name" \
        --project "$PROJECT" --commit "$COMMIT_LABEL#precheck#$precheck_index" \
        --samples-csv "$DOCKER_SAMPLES_CSV" --summary-json "$docker_summary" \
        --interval "$STATS_INTERVAL_SECONDS" &
      monitor_pid=$!
    fi
    wait "$analysis_pid" || exit_code=$?
    [[ -z "$monitor_pid" ]] || wait "$monitor_pid" || echo "Statistics monitor failed: $container_name" >&2

    if [[ "$exit_code" -ne 0 || ! -s "$precheck_tmp" ]]; then
      echo "$source_file" >> "$excluded_sources"
      echo "[precheck] skip: $source_file"
    fi
    rm -f "$precheck_tmp"
    precheck_index=$((precheck_index + 1))
  done < "$all_sources"

  tmp_sources="$(mktemp)"
  if [[ -s "$excluded_sources" ]]; then
    grep -Fxv -f "$excluded_sources" "$all_sources" > "$tmp_sources" || true
  else
    cp "$all_sources" "$tmp_sources"
  fi
  mv "$tmp_sources" "$active_sources"
  active_count="$(wc -l < "$active_sources" | tr -d ' ')"
  skipped_count="$(wc -l < "$excluded_sources" | tr -d ' ')"
  if [[ "$active_count" -eq 0 ]]; then
    echo "All files failed precheck. Logs: $precheck_log_dir" >&2
    record_metrics failed
    exit 1
  fi
  echo "[precheck] Done: active=$active_count skipped=$skipped_count logs=$precheck_log_dir"
fi

attempt=1
while true; do
  active_count="$(wc -l < "$active_sources" | tr -d ' ')"
  echo "[3/3] Attempt $attempt: active sources=$active_count skipped=$(wc -l < "$excluded_sources" | tr -d ' ')"

  rm -f "$OUT_FILE"
  container_name="cpg-attempt-${record_id:0:38}-${attempt}-$$"
  docker_summary="$docker_summary_dir/attempt_${attempt}.json"
  exit_code=0
  docker run --rm --name "$container_name" \
    -e JEP_LIBRARY_PATH -e JEP_PYTHON_PATH \
    -v "$CPG_REPO_DIR:/cpg:ro" \
    -v "$repo_dir:/src:ro" \
    -v "$out_dir:/out" \
    -v "$state_dir:/state" \
    "$DOCKER_IMAGE" bash -lc '
      set -euo pipefail
      export LD_LIBRARY_PATH="${JEP_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
      export PYTHONPATH="${JEP_PYTHON_PATH}:${PYTHONPATH:-}"
      export JAVA_OPTS="${JAVA_OPTS:-} -Djava.library.path=${JEP_LIBRARY_PATH}"
      mapfile -t source_args < /state/active_sources.txt
      /cpg/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j \
        --no-neo4j \
        --top-level=/src \
        --export-json="/out/'"$out_base"'" \
        "${source_args[@]}"
    ' > "$log_file" 2>&1 &
  analysis_pid=$!
  monitor_pid=""
  if [[ -n "$DOCKER_SAMPLES_CSV" ]]; then
    python3 "$ROOT/scripts/monitor_docker_stats.py" --container "$container_name" \
      --project "$PROJECT" --commit "$COMMIT_LABEL#attempt#$attempt" \
      --samples-csv "$DOCKER_SAMPLES_CSV" --summary-json "$docker_summary" \
      --interval "$STATS_INTERVAL_SECONDS" &
    monitor_pid=$!
  fi
  wait "$analysis_pid" || exit_code=$?
  [[ -z "$monitor_pid" ]] || wait "$monitor_pid" || echo "Statistics monitor failed: $container_name" >&2

  cp "$log_file" "$attempt_log_dir/attempt_${attempt}.log"

  if [[ "$exit_code" -eq 0 && -s "$OUT_FILE" ]]; then
    metrics_status="success"
    echo "Saved: $OUT_FILE"
    echo "Excluded files: $excluded_sources"
    record_metrics "$metrics_status"
    exit 0
  fi

  if [[ "$attempt" -gt "$MAX_RETRIES" ]]; then
    echo "Failed after $MAX_RETRIES retries. Last log: $log_file" >&2
    record_metrics failed
    exit "$exit_code"
  fi

  failed_file="$(awk '
    /TranslationManager Parsing \/src\// {
      line = $0
      sub(/^.*TranslationManager Parsing /, "", line)
      last = line
    }
    END { print last }
  ' "$log_file")"

  if [[ -z "$failed_file" ]]; then
    echo "Could not identify failed source file. Last log: $log_file" >&2
    record_metrics failed
    exit "$exit_code"
  fi

  if ! grep -Fxq "$failed_file" "$active_sources"; then
    echo "Failed file is not in active source list: $failed_file" >&2
    echo "Last log: $log_file" >&2
    record_metrics failed
    exit "$exit_code"
  fi

  echo "$failed_file" >> "$excluded_sources"
  tmp_sources="$(mktemp)"
  grep -Fxv "$failed_file" "$active_sources" > "$tmp_sources" || true
  mv "$tmp_sources" "$active_sources"
  echo "Skipping failed file: $failed_file"
  if [[ ! -s "$active_sources" ]]; then
    echo "All active files were excluded. Last log: $log_file" >&2
    record_metrics failed
    exit "$exit_code"
  fi

  attempt=$((attempt + 1))
done
