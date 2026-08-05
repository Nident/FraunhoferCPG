#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT"
ENV_FILE="${ENV_FILE:-$ROOT/config/.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing env file: $ENV_FILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

require() { [[ -n "${!1:-}" ]] || { echo "Missing required variable: $1" >&2; exit 2; }; }
for name in CPG_REPO_DIR CPG_GIT_URL CPG_REF DOCKER_IMAGE; do
  require "$name"
done

command -v docker >/dev/null || { echo "Missing command: docker" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 2; }

mkdir -p "$CPG_REPO_DIR"

echo "[1/3] Building Docker image: $DOCKER_IMAGE"
docker build --load -t "$DOCKER_IMAGE" "$ROOT"
docker image inspect "$DOCKER_IMAGE" >/dev/null || { echo "Docker image was not loaded correctly: $DOCKER_IMAGE" >&2; exit 1; }

echo "[2/3] Cloning Fraunhofer CPG: $CPG_REF"
docker run --rm \
  -e CPG_GIT_URL -e CPG_REF \
  -v "$CPG_REPO_DIR:/cpg" \
  "$DOCKER_IMAGE" bash -lc '
    set -euo pipefail
    git config --global --add safe.directory /cpg
    if ! git -C /cpg rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      find /cpg -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      git clone "$CPG_GIT_URL" /cpg
    fi
    git -C /cpg fetch --all --tags --prune
    git -C /cpg checkout --force "$CPG_REF"
    git -C /cpg clean -fdx
    [[ -f /cpg/gradle.properties ]] || cp /cpg/gradle.properties.example /cpg/gradle.properties
  '

echo "[3/3] Building cpg-neo4j"
docker run --rm \
  -v "$CPG_REPO_DIR:/cpg" -w /cpg \
  "$DOCKER_IMAGE" bash -lc '
    set -euo pipefail
    ./gradlew --no-daemon :cpg-neo4j:installDist -x test
  '

CPG_BIN="$CPG_REPO_DIR/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j"
[[ -x "$CPG_BIN" ]] || { echo "Build did not create: $CPG_BIN" >&2; exit 1; }
echo "Initialization complete"
