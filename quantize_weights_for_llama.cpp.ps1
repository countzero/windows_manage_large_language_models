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

    $unquantizedModelPath = Join-Path -Path $cacheDirectory -ChildPath "${repositoryName}.model-unquantized.gguf"
    $importanceMatrixPath = Join-Path -Path $cacheDirectory -ChildPath "${repositoryName}.importance-matrix.dat"

    ForEach ($type in $quantizationTypes) {

        $quantizedModelPath = Join-Path -Path $targetDirectoryPath -ChildPath "model-quantized-${type}.gguf"

        if (!(Test-Path -Path $quantizedModelPath) -and !(Test-Path -Path $unquantizedModelPath)) {

            Write-Host "Converting ${sourceDirectoryPath} to ${unquantizedModelPath}..." -ForegroundColor "DarkYellow"

            $convertCommand = "python ${llamaCppDirectory}\convert.py"

            Invoke-Expression "$convertCommand --outfile `"${unquantizedModelPath}`" `"${sourceDirectoryPath}`""
        }

        if (("IQ2_XXS IQ2_XS IQ3_XXS".Contains($type)) -and !(Test-Path -Path $importanceMatrixPath)) {

            Write-Host "Computing importance matrix for ${unquantizedModelPath} at ${importanceMatrixPath}..." -ForegroundColor "DarkYellow"

            $imatrixCommand = "${llamaCppDirectory}\build\bin\Release\imatrix.exe"

            Invoke-Expression "$imatrixCommand -m `"${unquantizedModelPath}`" -f `"${trainingDataPath}`" -o `"${importanceMatrixPath}`""
        }

        if (!(Test-Path -Path $quantizedModelPath)) {

            Write-Host "Quantizing ${unquantizedModelPath} to ${quantizedModelPath}..." -ForegroundColor "DarkYellow"

            $quantizeCommand = "${llamaCppDirectory}\build\bin\Release\quantize.exe"

            Invoke-Expression "$quantizeCommand `"${unquantizedModelPath}`" `"${quantizedModelPath}`" `"${type}`""
        }
    }

    if ($cleanCache -and (Test-Path -Path $unquantizedModelPath)) {

        Write-Host "Removing intermediate unquantized model ${unquantizedModelPath}..." -ForegroundColor "DarkYellow"
        Remove-Item "${unquantizedModelPath}" -Recurse -Force
    }

    if ($cleanCache -and (Test-Path -Path $importanceMatrixPath)) {

        Write-Host "Removing intermediate unquantized model ${importanceMatrixPath}..." -ForegroundColor "DarkYellow"
        Remove-Item "${importanceMatrixPath}" -Recurse -Force
    }
}

$stopwatch.Stop()
$durationInSeconds = [Math]::Floor([Decimal]($stopwatch.Elapsed.TotalSeconds))

Write-Host "Successfully finished the quantization in ${durationInSeconds} seconds." -ForegroundColor "Yellow"