# Clean Fraunhofer CPG Runner

Minimal wrapper around upstream Fraunhofer CPG:

1. clone Fraunhofer CPG into `work/cpg`;
2. build `cpg-neo4j` inside Docker;
3. clone a target GitHub repository at a commit;
4. run `cpg-neo4j` on the repository root;
5. export the CPG to JSON.

There are no dataset transforms, exclusion regexes, custom pass lists, source
slicing, metrics collectors, or Docker stats monitors in this copy.

## Initialize

```bash
./init.sh
```

This builds the Docker image, clones `https://github.com/Fraunhofer-AISEC/cpg.git`
into `work/cpg`, checks out `CPG_REF`, and runs:

```bash
./gradlew --no-daemon :cpg-neo4j:installDist -x test
```

Configuration lives in `config/.env`.
The script copies upstream `gradle.properties.example` to `gradle.properties`
when needed, but does not rewrite frontend flags.

## Build CPG JSON

```bash
./build_fraunhofer_cpg.sh OWNER/REPO COMMIT [OUT.json]
```

Example:

```bash
./build_fraunhofer_cpg.sh apache/zookeeper 6a0e0ea09bae7d07d98b58a647d25afef2a8988f
```

Default output:

```text
cpg-output/OWNER__REPO__COMMIT12.json
```

The CPG command is intentionally plain:

```bash
cpg-neo4j --no-neo4j --top-level=/src --export-json=/out/result.json /src
```

## Best-Effort Build

Use this when upstream Fraunhofer CPG crashes on a specific Java file and you
want to continue with an incomplete graph:

```bash
./build_fraunhofer_cpg_best_effort.sh OWNER/REPO COMMIT [OUT.json]
```

The script:

1. clones and checks out the repository;
2. builds an explicit source file list;
3. runs `cpg-neo4j` on that list;
4. when CPG crashes, reads the last `TranslationManager Parsing /src/...` line;
5. removes that file from the next attempt;
6. repeats until JSON is exported or `MAX_RETRIES` is reached.

Example:

```bash
./build_fraunhofer_cpg_best_effort.sh apache/zookeeper 6a0e0ea09bae7d07d98b58a647d25afef2a8988f
```

Useful environment variables:

```bash
MAX_RETRIES=5
PRECHECK_FILES=1
SOURCE_GLOB='./zookeeper-server/src/main/java/*.java'
```

With `PRECHECK_FILES=1`, the script first runs CPG on each source file by
itself. Files that fail this one-file check are written to `excluded_files.txt`.
Then the script runs one combined CPG build on all remaining files. If the
combined build still fails, it falls back to the normal retry behavior and
skips the last file reported by `TranslationManager Parsing /src/...`.
`MAX_RETRIES` limits those combined-build fallback retries; precheck files are
not counted against it.

Skipped files and attempt logs are saved under:

```text
cpg-output/OWNER__REPO__COMMIT12.best-effort/
```

## Dataset Best-Effort Build

Run best-effort CPG generation for records from a JSONL dataset:

```bash
./build_dataset_best_effort.sh
```

Dataset defaults live in `config/.env`:

```text
DATASET=datasets/tasks 3.jsonl
DATASET_TARGET=vuln
DATASET_COMMIT_FIELDS=vuln_commit,safe_commit
DATASET_START=1
DATASET_LIMIT=0
RUN_ID=tasks3_vuln_main
SKIP_EXISTING=1
PRECHECK_FILES=1
SOURCE_GLOB=./*/src/main/java/*.java
MAX_RETRIES=5
```

Check selected records without building:

```bash
DRY_RUN=1 DATASET_LIMIT=10 ./build_dataset_best_effort.sh
```

Run in chunks:

```bash
DATASET_START=1 DATASET_LIMIT=20 RUN_ID=tasks3_001_020 ./build_dataset_best_effort.sh
DATASET_START=21 DATASET_LIMIT=20 RUN_ID=tasks3_021_040 ./build_dataset_best_effort.sh
```

Outputs are saved under:

```text
cpg-output/<RUN_ID>.dataset/
```

Metrics are also written in the old runner format:

```text
cpg-output/<RUN_ID>.dataset/commit_metrics.csv
cpg-output/<RUN_ID>.dataset/docker_samples.csv
cpg-output/<RUN_ID>.dataset/summary.csv
```
