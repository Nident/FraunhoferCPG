#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT"
ENV_FILE="${ENV_FILE:-$ROOT/config/.env}"
[[ $# -eq 1 ]] || { echo "Usage: $0 DATASET.json" >&2; exit 2; }
[[ -f "$1" ]] || { echo "Dataset does not exist: $1" >&2; exit 2; }
DATASET="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "$ENV_FILE" ]] || { echo "Missing env file: $ENV_FILE" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

require() { [[ -n "${!1:-}" ]] || { echo "Missing required variable: $1" >&2; exit 2; }; }
for name in REPOS_DIR CPG_REPO_DIR OUT_DIR LOG_DIR DOCKER_IMAGE \
  CPG_ANALYSIS_MODE MAX_COMPLEXITY_CF_DFG SKIP_EXISTING CUSTOM_PASS_LIST \
  STATS_INTERVAL_SECONDS MAX_CPG_SECONDS JEP_LIBRARY_PATH JEP_PYTHON_PATH; do
  require "$name"
done
[[ "$CPG_ANALYSIS_MODE" =~ ^(fast|full)$ ]] || { echo "CPG_ANALYSIS_MODE must be fast or full" >&2; exit 2; }
[[ "$SKIP_EXISTING" =~ ^(0|1)$ ]] || { echo "SKIP_EXISTING must be 0 or 1" >&2; exit 2; }
[[ "$MAX_COMPLEXITY_CF_DFG" =~ ^[1-9][0-9]*$ ]] || { echo "MAX_COMPLEXITY_CF_DFG must be a positive integer" >&2; exit 2; }
[[ "$MAX_CPG_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "MAX_CPG_SECONDS must be a positive integer" >&2; exit 2; }
for command in docker python3; do command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 2; }; done
python3 - "$STATS_INTERVAL_SECONDS" <<'PY' || { echo "STATS_INTERVAL_SECONDS must be a positive number" >&2; exit 2; }
import sys
assert float(sys.argv[1]) > 0
PY
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 2; }
docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1 || { echo "Missing image $DOCKER_IMAGE; run ./init.sh" >&2; exit 2; }
CPG_BIN="$CPG_REPO_DIR/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j"
[[ -x "$CPG_BIN" ]] || { echo "Missing $CPG_BIN; run ./init.sh" >&2; exit 2; }

dataset_name="$(basename "$DATASET")"; dataset_name="${dataset_name%.*}"
RUN_ID="${RUN_ID:-$dataset_name}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "RUN_ID contains invalid characters: $RUN_ID" >&2; exit 2; }
RUN_REPOS_DIR="$REPOS_DIR/$RUN_ID"
RUN_OUT_DIR="$OUT_DIR/$RUN_ID"
RUN_LOG_DIR="$LOG_DIR/$RUN_ID"
METRICS_CSV="$RUN_LOG_DIR/commit_metrics.csv"
DOCKER_SAMPLES_CSV="$RUN_LOG_DIR/docker_samples.csv"
mkdir -p "$RUN_REPOS_DIR" "$RUN_OUT_DIR" "$RUN_LOG_DIR"

records_tsv="$(mktemp)"; active_container=""; docker_summary=""
cleanup() {
  [[ -z "$active_container" ]] || docker rm -f "$active_container" >/dev/null 2>&1 || true
  rm -f "$records_tsv"
  [[ -z "$docker_summary" ]] || rm -f "$docker_summary"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

python3 - "$DATASET" > "$records_tsv" <<'PY'
import json, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
try:
    objects = [json.loads(text)]
except json.JSONDecodeError:
    objects = [json.loads(line) for line in text.splitlines() if line.strip()]

count = 0
for obj in objects:
    for record in obj.get("records", [obj]):
        language = record.get("dataset_record", {}).get("language", "")
        for item in record.get("results", []):
            project, commit = item.get("project"), item.get("commit")
            if not isinstance(project, str) or not re.fullmatch(r"[^/\s]+/[^/\s]+", project):
                raise TypeError(f"invalid project: {project!r}")
            if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-fA-F]{7,64}", commit):
                raise TypeError(f"invalid commit for {project}: {commit!r}")
            if not isinstance(language, str) or "\t" in language:
                raise TypeError(f"invalid language for {project}: {language!r}")
            print(project, commit, language, sep="\t")
            count += 1
if count == 0:
    raise ValueError("dataset contains no results")
PY

echo "Run=$RUN_ID dataset=$DATASET"
while IFS=$'\t' read -r project commit language; do
  safe_project="${project//\//__}"; short_commit="${commit:0:12}"
  repo_dir="$RUN_REPOS_DIR/${safe_project}__${short_commit}"
  out_file="$RUN_OUT_DIR/${safe_project}__${short_commit}.json"
  log_file="$RUN_LOG_DIR/${safe_project}__${short_commit}.log"
  active_container="cpg-${safe_project//__/-}-${short_commit}-$$"

  if [[ "$SKIP_EXISTING" == 1 && -s "$out_file" ]]; then
    echo "Skip $project@$short_commit"
    active_container=""; continue
  fi

  started="$(python3 -c 'import time; print(time.time())')"; started_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$repo_dir"
  docker run --rm -e PROJECT="$project" -e COMMIT="$commit" -v "$repo_dir:/repo" "$DOCKER_IMAGE" bash -lc '
    set -euo pipefail
    git config --global --add safe.directory /repo
    [[ -d /repo/.git ]] || git clone "https://github.com/$PROJECT.git" /repo
    git -C /repo fetch --all --tags --prune
    git -C /repo checkout --force "$COMMIT"
    git -C /repo clean -fdx
  '
  cloned="$(python3 -c 'import time; print(time.time())')"; docker_summary="$(mktemp)"

  docker run --rm --name "$active_container" \
    -e CPG_ANALYSIS_MODE -e MAX_COMPLEXITY_CF_DFG -e CUSTOM_PASS_LIST \
    -e JEP_LIBRARY_PATH -e JEP_PYTHON_PATH -e MAX_CPG_SECONDS \
    -v "$CPG_REPO_DIR:/cpg:ro" -v "$repo_dir:/src:ro" -v "$RUN_OUT_DIR:/out" \
    "$DOCKER_IMAGE" bash -lc '
      set -euo pipefail
      export LD_LIBRARY_PATH="${JEP_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
      export PYTHONPATH="${JEP_PYTHON_PATH}:${PYTHONPATH:-}"
      export JAVA_OPTS="${JAVA_OPTS:-} -Djava.library.path=${JEP_LIBRARY_PATH}"
      args=()
      [[ "$CPG_ANALYSIS_MODE" == full ]] || args=(--no-default-passes "--custom-pass-list=${CUSTOM_PASS_LIST}" "--max-complexity-cf-dfg=${MAX_COMPLEXITY_CF_DFG}")
      timeout --signal=TERM --kill-after=30s "$MAX_CPG_SECONDS" \
        /cpg/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j \
        --no-neo4j "${args[@]}" --top-level=/src --export-json="/out/'"$(basename "$out_file")"'" /src
    ' > "$log_file" 2>&1 &
  analysis_pid=$!
  python3 "$ROOT/scripts/monitor_docker_stats.py" --container "$active_container" \
    --project "$project" --commit "$commit" --samples-csv "$DOCKER_SAMPLES_CSV" \
    --summary-json "$docker_summary" --interval "$STATS_INTERVAL_SECONDS" &
  monitor_pid=$!

  exit_code=0; wait "$analysis_pid" || exit_code=$?
  case "$exit_code" in 0) status=success;; 124) status=timed_out;; *) status=failed;; esac
  wait "$monitor_pid" || echo "Statistics monitor failed: $project@$short_commit" >&2
  active_container=""
  finished="$(python3 -c 'import time; print(time.time())')"; finished_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  read -r total clone cpg < <(python3 - "$started" "$cloned" "$finished" <<'PY'
import sys
a, b, c = map(float, sys.argv[1:]); print(c-a, b-a, c-b)
PY
  )
  python3 "$ROOT/scripts/record_commit_metrics.py" --csv "$METRICS_CSV" --summary-json "$docker_summary" \
    --project "$project" --commit "$commit" --language "$language" --status "$status" \
    --started-at-utc "$started_utc" --finished-at-utc "$finished_utc" \
    --total-seconds "$total" --clone-seconds "$clone" --cpg-seconds "$cpg" \
    --repo "$repo_dir" --cpg-repo "$CPG_REPO_DIR" --output "$out_file" \
    --output-dir "$RUN_OUT_DIR" --log "$log_file" --image "$DOCKER_IMAGE"
  rm -f "$docker_summary"; docker_summary=""

  if [[ "$status" != success ]]; then
    [[ ! -e "$out_file" ]] || mv "$out_file" "$out_file.partial-$(date -u +'%Y%m%dT%H%M%SZ')"
    echo "$status $project@$short_commit (exit=$exit_code)" >&2
  else
    echo "Saved $out_file"
  fi
done < "$records_tsv"

echo "Done: $RUN_OUT_DIR"
echo "Metrics: $METRICS_CSV"
