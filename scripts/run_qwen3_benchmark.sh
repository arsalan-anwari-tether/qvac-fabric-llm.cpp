#!/usr/bin/env bash
# Run llama-bench on every *.gguf in a directory: once with -ngl 0 (CPU) and once with
# -ngl 999 (GPU offload, Vulkan when the build uses it). Writes JSON per run.
#
# Usage:
#   run_qwen3_benchmark.sh --input-dir=DIR [--out-dir=DIR] -- [extra llama-bench args]
#
# Extra arguments are appended before the script's -ngl / -o json so layer count and JSON
# output always match each benchmark mode unless you duplicate flags (last wins).
#
# Environment:
#   LLAMA_BENCH  Path to llama-bench (default: <repo>/build/bin/llama-bench)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_BENCH="${LLAMA_BENCH:-$ROOT/build/bin/llama-bench}"

INPUT_DIR=""
OUTPUT_DIR=""
EXTRA=()
FAILURES=0

usage() {
  sed -n '1,20p' "$0" | sed -n '/^# /s/^# //p'
  echo ""
  echo "Options:"
  echo "  --input-dir=DIR | --input-dir DIR   Directory containing .gguf files (required)"
  echo "  --out-dir=DIR | --out-dir DIR       Where to write JSON (default: same as --input-dir)"
  echo "  --output-dir=DIR | --output-dir DIR  Same as --out-dir (either name)"
  echo "  -h, --help                           This help"
  echo "  --                                   Separator: all following tokens go to llama-bench"
}

die() {
  echo "error: $*" >&2
  exit 1
}

while (( "$#" )); do
  case "$1" in
    --input-dir=*)
      INPUT_DIR="${1#*=}"
      shift
      ;;
    --input-dir)
      [[ $# -ge 2 ]] || die "--input-dir requires a path"
      INPUT_DIR="$2"
      shift 2
      ;;
    --out-dir=*)
      OUTPUT_DIR="${1#*=}"
      shift
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a path"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a path"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA+=("$@")
      break
      ;;
    *)
      die "unknown argument: $1 (use -- before llama-bench flags)"
      ;;
  esac
done

[[ -n "$INPUT_DIR" ]] || die "--input-dir is required"
[[ -d "$INPUT_DIR" ]] || die "input directory does not exist: $INPUT_DIR"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$INPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

if [[ ! -x "$LLAMA_BENCH" ]]; then
  die "llama-bench not found or not executable: $LLAMA_BENCH (set LLAMA_BENCH if installed elsewhere)"
fi

mapfile -t GGUF_FILES < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.gguf' | LC_ALL=C sort)
((${#GGUF_FILES[@]})) || die "no .gguf files in $INPUT_DIR"

run_one() {
  local model_path=$1
  local out_json=$2
  local ngl=$3
  local label=$4

  echo "==> $label: $(basename "$model_path") (ngl=$ngl) -> $(basename "$out_json")" >&2
  if ! "$LLAMA_BENCH" -m "$model_path" "${EXTRA[@]}" -ngl "$ngl" -o json >"$out_json"; then
    echo "error: llama-bench failed for $model_path ($label) model arch not supported!" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  return 0
}

for f in "${GGUF_FILES[@]}"; do
  base="$(basename "$f" .gguf)"
  out_cpu="${OUTPUT_DIR}/${base}_cpu.json"
  out_vk="${OUTPUT_DIR}/${base}_vulkan.json"

  run_one "$f" "$out_cpu" 0 cpu || true
  run_one "$f" "$out_vk" 999 vulkan || true
done

if (( FAILURES > 0 )); then
  echo "done with $FAILURES failing run(s)." >&2
  exit 1
fi
echo "all benchmarks finished." >&2
