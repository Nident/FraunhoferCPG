#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT"
ENV_FILE="${ENV_FILE:-$ROOT/config/.env}"
DEFAULT_DATASET_EXTERNAL="/Users/nident/Desktop/JOB/ScolTech/tasks 2.jsonl"
DEFAULT_DATASET_LOCAL="$ROOT/datasets/tasks 2.jsonl"
DEFAULT_DATASET="$DEFAULT_DATASET_EXTERNAL"
if [[ ! -f "$DEFAULT_DATASET" && -f "$DEFAULT_DATASET_LOCAL" ]]; then
  DEFAULT_DATASET="$DEFAULT_DATASET_LOCAL"
fi

[[ $# -le 1 ]] || { echo "Usage: $0 [DATASET.jsonl]" >&2; exit 2; }
DATASET="${1:-${SNIPPET_DATASET:-$DEFAULT_DATASET}}"
[[ -f "$DATASET" ]] || { echo "Dataset does not exist: $DATASET" >&2; exit 2; }
DATASET="$(cd "$(dirname "$DATASET")" && pwd)/$(basename "$DATASET")"
[[ -f "$ENV_FILE" ]] || { echo "Missing env file: $ENV_FILE" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

require() { [[ -n "${!1:-}" ]] || { echo "Missing required variable: $1" >&2; exit 2; }; }
for name in WORK_DIR CPG_REPO_DIR OUT_DIR LOG_DIR DOCKER_IMAGE \
  CPG_ANALYSIS_MODE MAX_COMPLEXITY_CF_DFG SKIP_EXISTING CUSTOM_PASS_LIST \
  STATS_INTERVAL_SECONDS MAX_CPG_SECONDS JEP_LIBRARY_PATH JEP_PYTHON_PATH; do
  require "$name"
done
[[ "$CPG_ANALYSIS_MODE" =~ ^(fast|full)$ ]] || { echo "CPG_ANALYSIS_MODE must be fast or full" >&2; exit 2; }
[[ "$SKIP_EXISTING" =~ ^(0|1)$ ]] || { echo "SKIP_EXISTING must be 0 or 1" >&2; exit 2; }
[[ "$MAX_COMPLEXITY_CF_DFG" =~ ^[1-9][0-9]*$ ]] || { echo "MAX_COMPLEXITY_CF_DFG must be a positive integer" >&2; exit 2; }
[[ "$MAX_CPG_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "MAX_CPG_SECONDS must be a positive integer" >&2; exit 2; }
SNIPPET_LIMIT="${SNIPPET_LIMIT:-0}"
[[ "$SNIPPET_LIMIT" =~ ^[0-9]+$ ]] || { echo "SNIPPET_LIMIT must be a non-negative integer" >&2; exit 2; }
for command in docker python3; do command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 2; }; done
python3 - "$STATS_INTERVAL_SECONDS" <<'PY' || { echo "STATS_INTERVAL_SECONDS must be a positive number" >&2; exit 2; }
import sys
assert float(sys.argv[1]) > 0
PY
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 2; }
docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1 || { echo "Missing image $DOCKER_IMAGE; run ./init.sh" >&2; exit 2; }
CPG_BIN="$CPG_REPO_DIR/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j"
[[ -x "$CPG_BIN" ]] || { echo "Missing $CPG_BIN; run ./init.sh" >&2; exit 2; }

dataset_name="$(basename "$DATASET")"; dataset_name="${dataset_name%.*}"; dataset_name="${dataset_name// /_}"
RUN_ID="${RUN_ID:-${dataset_name}_vuln_snippets}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "RUN_ID contains invalid characters: $RUN_ID" >&2; exit 2; }
RUN_SNIPPETS_DIR="$WORK_DIR/snippets/$RUN_ID"
RUN_OUT_DIR="$OUT_DIR/$RUN_ID"
RUN_LOG_DIR="$LOG_DIR/$RUN_ID"
METRICS_CSV="$RUN_LOG_DIR/commit_metrics.csv"
DOCKER_SAMPLES_CSV="$RUN_LOG_DIR/docker_samples.csv"
MANIFEST_JSONL="$RUN_LOG_DIR/snippet_manifest.jsonl"
records_tsv="$(mktemp)"
active_container=""
docker_summary=""

cleanup() {
  [[ -z "$active_container" ]] || docker rm -f "$active_container" >/dev/null 2>&1 || true
  rm -f "$records_tsv"
  [[ -z "$docker_summary" ]] || rm -f "$docker_summary"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$RUN_SNIPPETS_DIR" "$RUN_OUT_DIR" "$RUN_LOG_DIR"
: > "$MANIFEST_JSONL"

python3 - "$DATASET" "$RUN_SNIPPETS_DIR" "$MANIFEST_JSONL" "$SNIPPET_LIMIT" > "$records_tsv" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

dataset = pathlib.Path(sys.argv[1])
snippets_root = pathlib.Path(sys.argv[2])
manifest = pathlib.Path(sys.argv[3])
limit = int(sys.argv[4])

def clean(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("_")

def guess_language(code: str) -> tuple[str, str]:
    text = code.strip()
    if re.search(r"\b(class|interface|enum)\s+[A-Za-z_$][\w$]*\s*[{\n]", text) or re.search(r"\b(public|private|protected|final|static)\b", text):
        match = re.search(r"\b(?:public\s+)?(?:abstract\s+|final\s+)?(?:class|interface|enum)\s+([A-Za-z_$][\w$]*)", text)
        return "java", f"{match.group(1) if match else 'Snippet'}.java"
    if re.search(r"^(def|class|import|from)\s+", text, re.MULTILINE):
        return "python", "snippet.py"
    raise ValueError("cannot infer snippet language")

count = 0
with manifest.open("w", encoding="utf-8") as manifest_file:
    for row_number, line in enumerate(dataset.open(encoding="utf-8"), start=1):
        if not line.strip():
            continue
        obj = json.loads(line)
        vuln = obj.get("vuln")
        if not isinstance(vuln, dict):
            raise TypeError(f"line {row_number}: missing object field vuln")
        project = vuln.get("project")
        commit = vuln.get("vuln_commit")
        snippets = vuln.get("snippets")
        if not isinstance(project, str) or not re.fullmatch(r"[^/\s]+/[^/\s]+", project):
            raise TypeError(f"line {row_number}: invalid vuln.project: {project!r}")
        if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-fA-F]{7,64}", commit):
            raise TypeError(f"line {row_number}: invalid vuln.vuln_commit: {commit!r}")
        if not isinstance(snippets, list):
            raise TypeError(f"line {row_number}: invalid vuln.snippets")

        for snippet_index, snippet_obj in enumerate(snippets, start=1):
            if limit and count >= limit:
                raise SystemExit
            if not isinstance(snippet_obj, dict):
                raise TypeError(f"line {row_number}, snippet {snippet_index}: snippet item is not an object")
            code = snippet_obj.get("vuln_snippet")
            if not isinstance(code, str) or not code.strip():
                raise TypeError(f"line {row_number}, snippet {snippet_index}: missing vuln_snippet")

            language, file_name = guess_language(code)
            short_hash = hashlib.sha1(code.encode("utf-8")).hexdigest()[:10]
            snippet_id = f"{row_number:06d}__{clean(project.replace('/', '__'))}__{commit[:12]}__s{snippet_index:03d}__{short_hash}"
            snippet_dir = snippets_root / snippet_id
            snippet_dir.mkdir(parents=True, exist_ok=True)
            source_file = snippet_dir / file_name
            source_file.write_text(code.rstrip() + "\n", encoding="utf-8")

            out_base = f"{snippet_id}.json"
            log_base = f"{snippet_id}.log"
            item = {
                "snippet_id": snippet_id,
                "row_number": row_number,
                "snippet_index": snippet_index,
                "project": project,
                "vuln_id": vuln.get("id", ""),
                "vuln_commit": commit,
                "safe_commit": vuln.get("safe_commit", ""),
                "task_project": obj.get("task", {}).get("project", "") if isinstance(obj.get("task"), dict) else "",
                "language": language,
                "source_file": str(source_file),
                "output_file": out_base,
                "log_file": log_base,
            }
            manifest_file.write(json.dumps(item, ensure_ascii=False) + "\n")
            print(snippet_id, project, commit, language, str(snippet_dir), file_name, out_base, log_base, sep="\t")
            count += 1

if count == 0:
    raise ValueError("dataset contains no vuln_snippet values")
PY

if awk -F'\t' '$4 == "java" { found=1 } END { exit found ? 0 : 1 }' "$records_tsv"; then
  if ! grep -Eq '^enableJavaFrontend *= *true\b' "$CPG_REPO_DIR/gradle.properties" 2>/dev/null; then
    echo "Dataset contains Java vuln_snippet values, but Fraunhofer CPG was built without Java frontend." >&2
    echo "Set ENABLE_JAVA_FRONTEND=true in config/.env and run ./init.sh once." >&2
    exit 2
  fi
fi

echo "Run=$RUN_ID dataset=$DATASET snippets=$(wc -l < "$records_tsv" | tr -d ' ')"
while IFS=$'\t' read -r snippet_id project commit language snippet_dir source_name out_base log_base; do
  out_file="$RUN_OUT_DIR/$out_base"
  log_file="$RUN_LOG_DIR/$log_base"
  active_container="cpg-snippet-${snippet_id:0:36}-$$"

  if [[ "$SKIP_EXISTING" == 1 && -s "$out_file" ]]; then
    echo "Skip $snippet_id"
    active_container=""
    continue
  fi

  started="$(python3 -c 'import time; print(time.time())')"
  started_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  docker_summary="$(mktemp)"

  docker run --rm --name "$active_container" \
    -e CPG_ANALYSIS_MODE -e MAX_COMPLEXITY_CF_DFG -e CUSTOM_PASS_LIST \
    -e JEP_LIBRARY_PATH -e JEP_PYTHON_PATH -e MAX_CPG_SECONDS \
    -v "$CPG_REPO_DIR:/cpg:ro" -v "$snippet_dir:/src:ro" -v "$RUN_OUT_DIR:/out" \
    "$DOCKER_IMAGE" bash -lc '
      set -euo pipefail
      export LD_LIBRARY_PATH="${JEP_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
      export PYTHONPATH="${JEP_PYTHON_PATH}:${PYTHONPATH:-}"
      export JAVA_OPTS="${JAVA_OPTS:-} -Djava.library.path=${JEP_LIBRARY_PATH}"
      args=()
      [[ "$CPG_ANALYSIS_MODE" == full ]] || args=(--no-default-passes "--custom-pass-list=${CUSTOM_PASS_LIST}" "--max-complexity-cf-dfg=${MAX_COMPLEXITY_CF_DFG}")
      timeout --signal=TERM --kill-after=30s "$MAX_CPG_SECONDS" \
        /cpg/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j \
        --no-neo4j "${args[@]}" --top-level=/src --export-json="/out/'"$out_base"'" "/src/'"$source_name"'"
    ' > "$log_file" 2>&1 &
  analysis_pid=$!
  python3 "$ROOT/scripts/monitor_docker_stats.py" --container "$active_container" \
    --project "$project" --commit "$commit#$snippet_id" --samples-csv "$DOCKER_SAMPLES_CSV" \
    --summary-json "$docker_summary" --interval "$STATS_INTERVAL_SECONDS" &
  monitor_pid=$!

  exit_code=0
  wait "$analysis_pid" || exit_code=$?
  case "$exit_code" in 0) status=success;; 124|137) status=timed_out;; *) status=failed;; esac
  wait "$monitor_pid" || echo "Statistics monitor failed: $snippet_id" >&2
  active_container=""
  finished="$(python3 -c 'import time; print(time.time())')"
  finished_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  seconds="$(python3 - "$started" "$finished" <<'PY'
import sys
a, b = map(float, sys.argv[1:])
print(b - a)
PY
  )"

  python3 "$ROOT/scripts/record_commit_metrics.py" --csv "$METRICS_CSV" --summary-json "$docker_summary" \
    --project "$project" --commit "$commit#$snippet_id" --language "$language" --status "$status" \
    --started-at-utc "$started_utc" --finished-at-utc "$finished_utc" \
    --total-seconds "$seconds" --clone-seconds 0 --cpg-seconds "$seconds" \
    --repo "$snippet_dir" --cpg-repo "$CPG_REPO_DIR" --output "$out_file" \
    --output-dir "$RUN_OUT_DIR" --log "$log_file" --image "$DOCKER_IMAGE"
  rm -f "$docker_summary"; docker_summary=""

  if [[ "$status" != success ]]; then
    [[ ! -e "$out_file" ]] || mv "$out_file" "$out_file.partial-$(date -u +'%Y%m%dT%H%M%SZ')"
    echo "$status $snippet_id (exit=$exit_code)" >&2
  else
    echo "Saved $out_file"
  fi
done < "$records_tsv"

echo "Done: $RUN_OUT_DIR"
echo "Logs: $RUN_LOG_DIR"
echo "Metrics: $METRICS_CSV"
echo "Manifest: $MANIFEST_JSONL"
