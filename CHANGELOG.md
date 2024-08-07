# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
