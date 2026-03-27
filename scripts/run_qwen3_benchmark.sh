#!/usr/bin/env bash
# Run llama-bench on every *.gguf in a directory: once with -ngl 0 (CPU) and once with
# -ngl 999 (GPU offload, Vulkan when the build uses it). Writes JSON per run.
#
# Also runs llama-cli logic prompts (thinking + non-thinking) and writes Markdown reports.
#
#   {output-dir}/inference/{model}_{cpu|vulkan}.json
#   {output-dir}/logic/{model}_{cpu|vulkan}_{think|no_think}.md
#
# Usage:
#   run_qwen3_benchmark.sh --input-dir=DIR [--output-dir=DIR] -- [extra llama-bench args]
#
# Default llama-bench workload: -p/-n/-r from BENCH_* env (see below). Extra arguments after
# -- apply to llama-bench only (not llama-cli logic), so bench flags like -p/-n/-r do not
# confuse llama-cli. Optional logic-only flags: LOGIC_CLI_EXTRA (space-separated tokens).
# Logic runs use stdin from /dev/null so llama-cli cannot block on console input when stdout
# is captured (command substitution otherwise inherits the script's TTY stdin).
#
# Environment:
#   LLAMA_BENCH  Path to llama-bench (default: <repo>/build/bin/llama-bench)
#   LLAMA_CLI    Path to llama-cli (default: <repo>/build/bin/llama-cli)
#   LOGIC_CLI_EXTRA  Optional space-separated extra llama-cli flags for logic only
#                    (default: "--temp 0.5 --top-k 20 --top-p 0.9 --min-p 0 --repeat-penalty 1.10 --presence-penalty 0.3")
#
# Defaults (override with env):
#   BENCH_P, BENCH_N, BENCH_R     llama-bench: prompt tokens, gen tokens, repetitions (defaults: 256, 64, 2)
#   LOGIC_N_THINK, LOGIC_N_NO_THINK  llama-cli -n for think / no_think logic runs (defaults: 1024, 512)
# llama-bench upstream defaults are -p 512 -n 128 -r 5; this script uses smaller values unless env overrides.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_BENCH="${LLAMA_BENCH:-$ROOT/build/bin/llama-bench}"
LLAMA_CLI="${LLAMA_CLI:-$ROOT/build/bin/llama-cli}"

: "${BENCH_P:=256}"
: "${BENCH_N:=64}"
: "${BENCH_R:=2}"
: "${LOGIC_N_THINK:=1024}"
: "${LOGIC_N_NO_THINK:=512}"
: "${LOGIC_CLI_EXTRA:=--temp 0.5 --top-k 20 --top-p 0.9 --min-p 0 --repeat-penalty 1.10 --presence-penalty 0.3}"

LOGIC_CLI_EXTRA_ARR=()
if [[ -n "${LOGIC_CLI_EXTRA:-}" ]]; then
  read -r -a LOGIC_CLI_EXTRA_ARR <<< "${LOGIC_CLI_EXTRA}"
fi

INPUT_DIR=""
OUTPUT_DIR=""
EXTRA=()
FAILURES=0

usage() {
  sed -n '1,30p' "$0" | sed -n '/^# /s/^# //p'
  echo ""
  echo "Options:"
  echo "  --input-dir=DIR | --input-dir DIR   Directory containing .gguf files (required)"
  echo "  --output-dir=DIR | --output-dir DIR Where to write inference/ and logic/ (default: same as --input-dir)"
  echo "  -h, --help                           This help"
  echo "  --                                   Separator: all following tokens go to llama-bench"
}

# Fixed logic prompts (Qwen3-style chat: --jinja + --reasoning-budget).
LOGIC_PROMPTS=(
  'What is the derivative of x³ + 2x² - 5x + 3?'
  'Write a Python function to check if a string is a palindrome.'
  'A farmer has 17 sheep. All but 9 run away. How many sheep does the farmer have left?'
)

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
mkdir -p "$OUTPUT_DIR/inference" "$OUTPUT_DIR/logic"

if [[ ! -x "$LLAMA_BENCH" ]]; then
  die "llama-bench not found or not executable: $LLAMA_BENCH (set LLAMA_BENCH if installed elsewhere)"
fi

if [[ ! -x "$LLAMA_CLI" ]]; then
  die "llama-cli not found or not executable: $LLAMA_CLI (set LLAMA_CLI if installed elsewhere)"
fi

LLAMA_VERSION="$("$LLAMA_CLI" --version 2>/dev/null | head -n1 || echo "unknown")"

mapfile -t GGUF_FILES < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.gguf' | LC_ALL=C sort)
((${#GGUF_FILES[@]})) || die "no .gguf files in $INPUT_DIR"

run_one() {
  local model_path=$1
  local out_json=$2
  local ngl=$3
  local label=$4

  echo "==> $label: $(basename "$model_path") (ngl=$ngl) -> $(basename "$out_json")" >&2
  if ! "$LLAMA_BENCH" -m "$model_path" -p "$BENCH_P" -n "$BENCH_N" -r "$BENCH_R" "${EXTRA[@]}" -ngl "$ngl" -o json >"$out_json"; then
    echo "error: llama-bench failed for $model_path ($label) model arch not supported!" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  return 0
}

run_logic_one() {
  local model_path=$1
  local out_md=$2
  local ngl=$3
  local backend=$4
  local mode=$5
  local base_name=$6

  local n_predict rbudget
  if [[ "$mode" == "think" ]]; then
    n_predict=$LOGIC_N_THINK
    rbudget=-1
  elif [[ "$mode" == "no_think" ]]; then
    n_predict=$LOGIC_N_NO_THINK
    rbudget=0
  else
    die "run_logic_one: mode must be think or no_think (got: $mode)"
  fi

  {
    cat <<EOF
# Logic test: ${base_name}

## Run configuration

| Field | Value |
|-------|-------|
| **llama-cli** | \`${LLAMA_CLI}\` |
| **llama-cli version** | ${LLAMA_VERSION} |
| **Model file** | \`$(basename "$model_path")\` |
| **Backend** | ${backend} (\`ngl=${ngl}\`) |
| **Thinking mode** | \`${mode}\` (\`--reasoning-budget ${rbudget}\`) |
| **Max new tokens** | \`-n ${n_predict}\` |
| **Chat** | \`--jinja\`, \`--single-turn\` (each question: \`-p\` …) |

## Command line (same for every question; only \`-p\` changes)

EOF
    printf '````bash\n'
    printf '%q ' "$LLAMA_CLI" -m "$model_path" --jinja --reasoning-budget "$rbudget" -ngl "$ngl" -st -p '<prompt>' -n "$n_predict" "${LOGIC_CLI_EXTRA_ARR[@]}"
    printf ' </dev/null\n'
    printf '````\n\n---\n\n'
  } >"$out_md"

  local i=1
  local tmp_err
  tmp_err="$(mktemp)"

  local prompt answer ec err
  for prompt in "${LOGIC_PROMPTS[@]}"; do
    echo "==> logic $backend $mode Question-${i}: $(basename "$model_path")" >&2
    set +e
    answer=$("$LLAMA_CLI" -m "$model_path" --jinja --reasoning-budget "$rbudget" -ngl "$ngl" -st -p "$prompt" -n "$n_predict" "${LOGIC_CLI_EXTRA_ARR[@]}" </dev/null 2>"$tmp_err")
    ec=$?
    set -e
    err="$(cat "$tmp_err" || true)"
    if (( ec != 0 )); then
      echo "error: llama-cli failed for $model_path ($backend $mode Q${i}) exit=$ec" >&2
      FAILURES=$((FAILURES + 1))
      {
        printf '## Question %s\n\n### Prompt\n\n%s\n\n### Answer\n\n' "$i" "$prompt"
        printf '**llama-cli exited with code %s**\n\n' "$ec"
        printf '````text\n\n'
        printf '%s\n' "$err"
        printf '\n````\n\n'
      } >>"$out_md"
    else
      if [[ -z "$answer" ]]; then
        answer="(empty output)"
      fi
      {
        printf '## Question %s\n\n### Prompt\n\n%s\n\n### Answer\n\n' "$i" "$prompt"
        printf '````text\n\n'
        printf '%s\n' "$answer"
        printf '\n````\n\n'
      } >>"$out_md"
    fi
    i=$((i + 1))
  done
  rm -f "$tmp_err"
  return 0
}

for f in "${GGUF_FILES[@]}"; do
  base="$(basename "$f" .gguf)"
  out_cpu="${OUTPUT_DIR}/inference/${base}_cpu.json"
  out_vk="${OUTPUT_DIR}/inference/${base}_vulkan.json"

  run_one "$f" "$out_cpu" 0 cpu || true
  run_one "$f" "$out_vk" 999 vulkan || true

  run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}_cpu_think.md" 0 cpu think "$base"
  run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}_cpu_no_think.md" 0 cpu no_think "$base"
  run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}_vulkan_think.md" 999 vulkan think "$base"
  run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}_vulkan_no_think.md" 999 vulkan no_think "$base"
done

if (( FAILURES > 0 )); then
  echo "done with $FAILURES failing run(s)." >&2
  exit 1
fi
echo "all benchmarks and logic tests finished." >&2
