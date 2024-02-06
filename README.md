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
TRAINING_DATA=C:\windows_llama.cpp\vendor\wikitext-2-raw-v1\wikitext-2-raw\wiki.train.raw

# Path to the Git repositories containing the models.
SOURCE_DIRECTORY=.\source

# Path to the quantized models in GGUF format.
TARGET_DIRECTORY=.\gguf

# Path to the cache directory for intermediate files.
#
# Hint: Ideally this should be located on a different
# physical drive to improve the quantization speed.
CACHE_DIRECTORY=.\cache

#
# Comma separated list of quantization types.
#
# Possible llama.cpp quantization types:
#
#     IQ2_XXS :  2.06 bpw quantization
#     IQ2_XS  :  2.31 bpw quantization
#     Q2_K    :  2.63G, +0.6717 ppl @ LLaMA-v1-7B
#     Q2_K_S  :  2.16G, +9.0634 ppl @ LLaMA-v1-7B
#     IQ3_XXS :  3.06 bpw quantization
#     Q3_K_XS :  3-bit extra small quantization
#     Q3_K_S  :  2.75G, +0.5551 ppl @ LLaMA-v1-7B
#     Q3_K_M  :  3.07G, +0.2496 ppl @ LLaMA-v1-7B
#     Q3_K_L  :  3.35G, +0.1764 ppl @ LLaMA-v1-7B
#     Q4_0    :  3.56G, +0.2166 ppl @ LLaMA-v1-7B
#     Q4_1    :  3.90G, +0.1585 ppl @ LLaMA-v1-7B
#     Q4_K_S  :  3.59G, +0.0992 ppl @ LLaMA-v1-7B
#     Q4_K_M  :  3.80G, +0.0532 ppl @ LLaMA-v1-7B
#     Q5_0    :  4.33G, +0.0683 ppl @ LLaMA-v1-7B
#     Q5_1    :  4.70G, +0.0349 ppl @ LLaMA-v1-7B
#     Q5_K_S  :  4.33G, +0.0400 ppl @ LLaMA-v1-7B
#     Q5_K_M  :  4.45G, +0.0122 ppl @ LLaMA-v1-7B
#     Q6_K    :  5.15G, -0.0008 ppl @ LLaMA-v1-7B
#     Q8_0    :  6.70G, +0.0004 ppl @ LLaMA-v1-7B
#     F16     : 13.00G              @ 7B
#     F32     : 26.00G              @ 7B
#     COPY    : only copy tensors, no quantizing
#
# Hint: The sweet spot is Q5_K_M. The smallest quantization
# without the need for an importance matrix is IQ3_XXS.
#
QUANTIZATION_TYPES=Q5_K_M,IQ3_XXS
```


## Usage

### 1. Clone a model

Clone a Git repository containing an LLM into the `SOURCE_DIRECTORY` without checking out any files and downloading any large files (lfs).

```PowerShell
git -C "./source" clone --no-checkout https://huggingface.co/microsoft/Orca-2-7b
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
