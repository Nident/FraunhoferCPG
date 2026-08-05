#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT"
ENV_FILE="${ENV_FILE:-$ROOT/config/.env}"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./build_fraunhofer_cpg.sh OWNER/REPO COMMIT [OUT.json]

Example:
  ./build_fraunhofer_cpg.sh apache/zookeeper 6a0e0ea09bae7d07d98b58a647d25afef2a8988f
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

command -v docker >/dev/null || { echo "Missing command: docker" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 2; }
docker run --rm "$DOCKER_IMAGE" true >/dev/null 2>&1 || { echo "Cannot run image $DOCKER_IMAGE; run ./init.sh" >&2; exit 2; }

CPG_BIN="$CPG_REPO_DIR/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j"
[[ -x "$CPG_BIN" ]] || { echo "Missing $CPG_BIN; run ./init.sh" >&2; exit 2; }

safe_project="${PROJECT//\//__}"
short_commit="${COMMIT:0:12}"
record_id="${safe_project}__${short_commit}"
repo_dir="$REPOS_DIR/$record_id"

if [[ -n "$OUT_FILE_ARG" ]]; then
  mkdir -p "$(dirname "$OUT_FILE_ARG")"
  OUT_FILE="$(cd "$(dirname "$OUT_FILE_ARG")" && pwd)/$(basename "$OUT_FILE_ARG")"
else
  mkdir -p "$OUT_DIR"
  OUT_FILE="$OUT_DIR/$record_id.json"
fi

out_dir="$(dirname "$OUT_FILE")"
out_base="$(basename "$OUT_FILE")"
mkdir -p "$repo_dir" "$out_dir"

echo "[1/2] Clone and checkout: https://github.com/$PROJECT.git@$COMMIT"
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
  '

echo "[2/2] Build CPG JSON: $OUT_FILE"
docker run --rm \
  -e JEP_LIBRARY_PATH -e JEP_PYTHON_PATH \
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
      --export-json="/out/'"$out_base"'" \
      /src
  '

echo "Saved: $OUT_FILE"
