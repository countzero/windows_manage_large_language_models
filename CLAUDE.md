# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PowerShell automation toolkit for downloading LLMs via Git and batch-quantizing them to GGUF format using llama.cpp. Runs on Windows. Inspired by TheBloke's HuggingFace workflow but for local machines.

## Common Commands

```powershell
# Clone a model (no-checkout, no LFS download yet)
git -C "./source" clone --no-checkout https://huggingface.co/<org>/<model>

# Download all model files (Git LFS) across all repos in source/
./download_model_sources.ps1

# Quantize all models from source/ into gguf/
./quantize_weights_for_llama.cpp.ps1
```

Both scripts read configuration from `.env` in the project root.

## Architecture

### Two-Script Pipeline

1. **`download_model_sources.ps1`** — Iterates all Git repos in `SOURCE_DIRECTORY`, prunes incomplete LFS files, resets working directory, pulls regular files (with `GIT_LFS_SKIP_SMUDGE=1`), then pulls LFS files sequentially with progress.

2. **`quantize_weights_for_llama.cpp.ps1`** — For each model in `SOURCE_DIRECTORY`:
   - Generates multimodal projector files (`mmproj.{model}.{type}.gguf`) for vision-capable models using `convert_hf_to_gguf.py --mmproj`
   - Converts HuggingFace format to unquantized GGUF via `convert_hf_to_gguf.py` (skipped if source already contains a `.gguf`)
   - Computes importance matrix via `llama-imatrix.exe` (GPU first, CPU fallback), cached in `IMPORTANCE_MATRIX_DIRECTORY`
   - Quantizes to each configured type via `llama-quantize.exe` with imatrix
   - Cleans up intermediate unquantized GGUF (preserves source-provided ones and cached importance matrices)

### Directory Layout

| Directory | Purpose |
|-----------|---------|
| `source/` | Git repos cloned from HuggingFace (one subdirectory per model) |
| `gguf/` | Output quantized GGUF files (`{model}/{model}.{type}.gguf`) |
| `cache/` | Intermediate unquantized GGUF files (ideally on a separate physical drive) |
| `imatrix/` | Cached importance matrix files (`{model}.importance-matrix.gguf`) |

### Configuration

All configuration lives in a single `.env` file (gitignored). Key variables:

- `LLAMA_CPP_DIRECTORY` — Path to compiled llama.cpp (from [windows_llama.cpp](https://github.com/countzero/windows_llama.cpp))
- `TRAINING_DATA` / `TRAINING_DATA_CHUNKS` — Calibration data for importance matrix computation
- `QUANTIZATION_TYPES` — Comma-separated list of target quantization formats (e.g., `Q5_K_M,IQ4_XS`)
- `MULTIMODAL_PROJECTOR_TYPES` — Comma-separated projector types (e.g., `BF16`)
- `DRAFT_QUANTIZATION_TYPE` — Precision for standalone draft models (MTP/NextN heads); `Q8_0`/`F16`/`BF16`/`F32`
- `SOURCE_DIRECTORY`, `TARGET_DIRECTORY`, `CACHE_DIRECTORY`, `IMPORTANCE_MATRIX_DIRECTORY` — Working directories

### Key Implementation Details

- Both scripts parse `.env` manually (split on `=`, skip blank/comment lines, set as environment variables)
- Repositories are processed in natural sort order (numeric-aware)
- Mistral-format models (Devstral series) are hardcoded in `$mistralFormatModels` and get a `--mistral-format` flag
- The conda environment `llama.cpp` is activated before quantization
- llama.cpp binaries are expected at `{LLAMA_CPP_DIRECTORY}\build\bin\Release\`
- Output naming: `{model}.{quantType}.gguf` for quantized models, `mmproj.{model}.{projType}.gguf` for vision projectors

### External Dependencies

- **llama.cpp** compiled via [windows_llama.cpp](https://github.com/countzero/windows_llama.cpp) — provides `convert_hf_to_gguf.py`, `llama-imatrix.exe`, `llama-quantize.exe`, and the in-tree `gguf-py` package at `vendor/llama.cpp/gguf-py/`
- Git with Git LFS
- Python (via Conda environment `llama.cpp`)
- CUDA-compatible GPU recommended (CPU fallback for imatrix computation)

## Non-obvious behavior

- **MTP / NextN layers escape imatrix coverage.** `llama-imatrix` runs a standard forward pass which does not exercise multi-token-prediction / NextN draft heads, so every tensor inside an MTP block ends up with zero imatrix entries. Very-low-bit quants (IQ3_XXS, IQ2_*, IQ1_*) require imatrix data per tensor and abort on the first one that lacks it (`llama-quant.cpp` at `src/llama-quant.cpp:1208`). The orchestrator computes the missing-tensor list in memory via `tools\list_missing_imatrix_tensors.py` (stdout = one regex rule per missing tensor) and injects the rules as repeated `--tensor-type` arguments to `llama-quantize`, pinning each to `MTP_QUANTIZATION_TYPE`. Every applied rule is echoed to the run log so the override decisions are visible without a side-channel file. The two legacy `--tensor-type` regexes (`blk\.[0-9]+\.nextn\..*` and `mtp\..*`) only matched the four explicitly-named MTP tensors per block; the helper additionally catches the ~12 transformer tensors per MTP block that share the block index but lack the `.nextn.` marker (e.g. `blk.40.attn_k.weight` on Qwen3.6-35B-A3B). When upstream [llama.cpp PR #23575](https://github.com/ggml-org/llama.cpp/pull/23575) (or the alternative [#23258](https://github.com/ggml-org/llama.cpp/pull/23258)) merges and the pin in `windows_llama.cpp` is bumped past it, delete the helper script, the matching block in `quantize_weights_for_llama.cpp.ps1`, and this note. The recommended value for `MTP_QUANTIZATION_TYPE` is `Q4_0` (per PR #23575's empirical results: equal draft acceptance vs Q8_0 and faster speculative decoding because the MTP head runs on every drafted token); raise it to `Q8_0` only when the main quant is itself `Q8_0`/`F16`/`BF16`, and never drop below `Q4_0` (i-quants are LUT-based and too slow on the speculative path even though they are smaller).
- **imatrix GGUF stores each tensor as a pair of entries.** Each covered tensor `T` is written as two GGUF tensors named `T.in_sum2` and `T.counts` (see `vendor/llama.cpp/tools/imatrix/imatrix.cpp:603-604`). The helper script strips these suffixes when computing the covered-name set. Don't search for raw model tensor names in an imatrix GGUF without first stripping suffixes.
- **gguf-py is consumed from `vendor/llama.cpp/gguf-py/` via PYTHONPATH-style import**, not from `pip install gguf`. The vendored library tracks the submodule SHA in lockstep with the C++ binaries, so it cannot disagree with the file format produced by the same checkout's `convert_hf_to_gguf.py`. The pip-installed `gguf` package lags upstream and is known to misread files written by newer converters.
- **Standalone draft models (MTP / NextN heads) are auto-detected and emitted as a separate draft GGUF.** A source dir whose `config.json` contains `*AssistantForCausalLM` or `backbone_hidden_size` is converted directly to `DRAFT_QUANTIZATION_TYPE`, bypassing the imatrix/mmproj/`llama-quantize` steps, and named with an `mtp-` prefix. It runs as a separate draft model (`-md <file> --spec-type draft-mtp`), never merged into the main GGUF — unlike DeepSeek/GLM/Qwen3-Next NextN, which lives inside the main GGUF. Detection matches `*AssistantForCausalLM` (so the regular `Gemma4UnifiedForConditionalGeneration` is excluded) or the `backbone_hidden_size` key that only a head sharing the target's hidden states carries. Note: `convert_hf_to_gguf.py --outtype` only accepts `Q8_0`/`F16`/`BF16`/`F32` (no `Q4_0`). Do not quantize the main model's KV cache at runtime — it drops MTP draft acceptance to ~0%.
