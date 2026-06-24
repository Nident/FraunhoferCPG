# Fraunhofer CPG dataset runner

Fraunhofer CPG is initialized once. Dataset workers can then run in parallel
without rebuilding Gradle or changing a shared repository checkout.

## 1. Initialize

Configure `config/.env`, then run:

```bash
./init.sh
```

This command builds the Docker image, clones Fraunhofer CPG into `work/cpg`,
and builds `cpg-neo4j`. Run it again only after changing `CPG_REF`, Dockerfile,
or frontend settings.

## 2. Process datasets

The dataset is a required positional argument:

```bash
./build_fraunhofer_cpg.sh datasets/vuln_patches_10_20.json
```

Parallel example:

```bash
./build_fraunhofer_cpg.sh datasets/vuln_patches_10_20.json &
./build_fraunhofer_cpg.sh datasets/vuln_patches_20_21.json &
wait
```

Each dataset gets an isolated run directory:

```text
work/repos/<dataset>/
cpg-output/<dataset>/
logs/<dataset>/commit_metrics.csv
logs/<dataset>/docker_samples.csv
logs/<dataset>/*.log
```

Use a distinct `RUN_ID` when starting the same dataset more than once:

```bash
RUN_ID=experiment-2 ./build_fraunhofer_cpg.sh datasets/input.json
```

The worker fails immediately when its dataset, Docker image, CPG binary, or a
required/typed setting is invalid. `MAX_CPG_SECONDS` limits each commit to three
hours by default. A timeout is recorded as `timed_out`, partial output is
preserved, and the worker continues with the next commit.

Host requirements: Docker and Python 3. All CPG/JEP dependencies run inside
Docker. Use another configuration with `ENV_FILE=/path/to/file.env`.
