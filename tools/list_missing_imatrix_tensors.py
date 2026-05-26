"""Emit --tensor-type-file rules for tensors missing from an imatrix.

llama-imatrix does not traverse MTP / NextN blocks during a standard
forward pass, so the transformer tensors that live inside those blocks
get zero entries in the importance matrix. Very-low-bit quants
(IQ3_XXS, IQ2_*, IQ1_*) refuse to proceed without imatrix data and
abort the whole quantization run.

This script compares the tensor inventory of an unquantized GGUF
against the tensor inventory of the corresponding imatrix GGUF and
prints one regex rule per missing-imatrix tensor in the format
consumed by `llama-quantize --tensor-type-file`. The rules pin each
missing tensor to a single static quantization type.

Track upstream:
  - https://github.com/ggml-org/llama.cpp/pull/23575 (generic
    missing-imatrix fallback inside llama-quantize)
  - https://github.com/ggml-org/llama.cpp/pull/23258 (alternative:
    activate MTP layers during imatrix collection)

When either lands and the llama.cpp pin in the sibling
windows_llama.cpp project is bumped past it, delete this script, the
two integration points in `quantize_weights_for_llama.cpp.ps1`, and
the matching note in CLAUDE.md.

Usage:
    python list_missing_imatrix_tensors.py \\
        --bf16 path\\to\\model.gguf \\
        --imatrix path\\to\\model.importance-matrix.gguf \\
        --quant-type Q8_0 \\
        --gguf-py-path path\\to\\vendor\\llama.cpp\\gguf-py \\
        > overrides.txt
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--bf16", required=True, type=Path,
                        help="Unquantized GGUF (BF16 / F16) to inspect.")
    parser.add_argument("--imatrix", required=True, type=Path,
                        help="Importance-matrix GGUF produced by llama-imatrix.")
    parser.add_argument("--quant-type", required=True,
                        help="Fallback quant type for missing tensors (e.g. Q8_0).")
    parser.add_argument("--gguf-py-path", required=True, type=Path,
                        help="Path to vendor/llama.cpp/gguf-py (in-tree, version-locked).")
    args = parser.parse_args()

    if not args.bf16.is_file():
        print(f"error: --bf16 not found: {args.bf16}", file=sys.stderr)
        return 1
    if not args.imatrix.is_file():
        print(f"error: --imatrix not found: {args.imatrix}", file=sys.stderr)
        return 1
    if not args.gguf_py_path.is_dir():
        print(f"error: --gguf-py-path not a directory: {args.gguf_py_path}",
              file=sys.stderr)
        return 1

    # Use the gguf package vendored alongside the llama-quantize.exe we will
    # invoke. This avoids any version drift against pip-installed gguf.
    sys.path.insert(0, str(args.gguf_py_path))
    from gguf import GGUFReader  # noqa: E402
    from gguf.constants import GGMLQuantizationType  # noqa: E402

    # F32 and integer tensors are never quantized by llama-quantize; they pass
    # through as-is and never trigger the "requires imatrix" check.
    skip_types = {
        GGMLQuantizationType.F32,
        GGMLQuantizationType.I8,
        GGMLQuantizationType.I16,
        GGMLQuantizationType.I32,
        GGMLQuantizationType.I64,
    }

    quant = args.quant_type.lower()

    # An imatrix GGUF stores each tensor as a pair of entries named
    # `<tensor>.in_sum2` and `<tensor>.counts` (see imatrix.cpp:603-604,
    # imatrix.cpp:753-754 in vendored llama.cpp). Strip these known suffixes
    # to recover the underlying tensor name set that imatrix has coverage for.
    IMATRIX_SUFFIXES = (".in_sum2", ".counts")

    bf16_reader = GGUFReader(str(args.bf16))
    imatrix_reader = GGUFReader(str(args.imatrix))

    imatrix_names: set[str] = set()
    for t in imatrix_reader.tensors:
        name = t.name
        for suffix in IMATRIX_SUFFIXES:
            if name.endswith(suffix):
                name = name[: -len(suffix)]
                break
        imatrix_names.add(name)

    missing = 0
    for tensor in bf16_reader.tensors:
        if tensor.tensor_type in skip_types:
            continue
        if tensor.name in imatrix_names:
            continue
        # Exact-match regex. llama-quantize's --tensor-type parser treats the
        # left-hand side as a regex, so the literal '.' separators in tensor
        # names must be escaped to avoid spurious partial matches.
        print(f"^{re.escape(tensor.name)}$={quant}")
        missing += 1

    # Diagnostic to stderr so callers can sanity-check counts in their logs
    # without contaminating the rules file on stdout.
    print(f"list_missing_imatrix_tensors: {missing} tensor(s) missing from "
          f"{args.imatrix.name}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
