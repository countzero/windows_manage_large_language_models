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
- `SOURCE_DIRECTORY`, `TARGET_DIRECTORY`, `CACHE_DIRECTORY`, `IMPORTANCE_MATRIX_DIRECTORY` — Working directories

### Key Implementation Details

- Both scripts parse `.env` manually (split on `=`, skip blank/comment lines, set as environment variables)
- Repositories are processed in natural sort order (numeric-aware)
- Mistral-format models (Devstral series) are hardcoded in `$mistralFormatModels` and get a `--mistral-format` flag
- The conda environment `llama.cpp` is activated before quantization
- llama.cpp binaries are expected at `{LLAMA_CPP_DIRECTORY}\build\bin\Release\`
- Output naming: `{model}.{quantType}.gguf` for quantized models, `mmproj.{model}.{projType}.gguf` for vision projectors

### External Dependencies

- **llama.cpp** compiled via [windows_llama.cpp](https://github.com/countzero/windows_llama.cpp) — provides `convert_hf_to_gguf.py`, `llama-imatrix.exe`, `llama-quantize.exe`
- Git with Git LFS
- Python (via Conda environment `llama.cpp`)
- CUDA-compatible GPU recommended (CPU fallback for imatrix computation)
