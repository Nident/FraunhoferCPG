#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT"
ENV_FILE="${ENV_FILE:-$ROOT/config/.env}"
DEFAULT_DATASET="$ROOT/datasets/tasks 2.jsonl"

[[ $# -le 1 ]] || { echo "Usage: $0 [DATASET.jsonl]" >&2; exit 2; }
DATASET="${1:-$DEFAULT_DATASET}"
[[ -f "$DATASET" ]] || { echo "Dataset does not exist: $DATASET" >&2; exit 2; }
DATASET="$(cd "$(dirname "$DATASET")" && pwd)/$(basename "$DATASET")"
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

TASKS_TARGET="${TASKS_TARGET:-vuln}"
TASKS_COMMIT_FIELDS="${TASKS_COMMIT_FIELDS:-${TASKS_COMMIT_FIELD:-vuln_commit,safe_commit}}"
TASKS_START="${TASKS_START:-1}"
TASKS_LIMIT="${TASKS_LIMIT:-0}"
TASKS_SELECTED_ONLY="${TASKS_SELECTED_ONLY:-0}"
TASKS_LANGUAGE_DEFAULT="${TASKS_LANGUAGE_DEFAULT:-java}"
DRY_RUN="${DRY_RUN:-0}"
CPG_EXCLUSION_PATTERNS="${CPG_EXCLUSION_PATTERNS:-}"
CPG_EXTRA_ARGS="${CPG_EXTRA_ARGS:-}"
CPG_JAVA_MAIN_ONLY="${CPG_JAVA_MAIN_ONLY:-0}"
[[ "$TASKS_TARGET" =~ ^(vuln|task|both)$ ]] || { echo "TASKS_TARGET must be vuln, task, or both" >&2; exit 2; }
[[ "$TASKS_COMMIT_FIELDS" =~ ^(vuln_commit|safe_commit|last_commit)(,(vuln_commit|safe_commit|last_commit))*$ ]] || { echo "TASKS_COMMIT_FIELDS must be a comma-separated list of vuln_commit,safe_commit,last_commit" >&2; exit 2; }
[[ "$TASKS_START" =~ ^[1-9][0-9]*$ ]] || { echo "TASKS_START must be a positive integer" >&2; exit 2; }
[[ "$TASKS_LIMIT" =~ ^[0-9]+$ ]] || { echo "TASKS_LIMIT must be a non-negative integer" >&2; exit 2; }
[[ "$TASKS_SELECTED_ONLY" =~ ^(0|1)$ ]] || { echo "TASKS_SELECTED_ONLY must be 0 or 1" >&2; exit 2; }
[[ "$TASKS_LANGUAGE_DEFAULT" =~ ^[A-Za-z0-9_.+-]+$ ]] || { echo "TASKS_LANGUAGE_DEFAULT contains invalid characters" >&2; exit 2; }
[[ "$DRY_RUN" =~ ^(0|1)$ ]] || { echo "DRY_RUN must be 0 or 1" >&2; exit 2; }
[[ "$CPG_JAVA_MAIN_ONLY" =~ ^(0|1)$ ]] || { echo "CPG_JAVA_MAIN_ONLY must be 0 or 1" >&2; exit 2; }
[[ "$CPG_EXCLUSION_PATTERNS" != *$'\n'* ]] || { echo "CPG_EXCLUSION_PATTERNS must be one line" >&2; exit 2; }
[[ "$CPG_EXTRA_ARGS" != *$'\n'* ]] || { echo "CPG_EXTRA_ARGS must be one line" >&2; exit 2; }

command -v python3 >/dev/null || { echo "Missing command: python3" >&2; exit 2; }
if [[ "$DRY_RUN" == 0 ]]; then
  command -v docker >/dev/null || { echo "Missing command: docker" >&2; exit 2; }
fi
python3 - "$STATS_INTERVAL_SECONDS" <<'PY' || { echo "STATS_INTERVAL_SECONDS must be a positive number" >&2; exit 2; }
import sys
assert float(sys.argv[1]) > 0
PY
CPG_BIN="$CPG_REPO_DIR/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j"
if [[ "$DRY_RUN" == 0 ]]; then
  docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 2; }
  docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1 || { echo "Missing image $DOCKER_IMAGE; run ./init.sh" >&2; exit 2; }
  [[ -x "$CPG_BIN" ]] || { echo "Missing $CPG_BIN; run ./init.sh" >&2; exit 2; }
fi

dataset_name="$(basename "$DATASET")"; dataset_name="${dataset_name%.*}"; dataset_name="${dataset_name// /_}"
commit_fields_id="${TASKS_COMMIT_FIELDS//,/_}"
RUN_ID="${RUN_ID:-${dataset_name}_${TASKS_TARGET}_${commit_fields_id}_full_project}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "RUN_ID contains invalid characters: $RUN_ID" >&2; exit 2; }
RUN_REPOS_DIR="$REPOS_DIR/$RUN_ID"
RUN_OUT_DIR="$OUT_DIR/$RUN_ID"
RUN_LOG_DIR="$LOG_DIR/$RUN_ID"
METRICS_CSV="$RUN_LOG_DIR/commit_metrics.csv"
DOCKER_SAMPLES_CSV="$RUN_LOG_DIR/docker_samples.csv"
MANIFEST_JSONL="$RUN_LOG_DIR/record_manifest.jsonl"
mkdir -p "$RUN_REPOS_DIR" "$RUN_OUT_DIR" "$RUN_LOG_DIR"

records_tsv="$(mktemp)"; active_container=""; docker_summary=""
cleanup() {
  [[ -z "$active_container" ]] || docker rm -f "$active_container" >/dev/null 2>&1 || true
  rm -f "$records_tsv"
  [[ -z "$docker_summary" ]] || rm -f "$docker_summary"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

python3 - "$DATASET" "$TASKS_TARGET" "$TASKS_COMMIT_FIELDS" "$TASKS_START" "$TASKS_LIMIT" "$TASKS_SELECTED_ONLY" "$TASKS_LANGUAGE_DEFAULT" "$MANIFEST_JSONL" > "$records_tsv" <<'PY'
import json
import pathlib
import re
import sys

dataset = pathlib.Path(sys.argv[1])
target = sys.argv[2]
commit_fields = sys.argv[3].split(",")
start = int(sys.argv[4])
limit = int(sys.argv[5])
selected_only = sys.argv[6] == "1"
language_default = sys.argv[7]
manifest = pathlib.Path(sys.argv[8])

project_re = re.compile(r"[^/\s]+/[^/\s]+")
commit_re = re.compile(r"[0-9a-fA-F]{7,64}")

def clean(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("_")

def infer_language(obj: dict, fallback: str) -> str:
    language = obj.get("language")
    if isinstance(language, str) and language:
        return language
    for snippet in obj.get("snippets", []) if isinstance(obj.get("snippets"), list) else []:
        code = snippet.get("vuln_snippet") if isinstance(snippet, dict) else None
        if not isinstance(code, str):
            continue
        if re.search(r"\b(class|interface|enum)\s+[A-Za-z_$][\w$]*\b|\b(public|private|protected)\b", code):
            return "java"
        if re.search(r"^(def|class|import|from)\s+", code, re.MULTILINE):
            return "python"
    return fallback

def candidates(row: dict):
    if target in {"vuln", "both"}:
        yield "vuln", row.get("vuln")
    if target in {"task", "both"}:
        yield "task", row.get("task")

seen_logical = set()
included_logical = {}
records = {}
order = []
included_count = 0
unique_index = 0
for row_number, line in enumerate(dataset.open(encoding="utf-8"), start=1):
    if not line.strip():
        continue
    row = json.loads(line)
    if selected_only and row.get("selected") is not True:
        continue
    for kind, obj in candidates(row):
        if not isinstance(obj, dict):
            raise TypeError(f"line {row_number}: missing object field {kind}")
        project = obj.get("project")
        if not isinstance(project, str) or not project_re.fullmatch(project):
            raise TypeError(f"line {row_number}: invalid {kind}.project: {project!r}")
        language = infer_language(obj, language_default)
        if "\t" in language:
            raise TypeError(f"line {row_number}: invalid language: {language!r}")

        commits = []
        for commit_field in commit_fields:
            commit = obj.get(commit_field)
            if not isinstance(commit, str) or not commit_re.fullmatch(commit):
                raise TypeError(f"line {row_number}: invalid {kind}.{commit_field}: {commit!r}")
            commits.append((commit_field, commit))

        logical_key = (kind, project, tuple(commits))
        if logical_key in included_logical:
            for key in included_logical[logical_key]:
                records[key]["row_numbers"].append(row_number)
                if row.get("selected") is True:
                    records[key]["selected_rows"] += 1
            continue
        if logical_key in seen_logical:
            continue

        seen_logical.add(logical_key)
        unique_index += 1
        if unique_index < start:
            continue
        if limit and included_count >= limit:
            continue

        safe_project = clean(project.replace("/", "__"))
        output_keys = []
        for commit_field, commit in commits:
            key = (kind, project, commit_field, commit)
            record_id = f"{kind}__{commit_field}__{safe_project}__{commit[:12]}"
            records[key] = {
                "record_id": record_id,
                "source": kind,
                "project": project,
                "commit": commit,
                "commit_field": commit_field,
                "language": language,
                "row_numbers": [],
                "selected_rows": 0,
            }
            order.append(key)
            output_keys.append(key)

        included_logical[logical_key] = output_keys
        included_count += 1
        for key in output_keys:
            records[key]["row_numbers"].append(row_number)
            if row.get("selected") is True:
                records[key]["selected_rows"] += 1

if not order:
    raise ValueError("dataset produced no build records")

manifest.parent.mkdir(parents=True, exist_ok=True)
with manifest.open("w", encoding="utf-8") as manifest_file:
    for key in order:
        record = records[key]
        manifest_file.write(json.dumps(record, ensure_ascii=False) + "\n")
        print(
            record["record_id"],
            record["project"],
            record["commit"],
            record["language"],
            record["source"],
            record["commit_field"],
            ",".join(map(str, record["row_numbers"])),
            sep="\t",
        )
PY

if [[ "$DRY_RUN" == 0 ]] && awk -F'\t' '$4 == "java" { found=1 } END { exit found ? 0 : 1 }' "$records_tsv"; then
  if ! grep -Eq '^enableJavaFrontend *= *true\b' "$CPG_REPO_DIR/gradle.properties" 2>/dev/null; then
    echo "Dataset contains Java projects, but Fraunhofer CPG was built without Java frontend." >&2
    echo "Set ENABLE_JAVA_FRONTEND=true in config/.env and run ./init.sh once." >&2
    exit 2
  fi
fi

echo "Run=$RUN_ID dataset=$DATASET records=$(wc -l < "$records_tsv" | tr -d ' ') timeout=${MAX_CPG_SECONDS}s target=$TASKS_TARGET commit_fields=$TASKS_COMMIT_FIELDS start=$TASKS_START"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "Dry run: records were parsed, no repositories cloned, no CPG built."
  echo "Manifest: $MANIFEST_JSONL"
  exit 0
fi
while IFS=$'\t' read -r record_id project commit language source_kind commit_field row_numbers; do
  short_commit="${commit:0:12}"
  repo_dir="$RUN_REPOS_DIR/$record_id"
  out_file="$RUN_OUT_DIR/$record_id.json"
  log_file="$RUN_LOG_DIR/$record_id.log"
  active_container="cpg-${record_id:0:48}-$$"

  if [[ "$SKIP_EXISTING" == 1 && -s "$out_file" ]]; then
    echo "Skip $record_id"
    active_container=""
    continue
  fi

  started="$(python3 -c 'import time; print(time.time())')"; started_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$repo_dir"
  docker run --rm -e PROJECT="$project" -e COMMIT="$commit" -v "$repo_dir:/repo" "$DOCKER_IMAGE" bash -lc '
    set -euo pipefail
    git config --global --add safe.directory /repo
    if ! git -C /repo rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      find /repo -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      git clone "https://github.com/$PROJECT.git" /repo
    fi
    git -C /repo fetch --all --tags --prune
    git -C /repo checkout --force "$COMMIT"
    git -C /repo clean -fdx
  '
  cloned="$(python3 -c 'import time; print(time.time())')"; docker_summary="$(mktemp)"

  docker run --rm --name "$active_container" \
    -e CPG_ANALYSIS_MODE -e MAX_COMPLEXITY_CF_DFG -e CUSTOM_PASS_LIST \
    -e CPG_EXCLUSION_PATTERNS -e CPG_EXTRA_ARGS -e CPG_JAVA_MAIN_ONLY \
    -e JEP_LIBRARY_PATH -e JEP_PYTHON_PATH -e MAX_CPG_SECONDS \
    -e SOURCE_LANGUAGE="$language" \
    -v "$CPG_REPO_DIR:/cpg:ro" -v "$repo_dir:/src:ro" -v "$RUN_OUT_DIR:/out" \
    "$DOCKER_IMAGE" bash -lc '
      set -euo pipefail
      export LD_LIBRARY_PATH="${JEP_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
      export PYTHONPATH="${JEP_PYTHON_PATH}:${PYTHONPATH:-}"
      export JAVA_OPTS="${JAVA_OPTS:-} -Djava.library.path=${JEP_LIBRARY_PATH}"
      args=()
      [[ "$CPG_ANALYSIS_MODE" == full ]] || args=(--no-default-passes "--custom-pass-list=${CUSTOM_PASS_LIST}" "--max-complexity-cf-dfg=${MAX_COMPLEXITY_CF_DFG}")
      exclusion_args=()
      if [[ -n "$CPG_EXCLUSION_PATTERNS" ]]; then
        IFS="," read -r -a patterns <<< "$CPG_EXCLUSION_PATTERNS"
        for pattern in "${patterns[@]}"; do
          [[ -z "$pattern" ]] || exclusion_args+=("--exclusion-patterns=${pattern}")
        done
      fi
      extra_args=()
      if [[ -n "$CPG_EXTRA_ARGS" ]]; then
        read -r -a extra_args <<< "$CPG_EXTRA_ARGS"
      fi
      source_args=(/src)
      if [[ "$SOURCE_LANGUAGE" == java && "$CPG_JAVA_MAIN_ONLY" == 1 ]]; then
        mapfile -d "" -t source_args < <(find /src -path "*/src/main/java/*.java" -type f -print0 | sort -z)
        if [[ "${#source_args[@]}" -eq 0 ]]; then
          echo "No Java source files found under */src/main/java for /src" >&2
          exit 2
        fi
      fi
      timeout --signal=TERM --kill-after=30s "$MAX_CPG_SECONDS" \
        /cpg/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j \
        --no-neo4j "${args[@]}" "${exclusion_args[@]}" "${extra_args[@]}" \
        --top-level=/src --export-json="/out/'"$(basename "$out_file")"'" "${source_args[@]}"
    ' > "$log_file" 2>&1 &
  analysis_pid=$!
  python3 "$ROOT/scripts/monitor_docker_stats.py" --container "$active_container" \
    --project "$project" --commit "$commit#$source_kind#$commit_field#$row_numbers" --samples-csv "$DOCKER_SAMPLES_CSV" \
    --summary-json "$docker_summary" --interval "$STATS_INTERVAL_SECONDS" &
  monitor_pid=$!

  exit_code=0; wait "$analysis_pid" || exit_code=$?
  case "$exit_code" in 0) status=success;; 124|137) status=timed_out;; *) status=failed;; esac
  wait "$monitor_pid" || echo "Statistics monitor failed: $record_id" >&2
  active_container=""
  finished="$(python3 -c 'import time; print(time.time())')"; finished_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  read -r total clone cpg < <(python3 - "$started" "$cloned" "$finished" <<'PY'
import sys
a, b, c = map(float, sys.argv[1:]); print(c-a, b-a, c-b)
PY
  )
  python3 "$ROOT/scripts/record_commit_metrics.py" --csv "$METRICS_CSV" --summary-json "$docker_summary" \
    --project "$project" --commit "$commit#$source_kind#$commit_field#$record_id" --language "$language" --status "$status" \
    --started-at-utc "$started_utc" --finished-at-utc "$finished_utc" \
    --total-seconds "$total" --clone-seconds "$clone" --cpg-seconds "$cpg" \
    --repo "$repo_dir" --cpg-repo "$CPG_REPO_DIR" --output "$out_file" \
    --output-dir "$RUN_OUT_DIR" --log "$log_file" --image "$DOCKER_IMAGE"
  rm -f "$docker_summary"; docker_summary=""

  if [[ "$status" != success ]]; then
    [[ ! -e "$out_file" ]] || mv "$out_file" "$out_file.partial-$(date -u +'%Y%m%dT%H%M%SZ')"
    echo "$status $record_id $project@$short_commit (exit=$exit_code)" >&2
  else
    echo "Saved $out_file"
  fi
done < "$records_tsv"

echo "Done: $RUN_OUT_DIR"
echo "Logs: $RUN_LOG_DIR"
echo "Metrics: $METRICS_CSV"
echo "Manifest: $MANIFEST_JSONL"
