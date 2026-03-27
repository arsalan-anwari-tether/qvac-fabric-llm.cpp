# Batch CPU vs Vulkan benchmarks (`run_qwen3_benchmark.sh`)

The script [`scripts/run_qwen3_benchmark.sh`](../scripts/run_qwen3_benchmark.sh) runs [`llama-bench`](../tools/llama-bench/README.md) once per GGUF file in a directory: **CPU** (`-ngl 0`) and **GPU offload** (`-ngl 999`, typically Vulkan on builds that use it). It also runs [`llama-cli`](../tools/main/README.md) logic prompts (thinking and non-thinking) and writes Markdown reports.

By default, the logic benchmark uses the same fixed prompt set for both thinking and non-thinking runs. The default `llama-cli` generation limits are `-n 1024` for thinking and `-n 512` for non-thinking. The default logic-only sampling flags are:

```bash
--temp 0.5 --top-k 20 --top-p 0.9 --min-p 0 --repeat-penalty 1.10 --presence-penalty 0.3
```

You can override these defaults with `LOGIC_N_THINK`, `LOGIC_N_NO_THINK`, and `LOGIC_CLI_EXTRA`.

Under **`--output-dir`** (default: same as `--input-dir`), it creates:

- **`inference/`** — `llama-bench` JSON (`-o json`) per file:
  - `<stem>_cpu.json` — all inference on CPU
  - `<stem>_vulkan.json` — layers offloaded to the GPU (high `-ngl`); the label reflects the usual goal (compare against CPU); the actual backend follows your binary and environment
- **`logic/`** — one Markdown file per backend and thinking mode: `<stem>_{cpu|vulkan}_{think|no_think}.md`

`<stem>` is the GGUF filename without the `.gguf` suffix (e.g. `Qwen3-8B-Q4_K_M_cpu.json`).

## Expected binary location

The script resolves the repository root from its own path and defaults to:

- `build/bin/llama-bench` — override with **`LLAMA_BENCH`**
- `build/bin/llama-cli` — override with **`LLAMA_CLI`**

## Usage

```bash
./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/ggufs [--output-dir=/path/to/results] -- [extra llama-bench arguments]
```

- **`--input-dir`** — Required. Directory containing `*.gguf` files (non-recursive; only the top level of that directory).
- **`--output-dir`** — Optional. Directory for **`inference/`** and **`logic/`**; defaults to the same path as **`--input-dir`**.
- **`--`** — Everything after `--` is passed through to `llama-bench`. The script sets **`-m`** for each file and appends **`-ngl`** and **`-o json`** after your extras so the benchmark mode and JSON output stay consistent. Do not add another **`-m`** or **`-o`** after `--` unless you intend to override (the last flag wins).

Example with extra bench flags:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf" -- -p 512 -n 128 -r 3
```

## Running in the background (Termux and other environments)

Long benchmark runs are often started in a shell session that you close. On Android **Termux**, the process may also be stopped when the device sleeps unless you keep the CPU awake.

### Redirect stdout and stderr to a log file

Run the script and tee to a log so you keep a full transcript while still watching progress:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/gguf -- -p 512 -n 128 2>&1 | tee bench.log
```

Or append-only:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/gguf -- -p 512 -n 128 >>bench.log 2>&1
```

### Background with `nohup`

`nohup` keeps the process from receiving a hangup signal when the terminal disconnects, and typically sends output to `nohup.out` unless you redirect:

```bash
nohup ./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/gguf -- -p 512 -n 128 >>bench.log 2>&1 &
echo $!   # PID to remember for kill or monitoring
```

You can **`tail -f bench.log`** in another session to watch status. JSON and Markdown results go under **`--output-dir`** (or **`--input-dir`** if you omitted **`--output-dir`**); the log is for messages and any errors from the shell or binary.

### Termux: keep the device awake (`termux-wake-lock`)

While Termux is in the foreground, acquire a wake lock so the CPU does not idle the session mid-run (behavior depends on device and battery settings):

```bash
termux-wake-lock
./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/gguf -- ...
termux-wake-unlock
```

For unattended jobs, combine with `nohup` and logging; release the lock when finished so the device can sleep normally.

### Why this matters

- **`nohup` / background `&`** — Survive closing the SSH or Termux terminal session (still subject to OS killing background apps under memory pressure).
- **Wake lock** — Reduces the chance that the device suspends the process during long GPU/CPU runs.
- **Log + `tail -f`** — Confirms which model is running and catches failures without opening each JSON file.

## See also

- [`docs/qwen3-llama-run.md`](qwen3-llama-run.md) — Single-model Qwen3 helper for `llama-cli` / `llama-bench`
- [`tools/llama-bench/README.md`](../tools/llama-bench/README.md) — Full `llama-bench` options and JSON output shape
