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

$naturalSort = { [regex]::Replace($_, '\d+', { $args[0].Value.PadLeft(20) }) }
$repositoryDirectories = @(Get-ChildItem -Directory $sourceDirectory -Name | Sort-Object $naturalSort)

Write-Host "Quantizing $($repositoryDirectories.Length) large language models." -ForegroundColor "Yellow"

conda activate llama.cpp

ForEach ($repositoryName in $repositoryDirectories) {

    $sourceDirectoryPath = Join-Path -Path $sourceDirectory -ChildPath $repositoryName
    $targetDirectoryPath = Join-Path -Path $targetDirectory -ChildPath $repositoryName

    if (!(Test-Path -Path $targetDirectoryPath)) {
        New-Item -Path $targetDirectory -Name $repositoryName -ItemType "directory"
    }

    Write-Host "Working on ${repositoryName}..." -ForegroundColor "DarkYellow"

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

    ForEach ($type in $quantizationTypes) {

        $quantizedModelPath = Join-Path -Path $targetDirectoryPath -ChildPath "${repositoryName}.${type}.gguf"

        if (!(Test-Path -Path $quantizedModelPath) -and !(Test-Path -Path $unquantizedModelPath)) {

            Write-Host "Converting ${sourceDirectoryPath} to ${unquantizedModelPath}..." -ForegroundColor "DarkYellow"

            Invoke-Expression "python ${llamaCppDirectory}\convert_hf_to_gguf.py ``
                --outfile '${unquantizedModelPath}' ``
                '${sourceDirectoryPath}'"
        }

        $multimodalProjectorPath = Join-Path -Path $targetDirectoryPath -ChildPath "${repositoryName}.mmproj.F16.gguf"

        # We are computing a multimodal projector model in F16
        # format for each model to enable vision capabilities.
        if (!(Test-Path -Path $multimodalProjectorPath)) {

            Write-Host "Creating multimodal projector model from ${unquantizedModelPath} to ${multimodalProjectorPath}..." -ForegroundColor "DarkYellow"

            Invoke-Expression "python ${llamaCppDirectory}\convert_hf_to_gguf.py ``
                --outfile '${multimodalProjectorPath}' ``
                --outtype 'f16' ``
                '${sourceDirectoryPath}' ``
                --mmproj"
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

            Write-Host "Quantizing ${unquantizedModelPath} to ${quantizedModelPath}..." -ForegroundColor "DarkYellow"

            Invoke-Expression "${llamaCppDirectory}\build\bin\Release\llama-quantize.exe ``
                $(if (Test-Path -Path $importanceMatrixPath) {"--imatrix '${importanceMatrixPath}'"}) ``
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
