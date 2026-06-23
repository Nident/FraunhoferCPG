#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  generate_edge_examples.sh \
    --project OWNER/REPO \
    --fp path/to/fp.json \
    --tp path/to/tp.json \
    --out path/to/output-directory \
    [--limit 2]

Creates one readable JSON file per edge type. Each output file contains up to
LIMIT examples from both the FP and TP CPG files, including the complete edge,
start node, and end node.
EOF
}

project=""
fp_file=""
tp_file=""
out_dir=""
limit=2

while (($#)); do
  case "$1" in
    --project) project="${2:?Missing value for --project}"; shift 2 ;;
    --fp) fp_file="${2:?Missing value for --fp}"; shift 2 ;;
    --tp) tp_file="${2:?Missing value for --tp}"; shift 2 ;;
    --out) out_dir="${2:?Missing value for --out}"; shift 2 ;;
    --limit) limit="${2:?Missing value for --limit}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$project" || -z "$fp_file" || -z "$tp_file" || -z "$out_dir" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "$fp_file" ]]; then
  echo "FP file does not exist: $fp_file" >&2
  exit 1
fi

if [[ ! -f "$tp_file" ]]; then
  echo "TP file does not exist: $tp_file" >&2
  exit 1
fi

if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "--limit must be a positive integer" >&2
  exit 2
fi

command -v jq >/dev/null || {
  echo "jq is required but was not found" >&2
  exit 1
}

mkdir -p "$out_dir"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cpg-edge-examples.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

extract_examples() {
  local input_file="$1"
  local output_file="$2"

  jq --argjson limit "$limit" '
    (.nodes | map({key: (.id | tostring), value: .}) | from_entries) as $nodes
    | reduce .edges[] as $edge ({};
        if ((.[$edge.type] // []) | length) < $limit then
          .[$edge.type] += [{
            edge: $edge,
            startNode: $nodes[($edge.startNode | tostring)],
            endNode: $nodes[($edge.endNode | tostring)]
          }]
        else
          .
        end
      )
  ' "$input_file" > "$output_file"
}

fp_examples="$tmp_dir/fp.json"
tp_examples="$tmp_dir/tp.json"
types_file="$tmp_dir/types.txt"

extract_examples "$fp_file" "$fp_examples"
extract_examples "$tp_file" "$tp_examples"

jq -nr \
  --slurpfile fp "$fp_examples" \
  --slurpfile tp "$tp_examples" \
  '$fp[0] + $tp[0] | keys[]' \
  | LC_ALL=C sort -u > "$types_file"

while IFS= read -r edge_type; do
  jq -n \
    --arg project "$project" \
    --arg edgeType "$edge_type" \
    --arg fpFile "$(basename "$fp_file")" \
    --arg tpFile "$(basename "$tp_file")" \
    --slurpfile fp "$fp_examples" \
    --slurpfile tp "$tp_examples" '
      {
        project: $project,
        relationType: $edgeType,
        edgeDirection: "startNode -> endNode",
        commits: [
          {
            verdict: "fp",
            sourceFile: $fpFile,
            examples: ($fp[0][$edgeType] // [])
          },
          {
            verdict: "tp",
            sourceFile: $tpFile,
            examples: ($tp[0][$edgeType] // [])
          }
        ]
      }
    ' > "$out_dir/$edge_type.json"
done < "$types_file"

find "$out_dir" -maxdepth 1 -type f -name '*.json' -print0 \
  | xargs -0 -n1 jq empty

file_count="$(wc -l < "$types_file" | tr -d ' ')"
echo "Created $file_count JSON files in $out_dir"
