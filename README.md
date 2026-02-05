# Windows Manage Large Language Models

PowerShell automation to download large language models (LLMs) via Git and quantize them with llama.cpp to the `GGUF` format.

Think batch quantization like https://huggingface.co/TheBloke does it, but on your local machine :wink:

## Features

- Easy configuration via one `.env` file
- Automates the synchronization of Git repositories containing large files (LFS)
- Only fetches one LFS object at a time
- Displays a progress indicator on downloading LFS objects
- Automates the quantization from the source models
- Handles the intermediate files during quantization to reduce disk usage
- Improves quantization speed by separating read from write loads

## Installation

### Prerequisites

Use https://github.com/countzero/windows_llama.cpp to compile a specific version of the [llama.cpp](https://github.com/ggerganov/llama.cpp) project on your machine. This also makes training data available.


### Clone the repository from GitHub

Clone the repository to a nice place on your machine via:

```PowerShell
git clone git@github.com:countzero/windows_manage_large_language_models.git
```

### Create a .env file

Create the following `.env` file in the project directory. Make sure to change the `LLAMA_CPP_DIRECTORY` value.

```Env
# Path to the llama.cpp project that contains the
# required conversion and quantization programs.
LLAMA_CPP_DIRECTORY=C:\windows_llama.cpp\vendor\llama.cpp

# Path to the training data for computing the importance matrix.
TRAINING_DATA=C:\windows_llama.cpp\vendor\bartowski1182\calibration_datav5.txt

# This can be used to significantly reduce the time to compute the
# importance matrix without increasing the final perplexity.
# We are using 20 chunks (~10k tokens) from the training data.
# @see https://github.com/ggerganov/llama.cpp/discussions/5263
TRAINING_DATA_CHUNKS=20

# Path to the Git repositories containing the models.
SOURCE_DIRECTORY=.\source

# Path to the quantized models in GGUF format.
TARGET_DIRECTORY=.\gguf

# Path to the cache directory for intermediate files.
#
# Hint: Ideally this should be located on a different
# physical drive to improve the quantization speed.
CACHE_DIRECTORY=.\cache

# Path to the directory for importance matrix files.
IMPORTANCE_MATRIX_DIRECTORY=.\imatrix

#
# Comma separated list of multimodal projector types.
#
# For models with vision capability a "mmproj" file will be
# generated and placed next to the quantized models.
#
# Common types for the mmproj files:
#
#     F32  : Use float32 for older hardware
#     BF16 : Use bfloat16 for current hardware (recommended)
#     F16  : Use float16 for older hardware under VRAM constraints
#
MULTIMODAL_PROJECTOR_TYPES=BF16

#
# Comma separated list of quantization types.
#
# Possible llama.cpp quantization types:
#
#      2  or  Q4_0    :  4.34G, +0.4685 ppl @ Llama-3-8B
#      3  or  Q4_1    :  4.78G, +0.4511 ppl @ Llama-3-8B
#      8  or  Q5_0    :  5.21G, +0.1316 ppl @ Llama-3-8B
#      9  or  Q5_1    :  5.65G, +0.1062 ppl @ Llama-3-8B
#     19  or  IQ2_XXS :  2.06 bpw quantization
#     20  or  IQ2_XS  :  2.31 bpw quantization
#     28  or  IQ2_S   :  2.5  bpw quantization
#     29  or  IQ2_M   :  2.7  bpw quantization
#     24  or  IQ1_S   :  1.56 bpw quantization
#     31  or  IQ1_M   :  1.75 bpw quantization
#     36  or  TQ1_0   :  1.69 bpw ternarization
#     37  or  TQ2_0   :  2.06 bpw ternarization
#     10  or  Q2_K    :  2.96G, +3.5199 ppl @ Llama-3-8B
#     21  or  Q2_K_S  :  2.96G, +3.1836 ppl @ Llama-3-8B
#     23  or  IQ3_XXS :  3.06 bpw quantization
#     26  or  IQ3_S   :  3.44 bpw quantization
#     27  or  IQ3_M   :  3.66 bpw quantization mix
#     12  or  Q3_K    : alias for Q3_K_M
#     22  or  IQ3_XS  :  3.3 bpw quantization
#     11  or  Q3_K_S  :  3.41G, +1.6321 ppl @ Llama-3-8B
#     12  or  Q3_K_M  :  3.74G, +0.6569 ppl @ Llama-3-8B
#     13  or  Q3_K_L  :  4.03G, +0.5562 ppl @ Llama-3-8B
#     25  or  IQ4_NL  :  4.50 bpw non-linear quantization
#     30  or  IQ4_XS  :  4.25 bpw non-linear quantization
#     15  or  Q4_K    : alias for Q4_K_M
#     14  or  Q4_K_S  :  4.37G, +0.2689 ppl @ Llama-3-8B
#     15  or  Q4_K_M  :  4.58G, +0.1754 ppl @ Llama-3-8B
#     17  or  Q5_K    : alias for Q5_K_M
#     16  or  Q5_K_S  :  5.21G, +0.1049 ppl @ Llama-3-8B
#     17  or  Q5_K_M  :  5.33G, +0.0569 ppl @ Llama-3-8B
#     18  or  Q6_K    :  6.14G, +0.0217 ppl @ Llama-3-8B
#      7  or  Q8_0    :  7.96G, +0.0026 ppl @ Llama-3-8B
#      1  or  F16     : 14.00G, +0.0020 ppl @ Mistral-7B
#     32  or  BF16    : 14.00G, -0.0050 ppl @ Mistral-7B
#      0  or  F32     : 26.00G              @ 7B
#             COPY    : only copy tensors, no quantizing
#
# Hint: A very good quantization with minimal quality loss is
# Q5_K_M. Quantization below 4-bit causes measurable quality
# loss, try to avoid going too low and use IQ4_XS as a minimum.
# @see https://github.com/ggerganov/llama.cpp/tree/master/examples/perplexity
#
QUANTIZATION_TYPES=Q5_K_M,IQ4_XS
```

> [!NOTE]
> All i-quants (`IQ*`) and the small k-quants (`Q2_K` and `Q2_K_S`) require an [importance matrix](https://github.com/ggerganov/llama.cpp/tree/master/examples/imatrix). Since an importance matrix is also improving the quality of larger quantization types this script will always automatically compute it for each model and use it for the quantization.

## Usage

### 1. Clone a model

Clone a Git repository containing an LLM into the `SOURCE_DIRECTORY` without checking out any files and downloading any large files (lfs).

```PowerShell
git -C "./source" clone --no-checkout https://huggingface.co/openchat/openchat-3.6-8b-20240522
```

### 2. Download model sources

Download all files across all Git repositories that are inside the `SOURCE_DIRECTORY`.

```PowerShell
./download_model_sources.ps1
```

**Hint:** This can also be used to update already existing sources from the remote repositories.

### 3. Quantize model weights

Quantize all model weights that are inside the `SOURCE_DIRECTORY` into the `TARGET_DIRECTORY` to create a specific `GGUF` file for each `QUANTIZATION_TYPES`.

```PowerShell
./quantize_weights_for_llama.cpp.ps1
```
