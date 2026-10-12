$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = 'C:\Lab1_ADS'
$vhd = Join-Path $root 'lab1_ntfs.vhdx'
$letter = 'L'
$drive = "${letter}:\"
$diskpartLogs = @()

function Run-DiskPart {
    param([string[]]$Commands)

    $scriptPath = Join-Path $root ("diskpart_{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -Path $scriptPath -Encoding ASCII -Value $Commands
    $output = & diskpart /s $scriptPath 2>&1
    $result = [pscustomobject]@{
        Script = $scriptPath
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
    return $result
}

function Get-FreeBytes {
    return ([System.IO.DriveInfo]::new("${letter}:")).AvailableFreeSpace
}

function Run-Cmd {
    param([string]$Command)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & cmd.exe /d /c $Command 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        Command = $Command
        ExitCode = $exitCode
        Output = ($output -join "`n")
    }
}

function Get-StreamInfo {
    param([string]$Path)

    return @(Get-Item -Path $Path -Stream * | Select-Object Stream, Length)
}

function Write-BytesToAds {
    param(
        [string]$HostFile,
        [string]$StreamName,
        [Int64]$Size
    )

    $streamPath = "\\?\$HostFile`:$StreamName"
    $fs = [System.IO.File]::Open($streamPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $buffer = New-Object byte[] 1048576
        [Int64]$remaining = $Size
        while ($remaining -gt 0) {
            $count = [int][Math]::Min([Int64]$buffer.Length, $remaining)
            $fs.Write($buffer, 0, $count)
            $remaining -= $count
        }
    }
    finally {
        $fs.Dispose()
    }
}

New-Item -ItemType Directory -Path $root -Force | Out-Null

if (-not (Test-Path $drive)) {
    if (-not (Test-Path $vhd)) {
        $diskpartLogs += Run-DiskPart @(
            "create vdisk file=`"$vhd`" maximum=512 type=expandable",
            "select vdisk file=`"$vhd`"",
            "attach vdisk",
            "create partition primary",
            "format fs=ntfs label=`"LAB1ADS`" quick",
            "assign letter=$letter",
            "exit"
        )
    }
    else {
        $diskpartLogs += Run-DiskPart @(
            "select vdisk file=`"$vhd`"",
            "attach vdisk",
            "select partition 1",
            "assign letter=$letter",
            "exit"
        )
    }
}

for ($i = 0; $i -lt 10 -and -not (Test-Path $drive); $i++) {
    Start-Sleep -Seconds 1
}

$volume = Get-Volume -DriveLetter $letter
if ($volume.FileSystem -ne 'NTFS') {
    throw "Drive ${letter}: is not NTFS"
}

$labPath = Join-Path $drive ("lab1_ads_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $labPath | Out-Null
Set-Location $labPath

$volumeBefore = [pscustomobject]@{
    DriveLetter = $volume.DriveLetter
    FileSystem = $volume.FileSystem
    FileSystemLabel = $volume.FileSystemLabel
    SizeBytes = $volume.Size
    FreeBytes = (Get-FreeBytes)
}

$mainFile = Join-Path $labPath 'test.txt'
Set-Content -Path $mainFile -Encoding ASCII -Value @(
    'This is the unnamed NTFS stream.',
    'The visible file length should not include ADS bytes.'
)

$fileSizeBeforeAds = (Get-Item -Path $mainFile).Length
$freeBeforeAaa = Get-FreeBytes
$createAaa = Run-Cmd 'dir > test.txt:aaa.txt'
$freeAfterAaa = Get-FreeBytes
$fileSizeAfterAaa = (Get-Item -Path $mainFile).Length
$streamsAfterAaa = Get-StreamInfo $mainFile

$moreAaa = Run-Cmd 'more < test.txt:aaa.txt'
$copyAaaToFile = Run-Cmd 'more < test.txt:aaa.txt > testdir.txt'
$testdir = Join-Path $labPath 'testdir.txt'
$testdirSize = (Get-Item -Path $testdir).Length
$testdirPreview = @(Get-Content -Path $testdir | Select-Object -First 8)

$typeMain = Run-Cmd 'type test.txt'
$typeAdsDirect = Run-Cmd 'type test.txt:aaa.txt'
$typeAdsRedirect = Run-Cmd 'type < test.txt:aaa.txt'
$echoAds = Run-Cmd 'echo created_by_echo > test.txt:echo.txt'
$moreEchoAds = Run-Cmd 'more < test.txt:echo.txt'
$dirR = Run-Cmd 'dir /r'
$powershellGetContentAaa = @(Get-Content -Path $mainFile -Stream 'aaa.txt' | Select-Object -First 8)
$certutilHashAaa = Run-Cmd 'certutil -hashfile test.txt:aaa.txt SHA256'

$measureFiles = @()
for ($idx = 0; $idx -lt $sizes.Count; $idx++) {
    $measureFiles += Join-Path $labPath ('measure_{0:D2}.txt' -f ($idx + 1))
    Set-Content -Path $measureFiles[-1] -Encoding ASCII -Value 'Container file for binary ADS measurements.'
}

$measureStartFree = Get-FreeBytes
$sizes = @(
    997, 1999, 4093, 8191, 16381,
    32749, 65521, 131071, 262139, 524287,
    1048573, 2097143, 4194301, 8388593, 16777199,
    25165813, 33554431, 50331653, 67108859, 100663291
)
$measurementRows = @()
$measurementRows += [pscustomobject]@{
    Step = 0
    Stream = ''
    AddedBytes = 0
    CumulativeAdsBytes = 0
    FreeBytes = $measureStartFree
    FreeDecreaseBytes = 0
}

[Int64]$cumulative = 0
for ($idx = 0; $idx -lt $sizes.Count; $idx++) {
    $size = [Int64]$sizes[$idx]
    $measureFile = $measureFiles[$idx]
    $streamName = 'payload.bin'
    Write-BytesToAds -HostFile $measureFile -StreamName $streamName -Size $size
    $cumulative += $size
    $freeNow = Get-FreeBytes
    $measurementRows += [pscustomobject]@{
        Step = ($idx + 1)
        Stream = $streamName
        AddedBytes = $size
        CumulativeAdsBytes = $cumulative
        FreeBytes = $freeNow
        FreeDecreaseBytes = ($measureStartFree - $freeNow)
    }
}

$measureStreams = @($measureFiles | ForEach-Object { Get-StreamInfo $_ })
$volumeAfter = Get-Volume -DriveLetter $letter

$result = [pscustomobject]@{
    Timestamp = (Get-Date).ToString('s')
    ComputerName = $env:COMPUTERNAME
    UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    LabPath = $labPath
    VhdPath = $vhd
    Diskpart = $diskpartLogs
    VolumeBefore = $volumeBefore
    MainFile = [pscustomobject]@{
        Path = $mainFile
        SizeBeforeAdsBytes = $fileSizeBeforeAds
        SizeAfterAaaAdsBytes = $fileSizeAfterAaa
        FreeBeforeAaaBytes = $freeBeforeAaa
        FreeAfterAaaBytes = $freeAfterAaa
        FreeDecreaseAfterAaaBytes = ($freeBeforeAaa - $freeAfterAaa)
        StreamsAfterAaa = $streamsAfterAaa
    }
    Commands = [pscustomobject]@{
        CreateAaa = $createAaa
        MoreAaa = $moreAaa
        CopyAaaToFile = $copyAaaToFile
        TypeMain = $typeMain
        TypeAdsDirect = $typeAdsDirect
        TypeAdsRedirect = $typeAdsRedirect
        EchoAds = $echoAds
        MoreEchoAds = $moreEchoAds
        DirR = $dirR
        CertutilHashAaa = $certutilHashAaa
    }
    PowerShellGetContentAaaPreview = $powershellGetContentAaa
    Testdir = [pscustomobject]@{
        Path = $testdir
        SizeBytes = $testdirSize
        Preview = $testdirPreview
    }
    Measurement = [pscustomobject]@{
        HostFiles = $measureFiles
        Rows = $measurementRows
        Streams = $measureStreams
    }
    VolumeAfter = [pscustomobject]@{
        DriveLetter = $volumeAfter.DriveLetter
        FileSystem = $volumeAfter.FileSystem
        FileSystemLabel = $volumeAfter.FileSystemLabel
        SizeBytes = $volumeAfter.Size
        FreeBytes = (Get-FreeBytes)
    }
}

$json = $result | ConvertTo-Json -Depth 8
Set-Content -Path (Join-Path $root 'last_results.json') -Encoding UTF8 -Value $json
$json
