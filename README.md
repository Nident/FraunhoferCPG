# Fraunhofer CPG dataset runner

Builds Fraunhofer AISEC CPG in Docker, clones every project/commit from the dataset, and exports a CPG JSON file with `cpg-neo4j --export-json --no-neo4j`.

```bash
cd /Users/nident/Desktop/JOB/ScolTech/FraunhoferCPG_test
chmod +x build_fraunhofer_cpg.sh
./build_fraunhofer_cpg.sh
```

Only Docker is required on the host. Python, JEP, Git operations, and Fraunhofer CPG all run inside the container.

By default the runner uses `CPG_ANALYSIS_MODE=fast`, which avoids the Python concept pass that can hang on large projects such as `open-webui/open-webui`. To force the full default Fraunhofer pass list:

```bash
CPG_ANALYSIS_MODE=full ./build_fraunhofer_cpg.sh
```

Existing non-empty JSON outputs are skipped by default. Rebuild them with:

```bash
SKIP_EXISTING=0 ./build_fraunhofer_cpg.sh
```

Defaults:

- dataset: `/Users/nident/Desktop/JOB/ScolTech/tp_fp_two_projects.json`
- cloned projects: `work/repos`
- Fraunhofer CPG source/build: `work/cpg`
- exported CPG files: `cpg-output`
- logs: `logs`

Useful overrides:

```bash
DATASET=/path/to/dataset.jsonl ./build_fraunhofer_cpg.sh
CPG_REF=v10.8.2 ./build_fraunhofer_cpg.sh
OUT_DIR=/tmp/cpg-output ./build_fraunhofer_cpg.sh
```
