$stopwatch = [System.Diagnostics.Stopwatch]::startNew()

Get-Content "./.env" | ForEach {

    $name, $value = $_.split('=', 2)

    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('#')) {
        return
    }

    Set-Content env:\$name $value
}

$llamaCppDirectory = Resolve-Path -Path $env:LLAMA_CPP_DIRECTORY
$sourceDirectory = Resolve-Path -Path $env:SOURCE_DIRECTORY
$targetDirectory = Resolve-Path -Path $env:TARGET_DIRECTORY
$importanceMatrixDirectory = Resolve-Path -Path $env:IMPORTANCE_MATRIX_DIRECTORY
$cacheDirectory = Resolve-Path -Path $env:CACHE_DIRECTORY
$trainingDataPath = Resolve-Path -Path $env:TRAINING_DATA
$trainingDataChunks = [System.Convert]::ToInt32($env:TRAINING_DATA_CHUNKS)
$quantizationTypes = $env:QUANTIZATION_TYPES -split ','
$multimodalProjectorTypes = $env:MULTIMODAL_PROJECTOR_TYPES -split ','
$draftQuantizationType = $env:DRAFT_QUANTIZATION_TYPE

# DRAFT_QUANTIZATION_TYPE is a llama-quantize file-type preset (e.g. Q4_0, Q4_K_M)
# used directly for standalone draft files. The in-GGUF MTP / NextN tensor pins use
# --tensor-type, which needs a ggml tensor type, so reduce a K-quant preset to its
# base type here (Q4_K_M -> q4_K; Q4_0 / Q8_0 / IQ4_XS stay as-is).
$draftTensorType = $draftQuantizationType -replace '_K_[SML]$', '_K'

$naturalSort = { [regex]::Replace($_, '\d+', { $args[0].Value.PadLeft(20) }) }
$repositoryDirectories = @(Get-ChildItem -Directory $sourceDirectory -Name | Sort-Object $naturalSort)

$mistralFormatModels = @(
    "Devstral-2-123B-Instruct-2512"
    "Devstral-Small-2-24B-Instruct-2512"
)

# Convert a standalone draft (MTP / NextN head or EAGLE3) to a quantized draft GGUF
# in two steps, mirroring the main-model flow: convert to a high-fidelity
# intermediate in the cache, then quantize to any llama-quantize type. No imatrix is
# computed, so i-quants make llama-quantize error (intended; see README).
function Convert-StandaloneDraft {
    param(
        [Parameter(Mandatory)] [string] $SourceDirectoryPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $QuantizationType,
        [string] $TargetModelDir
    )

    $intermediatePath = Join-Path -Path $cacheDirectory -ChildPath "$(Split-Path -Path $SourceDirectoryPath -Leaf).draft.gguf"

    Invoke-Expression "python ${llamaCppDirectory}\convert_hf_to_gguf.py ``
        --outfile '${intermediatePath}' ``
        '${SourceDirectoryPath}' ``
        $(if ($TargetModelDir) {"--target-model-dir '${TargetModelDir}'"})"

    Invoke-Expression "${llamaCppDirectory}\build\bin\Release\llama-quantize.exe ``
        '${intermediatePath}' ``
        '${OutputPath}' ``
        '${QuantizationType}'"

    Remove-Item -Path $intermediatePath -Force
}

Write-Host "Quantizing $($repositoryDirectories.Length) large language models." -ForegroundColor "Yellow"

conda activate llama.cpp

ForEach ($repositoryName in $repositoryDirectories) {

    $sourceDirectoryPath = Join-Path -Path $sourceDirectory -ChildPath $repositoryName
    $targetDirectoryPath = Join-Path -Path $targetDirectory -ChildPath $repositoryName

    $isMistralFormat = $repositoryName -In $mistralFormatModels

    if (!(Test-Path -Path $targetDirectoryPath)) {
        New-Item -Path $targetDirectory -Name $repositoryName -ItemType "directory"
    }

    Write-Host "Working on ${repositoryName}..." -ForegroundColor "DarkYellow"

    # A standalone draft model (MTP / NextN head) is recognised by its config.json:
    # a draft architecture (*AssistantForCausalLM) or a backbone_hidden_size key.
    # It is converted to a separate draft GGUF (no mmproj, no imatrix) and skips the
    # main quantize path. The "mtp-" prefix marks it as a draft for llama.cpp:
    #   llama-server -m <main>.gguf -md <this>.gguf --spec-type draft-mtp
    $modelConfigPath = Join-Path -Path $sourceDirectoryPath -ChildPath "config.json"
    $modelConfigContent = if (Test-Path -Path $modelConfigPath) { Get-Content -Path $modelConfigPath -Raw } else { "" }

    if ($modelConfigContent -match 'AssistantForCausalLM|backbone_hidden_size') {

        $draftModelPath = Join-Path -Path $targetDirectoryPath -ChildPath "mtp-${repositoryName}.${draftQuantizationType}.gguf"

        if (!(Test-Path -Path $draftModelPath)) {

            Write-Host "Converting draft model ${sourceDirectoryPath} to ${draftModelPath} (${draftQuantizationType})..." -ForegroundColor "DarkYellow"

            Convert-StandaloneDraft -SourceDirectoryPath $sourceDirectoryPath -OutputPath $draftModelPath -QuantizationType $draftQuantizationType
        }

        continue
    }

    # EAGLE3 draft (config.json has draft_vocab_size): a separate draft GGUF that,
    # unlike MTP/NextN, needs the target model's HF dir (--target-model-dir) for the
    # target tokenizer + vocab/layer counts. Target read from the speculators config.
    if ($modelConfigContent -match '"draft_vocab_size"') {

        # -AsHashtable: speculators configs carry an empty-string key in auto_map
        # ("": "...") that ConvertFrom-Json rejects without it.
        $modelConfig = $modelConfigContent | ConvertFrom-Json -AsHashtable

        $eagle3ModelPath = Join-Path -Path $targetDirectoryPath -ChildPath "eagle3-${repositoryName}.${draftQuantizationType}.gguf"

        $targetReference = $modelConfig.speculators_config.verifier.name_or_path
        $targetReferenceName = if ($targetReference) { Split-Path -Path $targetReference -Leaf } else { $null }
        $targetRepositoryName = if ($targetReferenceName) {
            $repositoryDirectories | Where-Object { $_ -ieq $targetReferenceName } | Select-Object -First 1
        } else { $null }

        if (!$targetRepositoryName) {
            if ($targetReference) {
                Write-Host "Skipping EAGLE3 draft '${repositoryName}': it was trained for the target model '${targetReference}', but no matching directory '${targetReferenceName}' exists in ${sourceDirectory}. An EAGLE3 draft is not standalone - it reuses its target's tokenizer and taps the target's hidden states, so that exact target model must be present to convert. Clone it into '${sourceDirectory}\${targetReferenceName}' and re-run." -ForegroundColor "Red"
            } else {
                Write-Host "Skipping EAGLE3 draft '${repositoryName}': its config.json records no target model (no speculators_config.verifier.name_or_path), so the model it was trained on cannot be resolved automatically. EAGLE3 drafts need their specific target model's HuggingFace directory present to convert; provide it in ${sourceDirectory}." -ForegroundColor "Red"
            }
            continue
        }

        if (!(Test-Path -Path $eagle3ModelPath)) {

            $targetModelDirectoryPath = Join-Path -Path $sourceDirectory -ChildPath $targetRepositoryName

            Write-Host "Converting EAGLE3 draft ${sourceDirectoryPath} to ${eagle3ModelPath} (${draftQuantizationType}, target ${targetRepositoryName})..." -ForegroundColor "DarkYellow"

            Convert-StandaloneDraft -SourceDirectoryPath $sourceDirectoryPath -OutputPath $eagle3ModelPath -QuantizationType $draftQuantizationType -TargetModelDir $targetModelDirectoryPath
        }

        continue
    }

    $unquantizedModelPath = Join-Path -Path $cacheDirectory -ChildPath "${repositoryName}.gguf"

    # Note that we are not removing *.importance-matrix.gguf files because
    # they are relatively small but take a _very_ long time to compute.
    $importanceMatrixPath = Join-Path -Path $importanceMatrixDirectory -ChildPath "${repositoryName}.importance-matrix.gguf"

    # If a repository already contains an unquantized GGUF file we are using it directly.
    $unquantizedModelPathFromSource = Join-Path -Path $sourceDirectory -ChildPath $repositoryName | Join-Path -ChildPath "${repositoryName}.gguf"
    $unqantizedModelAvailableInSource = (Test-Path -Path $unquantizedModelPathFromSource)
    if ($unqantizedModelAvailableInSource) {
        Write-Host "Found unquantized model $unquantizedModelPathFromSource in source, skipping conversion..." -ForegroundColor "DarkYellow"
        $unquantizedModelPath = $unquantizedModelPathFromSource
    }

    # We are computing a multimodal projector file for each model to enable vision capabilities.
    ForEach ($multimodalProjectorType in $multimodalProjectorTypes) {

        $multimodalProjectorPath = Join-Path -Path $targetDirectoryPath -ChildPath "mmproj.${repositoryName}.${multimodalProjectorType}.gguf"

        if (!(Test-Path -Path $multimodalProjectorPath)) {

            Write-Host "Creating multimodal projector model from ${unquantizedModelPath} to ${multimodalProjectorPath}..." -ForegroundColor "DarkYellow"

            Invoke-Expression "python ${llamaCppDirectory}\convert_hf_to_gguf.py ``
                --outfile '${multimodalProjectorPath}' ``
                --outtype '$($multimodalProjectorType.ToLower())' ``
                '${sourceDirectoryPath}' ``
                --mmproj ``
                $(if ($isMistralFormat) {"--mistral-format"})"
        }
    }

    ForEach ($type in $quantizationTypes) {

        $quantizedModelPath = Join-Path -Path $targetDirectoryPath -ChildPath "${repositoryName}.${type}.gguf"

        if (!(Test-Path -Path $quantizedModelPath) -and !(Test-Path -Path $unquantizedModelPath)) {

            Write-Host "Converting ${sourceDirectoryPath} to ${unquantizedModelPath}..." -ForegroundColor "DarkYellow"

            Invoke-Expression "python ${llamaCppDirectory}\convert_hf_to_gguf.py ``
                --outfile '${unquantizedModelPath}' ``
                '${sourceDirectoryPath}' ``
                $(if ($isMistralFormat) {"--mistral-format"})"
        }

        # We are computing an importance matrix to enhance the quality of the models.
        # https://github.com/ggml-org/llama.cpp/tree/master/tools/imatrix
        if (!(Test-Path -Path $importanceMatrixPath)) {

            Write-Host "Computing importance matrix for ${unquantizedModelPath} at ${importanceMatrixPath} on GPU..." -ForegroundColor "DarkYellow"

            Invoke-Expression "${llamaCppDirectory}\build\bin\Release\llama-imatrix.exe ``
                --model '${unquantizedModelPath}' ``
                --file '${trainingDataPath}' ``
                --chunks ${trainingDataChunks} ``
                --output '${importanceMatrixPath}' ``
                --gpu-layers 999"
        }

        # We are falling back to CPU only importance matrix generation.
        if (!(Test-Path -Path $importanceMatrixPath)) {

            Write-Host "Computing importance matrix for ${unquantizedModelPath} at ${importanceMatrixPath} on CPU..." -ForegroundColor "DarkYellow"

            Invoke-Expression "${llamaCppDirectory}\build\bin\Release\llama-imatrix.exe ``
                --model '${unquantizedModelPath}' ``
                --file '${trainingDataPath}' ``
                --chunks ${trainingDataChunks} ``
                --output '${importanceMatrixPath}' ``
                --gpu-layers 0"
        }

        if (!(Test-Path -Path $quantizedModelPath)) {

            # llama-imatrix does not traverse MTP / NextN blocks during a standard
            # forward pass, so the transformer tensors inside those blocks get no
            # imatrix coverage. Very-low-bit quants (IQ3_XXS, IQ2_*, IQ1_*) refuse
            # to proceed without imatrix data and abort the whole run. We collect
            # every missing-imatrix tensor name in memory and pin it to
            # DRAFT_QUANTIZATION_TYPE (as the ggml tensor type $draftTensorType) via
            # repeated --tensor-type arguments. The legacy --tensor-type regexes
            # below remain as belt-and-braces.
            #
            # Track upstream:
            #   - https://github.com/ggml-org/llama.cpp/pull/23575
            #   - https://github.com/ggml-org/llama.cpp/pull/23258
            #
            # Once one of these lands and the llama.cpp pin in windows_llama.cpp is
            # bumped past it, delete tools\list_missing_imatrix_tensors.py, this
            # block, and the ${missingImatrixOverrides} reference in the quantize
            # call below.
            $missingImatrixOverrides = ""
            if (Test-Path -Path $importanceMatrixPath) {

                Write-Host "Detecting tensors missing from imatrix for ${repositoryName}..." -ForegroundColor "DarkYellow"

                $rules = & python "${PSScriptRoot}\tools\list_missing_imatrix_tensors.py" `
                    --bf16 $unquantizedModelPath `
                    --imatrix $importanceMatrixPath `
                    --quant-type $draftTensorType `
                    --gguf-py-path "${llamaCppDirectory}\gguf-py"

                if ($rules) {
                    $rules | ForEach-Object { Write-Host "  override: $_" -ForegroundColor "DarkGray" }
                    $missingImatrixOverrides = ($rules | ForEach-Object { "--tensor-type '$_'" }) -join " "
                }
            }

            Write-Host "Quantizing ${unquantizedModelPath} to ${quantizedModelPath}..." -ForegroundColor "DarkYellow"

            Invoke-Expression "${llamaCppDirectory}\build\bin\Release\llama-quantize.exe ``
                $(if (Test-Path -Path $importanceMatrixPath) {"--imatrix '${importanceMatrixPath}'"}) ``
                ${missingImatrixOverrides} ``
                --tensor-type 'blk\.[0-9]+\.nextn\..*=$($draftTensorType.ToLower())' ``
                --tensor-type 'mtp\..*=$($draftTensorType.ToLower())' ``
                '${unquantizedModelPath}' ``
                '${quantizedModelPath}' ``
                '${type}'"
        }
    }

    # We are exclusively removing unquantized models we created.
    # An unquantized model in the repository is left untouched.
    if ((Test-Path -Path $unquantizedModelPath) -and !($unqantizedModelAvailableInSource)) {

        Write-Host "Removing intermediate unquantized model ${unquantizedModelPath}..." -ForegroundColor "DarkYellow"
        Remove-Item "${unquantizedModelPath}" -Recurse -Force
    }
}

$stopwatch.Stop()
$durationInSeconds = [Math]::Floor([Decimal]($stopwatch.Elapsed.TotalSeconds))

Write-Host "Successfully finished the quantization in ${durationInSeconds} seconds." -ForegroundColor "Yellow"
