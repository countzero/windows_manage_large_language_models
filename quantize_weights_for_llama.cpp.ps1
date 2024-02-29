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
$cacheDirectory = Resolve-Path -Path $env:CACHE_DIRECTORY
$trainingDataPath = Resolve-Path -Path $env:TRAINING_DATA
$cleanCache = [System.Convert]::ToBoolean($env:CLEAN_CACHE)
$quantizationTypes = $env:QUANTIZATION_TYPES -split ','

$naturalSort = { [regex]::Replace($_, '\d+', { $args[0].Value.PadLeft(20) }) }

$repositoryDirectories = @(Get-ChildItem -Directory $sourceDirectory -Name | Sort-Object $naturalSort)

Write-Host $repositoryDirectories

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
    $importanceMatrixPath = Join-Path -Path $cacheDirectory -ChildPath "${repositoryName}.importance-matrix.dat"

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

            $convertCommand = "python ${llamaCppDirectory}\convert.py"

            $convertParameters = "--outfile `"${unquantizedModelPath}`" `"${sourceDirectoryPath}`""

            # Some models have a Byte Pair Encoding (BPE) vocabulary type.
            if (@("Smaug-72B-v0.1").Contains($repositoryName)) {
                $convertParameters = "--vocab-type `"bpe`" --pad-vocab $convertParameters"
            }

            Invoke-Expression "$convertCommand $convertParameters"

            # Some model architectures have not yet been backported into
            # the official 'convert.py' script. We are assuming, that
            # novel model architectures (e.g., Phi-2) are implemented
            # in the 'convert-hf-to-gguf.py' script instead.
            if (!(Test-Path -Path $unquantizedModelPath)) {
                Write-Host "Conversion with 'convert.py' failed, trying 'convert-hf-to-gguf.py' instead..." -ForegroundColor "DarkYellow"
                $convertCommand = "python ${llamaCppDirectory}\convert-hf-to-gguf.py"
                Invoke-Expression "$convertCommand --outfile `"${unquantizedModelPath}`" `"${sourceDirectoryPath}`""
            }
        }

        # We need to compute an importance matrix for all i-quants and
        # small k-quants to enhance the quality of the quantum models.
        # https://github.com/ggerganov/llama.cpp/tree/master/examples/imatrix
        $requiresImportanceMatrix = $type.Contains("IQ") -or "Q2_K Q2_K_S".Contains($type)

        if ($requiresImportanceMatrix -and !(Test-Path -Path $importanceMatrixPath)) {

            Write-Host "Computing importance matrix for ${unquantizedModelPath} at ${importanceMatrixPath}..." -ForegroundColor "DarkYellow"

            $matrixCommand = "${llamaCppDirectory}\build\bin\Release\imatrix.exe"

            Invoke-Expression "$matrixCommand -m `"${unquantizedModelPath}`" -f `"${trainingDataPath}`" -o `"${importanceMatrixPath}`" -ngl 99"
        }

        if (!(Test-Path -Path $quantizedModelPath)) {

            Write-Host "Quantizing ${unquantizedModelPath} to ${quantizedModelPath}..." -ForegroundColor "DarkYellow"

            $quantizeCommand = "${llamaCppDirectory}\build\bin\Release\quantize.exe"

            if ($requiresImportanceMatrix) {
                $quantizeCommand = "${quantizeCommand} --imatrix `"${importanceMatrixPath}`""
            }

            Invoke-Expression "$quantizeCommand `"${unquantizedModelPath}`" `"${quantizedModelPath}`" `"${type}`""
        }
    }

    # We are exclusively removing unqantized models we created.
    # An unquantized model in the repository is left untouched.
    if ((Test-Path -Path $unquantizedModelPath) -and !($unqantizedModelAvailableInSource)) {

        Write-Host "Removing intermediate unquantized model ${unquantizedModelPath}..." -ForegroundColor "DarkYellow"
        Remove-Item "${unquantizedModelPath}" -Recurse -Force
    }

    # Note that we are not removing *.importance-matrix.dat files because
    # they are relatively small but take a _very_ long time to compute.
}

$stopwatch.Stop()
$durationInSeconds = [Math]::Floor([Decimal]($stopwatch.Elapsed.TotalSeconds))

Write-Host "Successfully finished the quantization in ${durationInSeconds} seconds." -ForegroundColor "Yellow"
