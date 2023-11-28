$stopwatch = [System.Diagnostics.Stopwatch]::startNew()

$llamaCppDirectory = "D:\Privat\GitHub\windows_llama.cpp\vendor\llama.cpp"
$sourceDirectory = "R:\AI\LLM\source"
$targetDirectory = "R:\AI\LLM\gguf"
$cacheDirectory = "E:\cache"

$exclude = @()

$types = @(
    # "q2_K"
    # "q3_K"
    # "q3_K_L"
    # "q3_K_M"
    # "q3_K_S"
    # "q4_0"
    # "q4_1"
    # "q4_K"
    "q4_K_M"
    # "q4_K_S"
    # "q5_0"
    # "q5_1"
    # "q5_K"
    # "q5_K_M"
    # "q5_K_S"
    # "q6_K"
    # "q8_0"
)

$naturalSort = { [regex]::Replace($_, '\d+', { $args[0].Value.PadLeft(20) }) }

$repositoryDirectories = Get-ChildItem -Directory $sourceDirectory -Exclude $exclude -Name | Sort-Object $naturalSort

Write-Host "Quantizing $($repositoryDirectories.Length) large language models." -ForegroundColor "Yellow"

conda activate llama.cpp

ForEach ($repositoryName in $repositoryDirectories) {

    $sourceDirectoryPath = Join-Path -Path $sourceDirectory -ChildPath $repositoryName
    $targetDirectoryPath = Join-Path -Path $targetDirectory -ChildPath $repositoryName

    if (!(Test-Path -Path $targetDirectoryPath)) {
        New-Item -Path $targetDirectory -Name $repositoryName -ItemType "directory"
    }

    Write-Host "Working on ${repositoryName}..." -ForegroundColor "DarkYellow"

    # We are creating the intermediate unquantized model in a dedicated cache directory
    # so that it can be locatend on another drive to improve the quantization speed.
    $unquantizedModelPath = Join-Path -Path $cacheDirectory -ChildPath "${repositoryName}.model-unquantized.gguf"

    ForEach ($type in $types) {

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
