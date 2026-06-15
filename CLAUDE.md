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
- `DRAFT_QUANTIZATION_TYPE` — Precision for all speculative-decoding draft weights: standalone draft files (separate-checkpoint MTP/NextN heads and EAGLE3, converted two-step so any `llama-quantize` preset works) and in-GGUF MTP/NextN tensor pins (a K-quant preset is reduced to its base ggml type, e.g. `Q4_K_M`→`q4_K`). Recommended `Q4_0`; i-quants/`Q2_K` unsupported for drafts (no imatrix is computed)
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

- **MTP / NextN layers escape imatrix coverage.** `llama-imatrix` runs a standard forward pass which does not exercise multi-token-prediction / NextN draft heads, so every tensor inside an MTP block ends up with zero imatrix entries. Very-low-bit quants (IQ3_XXS, IQ2_*, IQ1_*) require imatrix data per tensor and abort on the first one that lacks it (`llama-quant.cpp` at `src/llama-quant.cpp:1208`). The orchestrator computes the missing-tensor list in memory via `tools\list_missing_imatrix_tensors.py` (stdout = one regex rule per missing tensor) and injects the rules as repeated `--tensor-type` arguments to `llama-quantize`, pinning each to `DRAFT_QUANTIZATION_TYPE` reduced to its base ggml tensor type (`$draftTensorType`, e.g. `Q4_K_M`→`q4_K`, since `--tensor-type` takes a ggml type not a preset). Every applied rule is echoed to the run log so the override decisions are visible without a side-channel file. The two legacy `--tensor-type` regexes (`blk\.[0-9]+\.nextn\..*` and `mtp\..*`) only matched the four explicitly-named MTP tensors per block; the helper additionally catches the ~12 transformer tensors per MTP block that share the block index but lack the `.nextn.` marker (e.g. `blk.40.attn_k.weight` on Qwen3.6-35B-A3B). When upstream [llama.cpp PR #23575](https://github.com/ggml-org/llama.cpp/pull/23575) (or the alternative [#23258](https://github.com/ggml-org/llama.cpp/pull/23258)) merges and the pin in `windows_llama.cpp` is bumped past it, delete the helper script, the matching block in `quantize_weights_for_llama.cpp.ps1`, and this note. The recommended value for `DRAFT_QUANTIZATION_TYPE` is `Q4_0` (per PR #23575's empirical results: equal draft acceptance vs Q8_0 and faster speculative decoding because the MTP head runs on every drafted token); never drop below `Q4_0` (i-quants are LUT-based and too slow on the speculative path even though they are smaller).
- **imatrix GGUF stores each tensor as a pair of entries.** Each covered tensor `T` is written as two GGUF tensors named `T.in_sum2` and `T.counts` (see `vendor/llama.cpp/tools/imatrix/imatrix.cpp:603-604`). The helper script strips these suffixes when computing the covered-name set. Don't search for raw model tensor names in an imatrix GGUF without first stripping suffixes.
- **gguf-py is consumed from `vendor/llama.cpp/gguf-py/` via PYTHONPATH-style import**, not from `pip install gguf`. The vendored library tracks the submodule SHA in lockstep with the C++ binaries, so it cannot disagree with the file format produced by the same checkout's `convert_hf_to_gguf.py`. The pip-installed `gguf` package lags upstream and is known to misread files written by newer converters.
- **Standalone draft models (MTP / NextN heads) are auto-detected and emitted as a separate draft GGUF.** A source dir whose `config.json` contains `*AssistantForCausalLM` or `backbone_hidden_size` is converted to a separate `DRAFT_QUANTIZATION_TYPE` draft GGUF via the two-step `Convert-StandaloneDraft` helper (convert to a cached intermediate, then `llama-quantize`; no imatrix, no mmproj), and named with an `mtp-` prefix. It runs as a separate draft model (`-md <file> --spec-type draft-mtp`), never merged into the main GGUF — unlike DeepSeek/GLM/Qwen3-Next NextN, which lives inside the main GGUF. Detection matches `*AssistantForCausalLM` (so the regular `Gemma4UnifiedForConditionalGeneration` is excluded) or the `backbone_hidden_size` key that only a head sharing the target's hidden states carries. The two-step conversion means any `llama-quantize` type is supported (e.g. `Q4_0`, `Q4_K_M`); `convert_hf_to_gguf.py --outtype` alone could not (no `Q4_0`/K-quants). Do not quantize the main model's KV cache at runtime — it drops MTP draft acceptance to ~0%.
- **EAGLE3 drafts are standalone draft models converted with `--target-model-dir`, not the MTP tensor-pin path.** A source dir whose `config.json` contains a `draft_vocab_size` key is an EAGLE3 speculative-decoding draft (true across all vendor families: yuhuili ships `LlamaForCausalLM`, SGLang/AngelSlim/Tengyunw ship `LlamaForCausalLMEagle3`, RedHat ships `Eagle3Speculator`/`Eagle3DraftModel`). It is converted via the two-step `Convert-StandaloneDraft` helper (`convert_hf_to_gguf.py` to a cached intermediate, then `llama-quantize` to `DRAFT_QUANTIZATION_TYPE`; no imatrix, no `--tensor-type` overrides) and emitted as a separate `eagle3-{model}.{type}.gguf`, run as `-md <file> --spec-type draft-eagle3`. This is the standalone-draft file path, NOT the in-main-GGUF MTP/NextN tensor-pin path (both now share `DRAFT_QUANTIZATION_TYPE`): EAGLE3 ships as its own checkpoint and can only ever be a separate GGUF, and no imatrix is needed. The converter requires `--target-model-dir` pointing at the *target* model's HF directory — it reads the target's `vocab_size` (for the `d2t` bounds check) and `num_hidden_layers` (to derive feature-extraction layers) and borrows the target's tokenizer (the draft carries only a reduced vocab + `d2t`). The orchestrator resolves the target from `speculators_config.verifier.name_or_path` (RedHat speculators format only) by matching its basename against a sibling repo in `SOURCE_DIRECTORY`; drafts without that field (yuhuili/AngelSlim/Tengyunw/lmsys) or whose target is not downloaded are skipped with a warning. The speculators format nests `num_hidden_layers`/`vocab_size` under `transformer_layer_config`; the converter flattens this in `index_tensors` (`conversion/llama.py`) before computing `block_count`, so detection works (verified against `gemma-4-31B-it-speculator.eagle3`). Non-Llama-decoder variants (Kimi `Eagle3DeepseekV2ForCausalLM`, MiniMax, OLMoE, `eagle3.1`, Baichuan) are unsupported upstream.

## Code Comments

Comments explain **why**, not **what**. The code already states what it does; a comment that restates it is noise that drifts out of sync.

- **Default to no comment.** Reach for a clearer name or a smaller function before a comment. Comment only when the *reason* is non-obvious from the code itself.
- **One source of truth per rationale.** When a non-obvious decision spans several call sites, document it once at the authoritative place (here, the "Non-obvious behavior" notes) and reference it tersely in code — do not repeat the explanation at every consumer.
- **History lives in git, not in comments.** A comment must stand on its own; the commit message and `git blame` carry the change history.
- **No WHAT-comments.** Do not preface a line or block with a sentence that paraphrases it.
- **Length is a smell.** A why-comment over ~3 lines usually signals unclear code or naming; fix the code first. Reserve longer blocks for genuinely subtle invariants at their single source of truth.
