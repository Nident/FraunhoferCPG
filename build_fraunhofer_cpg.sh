#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATASET="${DATASET:-/Users/nident/Desktop/JOB/ScolTech/tp_fp_two_projects.json}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
REPOS_DIR="${REPOS_DIR:-$WORK_DIR/repos}"
CPG_REPO_DIR="${CPG_REPO_DIR:-$WORK_DIR/cpg}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/cpg-output}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

CPG_GIT_URL="${CPG_GIT_URL:-https://github.com/Fraunhofer-AISEC/cpg.git}"
CPG_REF="${CPG_REF:-main}"
DOCKER_IMAGE="${DOCKER_IMAGE:-fraunhofer-cpg-runner:local}"
CPG_ANALYSIS_MODE="${CPG_ANALYSIS_MODE:-fast}"
MAX_COMPLEXITY_CF_DFG="${MAX_COMPLEXITY_CF_DFG:-50}"
SKIP_EXISTING="${SKIP_EXISTING:-1}"

if [[ ! -f "$DATASET" ]]; then
  echo "Dataset file does not exist: $DATASET" >&2
  exit 1
fi

DATASET="$(cd "$(dirname "$DATASET")" && pwd)/$(basename "$DATASET")"

mkdir -p "$WORK_DIR" "$REPOS_DIR" "$CPG_REPO_DIR" "$OUT_DIR" "$LOG_DIR"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd docker

echo "[1/5] Building Docker image: $DOCKER_IMAGE"
docker build -t "$DOCKER_IMAGE" "$SCRIPT_DIR"

echo "[2/5] Preparing Fraunhofer CPG sources: $CPG_REF"
docker run --rm \
  -e CPG_GIT_URL="$CPG_GIT_URL" \
  -e CPG_REF="$CPG_REF" \
  -v "$CPG_REPO_DIR:/cpg" \
  "$DOCKER_IMAGE" \
  bash -lc '
    set -euo pipefail
    git config --global --add safe.directory /cpg
    if [[ ! -d /cpg/.git ]]; then
      git clone "$CPG_GIT_URL" /cpg
    fi
    git -C /cpg fetch --tags origin
    git -C /cpg checkout "$CPG_REF"
    git -C /cpg pull --ff-only origin "$CPG_REF" || true
  '

echo "[3/5] Building cpg-neo4j distribution inside Docker"
docker run --rm \
  -v "$CPG_REPO_DIR:/cpg" \
  -w /cpg \
  "$DOCKER_IMAGE" \
  bash -lc '
    set -euo pipefail
    if [[ -f gradle.properties.example && ! -f gradle.properties ]]; then
      cp gradle.properties.example gradle.properties
    fi
    sed -i \
      -e "s/^\(enableJavaFrontend[[:space:]]*=[[:space:]]*\).*/\1false/" \
      -e "s/^\(enableCXXFrontend[[:space:]]*=[[:space:]]*\).*/\1false/" \
      -e "s/^\(enableGoFrontend[[:space:]]*=[[:space:]]*\).*/\1false/" \
      -e "s/^\(enablePythonFrontend[[:space:]]*=[[:space:]]*\).*/\1true/" \
      -e "s/^\(enableLLVMFrontend[[:space:]]*=[[:space:]]*\).*/\1false/" \
      -e "s/^\(enableTypeScriptFrontend[[:space:]]*=[[:space:]]*\).*/\1false/" \
      -e "s/^\(enableRubyFrontend[[:space:]]*=[[:space:]]*\).*/\1false/" \
      -e "s/^\(enableJVMFrontend[[:space:]]*=[[:space:]]*\).*/\1false/" \
      -e "s/^\(enableINIFrontend[[:space:]]*=[[:space:]]*\).*/\1false/" \
      -e "s/^\(enableMCPModule[[:space:]]*=[[:space:]]*\).*/\1false/" \
      gradle.properties
    ./gradlew --no-daemon :cpg-neo4j:installDist -x test
  '

CPG_BIN="$CPG_REPO_DIR/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j"
if [[ ! -x "$CPG_BIN" ]]; then
  echo "cpg-neo4j binary was not built: $CPG_BIN" >&2
  exit 1
fi

records_tsv="$(mktemp)"
trap 'rm -f "$records_tsv"' EXIT

echo "[4/5] Reading dataset inside Docker: $DATASET"
docker run --rm -i \
  -v "$DATASET:/dataset.json:ro" \
  "$DOCKER_IMAGE" \
  python3 - /dataset.json > "$records_tsv" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

def emit_record(obj):
    records = obj.get("records", [obj])
    for record in records:
        language = record.get("dataset_record", {}).get("language", "")
        for item in record.get("results", []):
            project = item["project"]
            commit = item["commit"]
            verdict = item.get("verdict", "")
            print("\t".join([project, commit, verdict, language]))

try:
    data = json.loads(text)
    emit_record(data)
except json.JSONDecodeError:
    for line in text.splitlines():
        if line.strip():
            emit_record(json.loads(line))
PY

if [[ ! -s "$records_tsv" ]]; then
  echo "No project/commit records found in dataset: $DATASET" >&2
  exit 1
fi

echo "[5/5] Cloning projects and exporting CPG JSON files"
while IFS=$'\t' read -r project commit verdict language; do
  safe_project="${project//\//__}"
  repo_dir="$REPOS_DIR/$safe_project"
  short_commit="${commit:0:12}"
  out_file="$OUT_DIR/${safe_project}__${verdict}__${short_commit}.json"
  log_file="$LOG_DIR/${safe_project}__${verdict}__${short_commit}.log"

  echo "Project=$project commit=$commit verdict=$verdict language=$language"

  if [[ "$SKIP_EXISTING" == "1" && -s "$out_file" ]]; then
    echo "Skipping existing output: $out_file"
    continue
  fi

  mkdir -p "$repo_dir"

  docker run --rm \
    -e PROJECT="$project" \
    -e COMMIT="$commit" \
    -v "$repo_dir:/repo" \
    "$DOCKER_IMAGE" \
    bash -lc '
      set -euo pipefail
      git config --global --add safe.directory /repo
      if [[ ! -d /repo/.git ]]; then
        git clone "https://github.com/$PROJECT.git" /repo
      fi
      git -C /repo fetch --all --tags --prune
      git -C /repo checkout --force "$COMMIT"
      git -C /repo clean -fdx
    '

  docker run --rm \
    -e CPG_ANALYSIS_MODE="$CPG_ANALYSIS_MODE" \
    -e MAX_COMPLEXITY_CF_DFG="$MAX_COMPLEXITY_CF_DFG" \
    -v "$CPG_REPO_DIR:/cpg:ro" \
    -v "$repo_dir:/src:ro" \
    -v "$OUT_DIR:/out" \
    "$DOCKER_IMAGE" \
    bash -lc '
      set -euo pipefail
      export LD_LIBRARY_PATH="${JEP_LIBRARY_PATH:-/root/.virtualenvs/cpg/lib/python3.14/site-packages/jep}:${LD_LIBRARY_PATH:-}"
      export PYTHONPATH="${PYTHONPATH:-/root/.virtualenvs/cpg/lib/python3.14/site-packages}"
      export JAVA_OPTS="${JAVA_OPTS:-} -Djava.library.path=${JEP_LIBRARY_PATH:-/root/.virtualenvs/cpg/lib/python3.14/site-packages/jep}"

      cpg_args=()
      case "${CPG_ANALYSIS_MODE:-fast}" in
        fast)
          cpg_args+=(
            --no-default-passes
            --custom-pass-list=TypeHierarchyResolver,SymbolResolver,DFGPass,EvaluationOrderGraphPass,TypeResolver,ControlFlowSensitiveDFGPass,ControlDependenceGraphPass,ProgramDependenceGraphPass
            "--max-complexity-cf-dfg=${MAX_COMPLEXITY_CF_DFG:-50}"
          )
          ;;
        full)
          ;;
        *)
          echo "Unsupported CPG_ANALYSIS_MODE=${CPG_ANALYSIS_MODE}. Use fast or full." >&2
          exit 1
          ;;
      esac

      /cpg/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j \
        --no-neo4j \
        "${cpg_args[@]}" \
        --top-level=/src \
        --export-json="/out/'"$(basename "$out_file")"'" \
        /src
    ' >"$log_file" 2>&1

  echo "Saved: $out_file"
  echo "Log:   $log_file"
done < "$records_tsv"

echo "Done. CPG exports are in: $OUT_DIR"
