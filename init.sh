#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT"
ENV_FILE="${ENV_FILE:-$ROOT/config/.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing env file: $ENV_FILE" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

require() { [[ -n "${!1:-}" ]] || { echo "Missing required variable: $1" >&2; exit 2; }; }
for name in CPG_REPO_DIR CPG_GIT_URL CPG_REF DOCKER_IMAGE \
  ENABLE_JAVA_FRONTEND ENABLE_CXX_FRONTEND ENABLE_GO_FRONTEND \
  ENABLE_PYTHON_FRONTEND ENABLE_LLVM_FRONTEND ENABLE_TYPESCRIPT_FRONTEND \
  ENABLE_RUBY_FRONTEND ENABLE_JVM_FRONTEND ENABLE_INI_FRONTEND ENABLE_MCP_MODULE; do
  require "$name"
done
for name in ENABLE_JAVA_FRONTEND ENABLE_CXX_FRONTEND ENABLE_GO_FRONTEND \
  ENABLE_PYTHON_FRONTEND ENABLE_LLVM_FRONTEND ENABLE_TYPESCRIPT_FRONTEND \
  ENABLE_RUBY_FRONTEND ENABLE_JVM_FRONTEND ENABLE_INI_FRONTEND ENABLE_MCP_MODULE; do
  [[ "${!name}" =~ ^(true|false)$ ]] || { echo "$name must be true or false" >&2; exit 2; }
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
    [[ -d /cpg/.git ]] || git clone "$CPG_GIT_URL" /cpg
    git -C /cpg fetch --tags origin
    git -C /cpg checkout --force "$CPG_REF"
    git -C /cpg pull --ff-only origin "$CPG_REF" || true
  '

echo "[3/3] Building cpg-neo4j"
docker run --rm \
  -e ENABLE_JAVA_FRONTEND -e ENABLE_CXX_FRONTEND -e ENABLE_GO_FRONTEND \
  -e ENABLE_PYTHON_FRONTEND -e ENABLE_LLVM_FRONTEND \
  -e ENABLE_TYPESCRIPT_FRONTEND -e ENABLE_RUBY_FRONTEND \
  -e ENABLE_JVM_FRONTEND -e ENABLE_INI_FRONTEND -e ENABLE_MCP_MODULE \
  -v "$CPG_REPO_DIR:/cpg" -w /cpg \
  "$DOCKER_IMAGE" bash -lc '
    set -euo pipefail
    [[ -f gradle.properties ]] || cp gradle.properties.example gradle.properties
    sed -i \
      -e "s/^\(enableJavaFrontend *= *\).*/\1${ENABLE_JAVA_FRONTEND}/" \
      -e "s/^\(enableCXXFrontend *= *\).*/\1${ENABLE_CXX_FRONTEND}/" \
      -e "s/^\(enableGoFrontend *= *\).*/\1${ENABLE_GO_FRONTEND}/" \
      -e "s/^\(enablePythonFrontend *= *\).*/\1${ENABLE_PYTHON_FRONTEND}/" \
      -e "s/^\(enableLLVMFrontend *= *\).*/\1${ENABLE_LLVM_FRONTEND}/" \
      -e "s/^\(enableTypeScriptFrontend *= *\).*/\1${ENABLE_TYPESCRIPT_FRONTEND}/" \
      -e "s/^\(enableRubyFrontend *= *\).*/\1${ENABLE_RUBY_FRONTEND}/" \
      -e "s/^\(enableJVMFrontend *= *\).*/\1${ENABLE_JVM_FRONTEND}/" \
      -e "s/^\(enableINIFrontend *= *\).*/\1${ENABLE_INI_FRONTEND}/" \
      -e "s/^\(enableMCPModule *= *\).*/\1${ENABLE_MCP_MODULE}/" \
      gradle.properties
    ./gradlew --no-daemon :cpg-neo4j:installDist -x test
  '

CPG_BIN="$CPG_REPO_DIR/cpg-neo4j/build/install/cpg-neo4j/bin/cpg-neo4j"
[[ -x "$CPG_BIN" ]] || { echo "Build did not create: $CPG_BIN" >&2; exit 1; }
echo "Initialization complete"
