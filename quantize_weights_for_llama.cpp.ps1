$stopwatch = [System.Diagnostics.Stopwatch]::startNew()

Get-Content "./.env" | ForEach {

    $name, $value = $_.split('=', 2)

    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('#')) {
        return
    }

    Set-Content env:\$name $value
}

$llamaCppDirectory = $env:LLAMA_CPP_DIRECTORY
$sourceDirectory = $env:SOURCE_DIRECTORY
$targetDirectory = $env:TARGET_DIRECTORY
$cacheDirectory = $env:CACHE_DIRECTORY
$quantizationTypes = $env:QUANTIZATION_TYPES -split ','

$naturalSort = { [regex]::Replace($_, '\d+', { $args[0].Value.PadLeft(20) }) }

$repositoryDirectories = Get-ChildItem -Directory $sourceDirectory -Name | Sort-Object $naturalSort

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

    ForEach ($type in $quantizationTypes) {

        $quantizedModelPath = Join-Path -Path $targetDirectoryPath -ChildPath "model-quantized-${type}.gguf"

        if (!(Test-Path -Path $quantizedModelPath) -and !(Test-Path -Path $unquantizedModelPath)) {

            Write-Host "Converting ${sourceDirectoryPath} to ${unquantizedModelPath}..." -ForegroundColor "DarkYellow"

            $convertCommand = "${llamaCppDirectory}\convert.py --outfile $unquantizedModelPath $sourceDirectoryPath"

            Invoke-Expression "python $convertCommand"
        }

        if (!(Test-Path -Path $quantizedModelPath)) {

            $quantizeCommand = "${llamaCppDirectory}\build\bin\Release\quantize.exe"

            Write-Host "Quantizing ${unquantizedModelPath} to ${quantizedModelPath}..." -ForegroundColor "DarkYellow"

            Invoke-Expression "$quantizeCommand $unquantizedModelPath $quantizedModelPath $type"
        }
    }

    if ((Test-Path -Path $unquantizedModelPath)) {

        Write-Host "Removing intermediate unquantized model ${unquantizedModelPath}..." -ForegroundColor "DarkYellow"
        Remove-Item "${unquantizedModelPath}" -Recurse -Force
    }
}

$stopwatch.Stop()
$durationInSeconds = [Math]::Floor([Decimal]($stopwatch.Elapsed.TotalSeconds))

Write-Host "Successfully finished the quantization in ${durationInSeconds} seconds." -ForegroundColor "Yellow"
