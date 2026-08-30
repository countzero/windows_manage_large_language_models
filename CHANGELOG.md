# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.14.0] - 2026-08-30

### Added
- Add SOURCE_DIRECTORY_LFS_STORAGE to relocate the Git LFS object store of every model repository onto another drive, mirrored per repository, so that a single drive no longer serves both the read and the write of every checked out large file

## [1.13.0] - 2026-08-27

### Added
- Detect and convert DFlash / DSpark block-diffusion drafts into a separate `dflash-` / `dspark-` prefixed draft GGUF
- Resolve a draft model's target by stripping the draft suffix from its directory name when the config records no target

### Fixed
- Stop pinning `token_embd.weight`, `per_layer_token_embd.weight` and `output.weight` to the draft quantization type; llama-imatrix never covers them and llama-quantize exempts them from the requires-imatrix abort, so the rules only served to replace the file type's own output-head choice (Q6_K at IQ4_XS, Q5_K at IQ3_XXS) with Q4_0 on every model
- Fix DFlash drafters (e.g. `MuseGlimmerAssistantModel`) being processed as regular models, which failed conversion because `--target-model-dir` was missing and then cascaded into failed importance matrix and quantization runs
- Skip the remaining pipeline of a model with a single explanatory message when its conversion produces no GGUF
- Stop computing an importance matrix for models whose quantized outputs already exist

### Changed
- Compute the missing-imatrix tensor rules once per model instead of once per quantization type

## [1.12.0] - 2026-06-15

### Added
- Detect and convert EAGLE3 speculative-decoding drafts into a separate `eagle3-` prefixed draft GGUF, resolving the target model from the speculators config

### Changed
- Move repo guidance to AGENTS.md with a CLAUDE.md import shim
- Convert standalone draft models (separate-checkpoint MTP / NextN heads and EAGLE3) in two steps (convert then quantize) so any llama-quantize type is supported for draft weights
- Consolidate MTP_QUANTIZATION_TYPE into DRAFT_QUANTIZATION_TYPE; for in-GGUF MTP / NextN tensor pins a K-quant preset is reduced to its base ggml tensor type (e.g. Q4_K_M to q4_K)

### Removed
- Remove the MTP_QUANTIZATION_TYPE environment variable (superseded by DRAFT_QUANTIZATION_TYPE)

## [1.11.0] - 2026-06-08

### Added
- Add DRAFT_QUANTIZATION_TYPE to convert standalone draft models (MTP / NextN heads) into a separate draft GGUF

### Changed
- Remove the hard-coded Q8_0 fallback for MTP_QUANTIZATION_TYPE

## [1.10.0] - 2026-05-26

### Added
- Add tools/list_missing_imatrix_tensors.py helper that detects model tensors not covered by the imatrix

### Fixed
- Fix IQ3_XXS / IQ2_* / IQ1_* quantization abort on models with MTP / NextN layers by pinning every imatrix-uncovered tensor to MTP_QUANTIZATION_TYPE

## [1.9.0] - 2026-05-17

### Added
- Add MTP_QUANTIZATION_TYPE environment variable to pin MTP / NextN tensors during quantization

## [1.8.0] - 2025-11-07

### Changed
- Move multimodal projector type configuration into .env file

## [1.7.0] - 2025-10-31

### Added
- Add multimodal projector (mmproj file) generation
- Add imatrix computation on the CPU as a fallback

### Changed
- Enable importance matrix for all quant formats

## [1.6.0] - 2024-07-12

### Added
- Add training data chunk environment variable

### Changed
- Enable importance matrix for all quant formats
- Always compute an imatrix file
- Update documentation about quantization

### Fixed
- Fix renaming of convert python script from llama.cpp

## [1.5.0] - 2024-06-20

### Added
- Use existing importance matrix files for all quant formats

### Changed
- Move importance matrix files into dedicated directory
- Simplify conversion from hf to gguf
- Changed binary names to the new llama.cpp format (llama-\*)
- Update list of supported quantization types

### Removed
- Remove logging of repository directories

## [1.4.0] - 2024-02-29

### Added
- Fix check when an importance matrix is required

### Changed
- Update supported quantization types

## [1.3.0] - 2024-02-22

### Added
- Add support for using unquantized models in the GGUF format from the source

## [1.2.0] - 2024-02-20

### Added
- Add fallback to 'convert-hf-to-gguf.py' to support novel model architectures
- Add support for models with Byte Pair Encoding (BPE) vocabulary type

### Changed
- Update documentation
- Change filenames to match the de facto standard

## [1.1.0] - 2024-02-06

### Added
- Add support for IQ2_XXS, IQ2_XS and Q2_K_S quantization types

### Changed
- Update list of supported quantization types

### Fixed
- Fix resolving of paths

## [1.0.0] - 2023-11-28

### Added
- Add .env configuration
- Add Documentation
- Add download script
- Add quantization script
