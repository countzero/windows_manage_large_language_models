$stopwatch = [System.Diagnostics.Stopwatch]::startNew()

Get-Content "./.env" | ForEach {

    $name, $value = $_.split('=', 2)

    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('#')) {
        return
    }

    Set-Content env:\$name $value
}

$sourceDirectory = Resolve-Path -Path $env:SOURCE_DIRECTORY

$lfsStorageDirectory = $env:SOURCE_DIRECTORY_LFS_STORAGE

$naturalSort = { [regex]::Replace($_, '\d+', { $args[0].Value.PadLeft(20) }) }

$repositoryDirectories = Get-ChildItem -Directory $sourceDirectory | Sort-Object $naturalSort

Write-Host "Downloading $($repositoryDirectories.Length) repositories..." -ForegroundColor "Yellow"

ForEach ($repositoryDirectory in $repositoryDirectories) {

    $repositoryDirectoryPath = $repositoryDirectory.FullName

    $repositoryOriginURI = git -C "${repositoryDirectoryPath}" config --get remote.origin.url

    Write-Host "Downloading ${repositoryOriginURI}..." -ForegroundColor "DarkYellow"

    $storageDirectory = "${repositoryDirectoryPath}\.git\lfs"

    # Git LFS uses an absolute lfs.storage verbatim, so mirroring the
    # repository name into it is this script's job rather than Git LFS's.
    if ($lfsStorageDirectory) {
        $storageDirectory = Join-Path $lfsStorageDirectory $repositoryDirectory.Name
        git -C "${repositoryDirectoryPath}" config lfs.storage $storageDirectory
    }

    Write-Host "Pruning incomplete large files..." -ForegroundColor "Yellow"
    if (Test-Path -Path "${storageDirectory}\incomplete") {
        Remove-Item "${storageDirectory}\incomplete\*" -Recurse -Force
    }

    Write-Host "Resetting working directory..." -ForegroundColor "Yellow"
    git -C "${repositoryDirectoryPath}" reset --hard HEAD

    Write-Host "Pulling regular files..." -ForegroundColor "Yellow"

    # We do not want the regular git pull command to also fetch
    # large lfs files, because it has no progress indicator.
    $env:GIT_LFS_SKIP_SMUDGE="1"

    git -C "${repositoryDirectoryPath}" pull

    Write-Host "Pulling large files..." -ForegroundColor "Yellow"
    git -C "${repositoryDirectoryPath}" -c lfs.concurrenttransfers=1 lfs pull
}

$stopwatch.Stop()
$durationInSeconds = [Math]::Floor([Decimal]($stopwatch.Elapsed.TotalSeconds))

Write-Host "Successfully finished the download in ${durationInSeconds} seconds." -ForegroundColor "Green"
