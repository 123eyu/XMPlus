#requires -Version 5.1
<#
Builds directly in the workspace; closes XMPlus instances before replacing outputs.
Never launches XMPlus or changes the shared SDK. Source archives and build evidence
remain outside the runtime bundle. Without -LocalCandidate, incomplete source gates fail
before pub get. -ReplaceLocalCandidate replaces only a recognized private candidate,
retaining the previous bundle/ZIP as uniquely named backups.
#>
[CmdletBinding()]
param(
    [switch]$LocalCandidate,
    [switch]$ReplaceLocalCandidate,
    [string]$NugetPath,
    [string]$FFmpegZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$SdkRoot = 'C:\src\flutter'
$Flutter = Join-Path $SdkRoot 'bin\flutter.bat'
$PackageName = 'XMPlus-1.0.0-windows-x64'
$SourceName = 'XMPlus-1.0.0-source'
$FixedFFmpegHash = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-Json([string]$Path) {
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 100), $Utf8)
}
function Field($Object, [string]$Name) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $null
}
function Ensure-Directory([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
}
function Assert-PlainPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points are not allowed in packaging inputs: $Path"
    }
}
function Child-Path([string]$Base, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) {
        throw "Expected a relative packaging path: $Relative"
    }
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $Base $Relative))
    if (-not $full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Packaging path escapes its root: $Relative"
    }
    return $full
}
function Relative-Path([string]$Base, [string]$Path) {
    $prefix = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "File is outside the packaging root: $Path"
    }
    return $full.Substring($prefix.Length).Replace('\', '/')
}
function File-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-Hash([string]$Path, [string]$Expected) {
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw "Missing SHA-256 for $Path" }
    Assert-PlainPath $Path
    if ((File-Hash $Path) -ne $Expected.ToLowerInvariant()) { throw "SHA-256 mismatch: $Path" }
}
function Copy-File([string]$From, [string]$To) {
    Assert-PlainPath $From
    if ((Split-Path -Leaf $From) -match '(?i)^readme') {
        throw "Standalone README files must not be copied: $From"
    }
    Ensure-Directory (Split-Path -Parent $To)
    [IO.File]::Copy($From, $To, $false)
}
function Copy-Tree([string]$From, [string]$To, [string]$Mode) {
    Assert-PlainPath $From
    Ensure-Directory $To
    foreach ($item in Get-ChildItem -LiteralPath $From -Force) {
        if ($item.Name -match '(?i)^readme') { continue }
        if ($item.Name -in @('.git', '.dart_tool', '.plugin_symlinks', 'ephemeral', 'build', 'dist')) { continue }
        if ($Mode -eq 'windows' -and $item.Name -like 'generated_*') { continue }
        Assert-PlainPath $item.FullName
        $destination = Join-Path $To $item.Name
        if ($item.PSIsContainer) {
            Copy-Tree $item.FullName $destination $Mode
        } else {
            $allowed = $true
            if ($Mode -eq 'dart') { $allowed = $item.Extension -eq '.dart' }
            if ($Mode -eq 'assets') { $allowed = $item.Extension -in @('.png', '.jpg', '.jpeg', '.webp', '.svg', '.ico', '.ttf', '.otf', '.json') }
            if ($Mode -eq 'windows') {
                $allowed = $item.Name -in @('CMakeLists.txt', 'LICENSE.PiliPlus', '.gitignore') -or
                    $item.Extension -in @('.cpp', '.cc', '.h', '.rc', '.manifest', '.ico', '.png')
            }
            if ($allowed) { Copy-File $item.FullName $destination }
        }
    }
}
function Assert-MicrosoftSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw "NuGet must have a valid Microsoft Authenticode signature: $Path"
    }
}
function Download-File([string]$Url, [string]$Path) {
    # ServicePointManager and PATH changes below are process-local, restored on exit.
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -TimeoutSec 180
}
function Invoke-Flutter([string[]]$Arguments) {
    $savedCredential = [Environment]::GetEnvironmentVariable('XMLY_TEST_CREDENTIALS_JSON', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('XMLY_TEST_CREDENTIALS_JSON', $null, 'Process')
        & $Flutter --suppress-analytics @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Flutter exited with code $LASTEXITCODE ($($Arguments[0]))." }
    } finally {
        [Environment]::SetEnvironmentVariable('XMLY_TEST_CREDENTIALS_JSON', $savedCredential, 'Process')
    }
}
function Tool-Identity([string]$Executable, [string]$Argument) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $Argument
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    [void]$info.EnvironmentVariables.Remove('XMLY_TEST_CREDENTIALS_JSON')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Metadata command failed: $Executable $Argument" }
        return $text
    } finally { $process.Dispose() }
}
function Stop-ProjectClients {
    $prefix = $ProjectRoot.TrimEnd('\') + '\'
    foreach ($item in Get-CimInstance -ClassName Win32_Process -Filter "Name='XMPlus.exe' OR Name='xmly_flutter.exe'") {
        $path = [string]$item.ExecutablePath
        if (-not $path) { throw "Cannot identify the application at PID $($item.ProcessId)." }
        $isProject = $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        if (-not $isProject -and [Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductName -ne 'XMPlus') { continue }
        $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try {
            if (-not $process.HasExited) {
                Write-Host "Closing XMPlus PID $($process.Id) for the workspace build."
                [void]$process.CloseMainWindow()
                if (-not $process.WaitForExit(10000)) {
                    $process.Kill()
                    $process.WaitForExit()
                }
            }
        } finally { $process.Dispose() }
    }
}
function Assert-Replacement([string]$Target, [string]$Zip, [string]$SourceZip) {
    $hasTarget = Test-Path -LiteralPath $Target
    $hasZip = Test-Path -LiteralPath $Zip
    if (Test-Path -LiteralPath $SourceZip) { throw "Existing source ZIP must be preserved: $SourceZip" }
    if (-not $hasTarget -and -not $hasZip) { return }
    if (-not $LocalCandidate -or -not $ReplaceLocalCandidate -or -not $hasTarget) {
        throw 'Output exists; only -LocalCandidate -ReplaceLocalCandidate may replace a recognized private candidate.'
    }
    Assert-PlainPath $Target
    $statusPath = Join-Path $Target 'RELEASE-STATUS.json'
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw 'Existing output has no ownership status.' }
    $status = Read-Json $statusPath
    if ((Field $status 'application') -ne 'XMPlus' -or (Field $status 'package') -ne $PackageName -or
        (Field $status 'status') -ne 'local-verification-only' -or
        (Field $status 'redistributionReady') -ne $false) {
        throw 'Existing output is not a matching XMPlus private candidate.'
    }
    if ($hasZip) { Assert-PlainPath $Zip }
}
function File-Inventory([string]$Root) {
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName) {
        Assert-PlainPath $file.FullName
        [pscustomobject]@{ path = (Relative-Path $Root $file.FullName); bytes = $file.Length; sha256 = (File-Hash $file.FullName) }
    }
}
function New-VerifiedZip([string]$Directory, [string]$ZipPath) {
    # Stream the runtime payload and use standard compact compression for bundled tools.
    $files = @(File-Inventory $Directory)
    $prefix = (Split-Path -Leaf $Directory) + '/'
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,
                (Child-Path $Directory $file.path), ($prefix + $file.path), [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($zip.Entries.Count -ne $files.Count) { throw 'ZIP entry count mismatch.' }
        foreach ($file in $files) {
            $entry = $zip.GetEntry($prefix + $file.path)
            if ($null -eq $entry -or $entry.Length -ne $file.bytes) { throw "ZIP entry mismatch: $($file.path)" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            if ($hash -ne $file.sha256) { throw "ZIP verification failed: $($file.path)" }
        }
    } finally { $zip.Dispose() }
}

$ffmpegManifest = Read-Json (Join-Path $ProjectRoot 'tool\ffmpeg_sources.json')
$nativeManifest = Read-Json (Join-Path $ProjectRoot 'tool\native_sources.json')
$blockers = New-Object 'System.Collections.Generic.List[string]'
if ((Field $ffmpegManifest.releaseCompliance 'redistributionReady') -ne $true -or
    (Field $ffmpegManifest.releaseCompliance 'completeCorrespondingSource') -ne $true) {
    $blockers.Add('FFmpeg exact publisher recipes/patches and full corresponding-source closure are incomplete.')
    foreach ($missing in $ffmpegManifest.missing) { $blockers.Add('FFmpeg: ' + $missing.id) }
}
if ((Field $nativeManifest 'distributionReady') -ne $true -or
    (Field $nativeManifest 'correspondingSourceComplete') -ne $true) {
    $blockers.Add('Native dependency corresponding sources and CRT redistribution rights are incomplete.')
    foreach ($missing in $nativeManifest.missing) { $blockers.Add('Native: ' + $missing.id) }
}
if (-not $LocalCandidate -and $blockers.Count -gt 0) {
    throw ("Public release blocked. Use -LocalCandidate only for private local verification.`n - " + ($blockers -join "`n - "))
}
if ($ReplaceLocalCandidate -and -not $LocalCandidate) { throw '-ReplaceLocalCandidate requires -LocalCandidate.' }
if ($ffmpegManifest.package.sha256 -ne $FixedFFmpegHash -or $ffmpegManifest.version -ne '9.0.2') {
    throw 'FFmpeg manifest does not describe the pinned Gyan 9.0.2 package.'
}
$sdk = Read-Json (Join-Path $SdkRoot 'bin\cache\flutter.version.json')
if ($sdk.frameworkVersion -ne '3.47.5' -or $sdk.dartSdkVersion -ne '3.13.4') {
    throw 'Required SDK: Flutter 3.47.5 / Dart 3.13.4. The shared SDK will not be upgraded.'
}
$pubspec = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'pubspec.yaml'), [Text.Encoding]::UTF8)
if ($pubspec -notmatch '(?m)^name:\s*xmly_flutter\s*$' -or $pubspec -notmatch '(?m)^version:\s*1\.0\.0\+1\s*$') {
    throw 'This packaging script requires xmly_flutter version 1.0.0+1.'
}
$dist = Join-Path $ProjectRoot 'dist'
$target = Join-Path $dist $PackageName
$targetZip = $target + '.zip'
$targetSourceZip = Join-Path $dist ($SourceName + '.zip')
Stop-ProjectClients
Assert-Replacement $target $targetZip $targetSourceZip

$stage = Join-Path $ProjectRoot ('build\xmplus-package-' + [Guid]::NewGuid().ToString('N'))
$source = $ProjectRoot
$bundle = Join-Path $stage $PackageName
Ensure-Directory $bundle
$oldPath = $env:PATH
$oldTls = [Net.ServicePointManager]::SecurityProtocol
$oldLocation = Get-Location
try {
    [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $lockHash = File-Hash (Join-Path $source 'pubspec.lock')

    if ($NugetPath) {
        $NugetPath = (Resolve-Path -LiteralPath $NugetPath).Path
        Assert-MicrosoftSignature $NugetPath
    } else {
        $pinnedNuget = 'C:\Users\Nahida\AppData\Local\Temp\xmly-build-tools-9yvSEa\nuget.exe'
        if (Test-Path -LiteralPath $pinnedNuget -PathType Leaf) {
            Assert-MicrosoftSignature $pinnedNuget
            $NugetPath = $pinnedNuget
        } else {
            $NugetPath = Join-Path $stage 'nuget-download.exe'
            Download-File 'https://dist.nuget.org/win-x86-commandline/v6.14.0/nuget.exe' $NugetPath
            Assert-MicrosoftSignature $NugetPath
        }
    }
    # A private nuget.exe always wins PATH; no global install or PATH update.
    $buildTools = Join-Path $stage 'build-tools'
    Ensure-Directory $buildTools
    Copy-File $NugetPath (Join-Path $buildTools 'nuget.exe')
    Assert-MicrosoftSignature (Join-Path $buildTools 'nuget.exe')
    $env:PATH = $buildTools + ';' + $oldPath
    Set-Location -LiteralPath $source
    Invoke-Flutter -Arguments @('pub', 'get', '--enforce-lockfile')
    Assert-Hash (Join-Path $source 'pubspec.lock') $lockHash
    # Discard only the obsolete pre-branding CMake cache, not user data or SDK files.
    $cache = Join-Path $ProjectRoot 'build\windows\x64\CMakeCache.txt'
    if ((Test-Path -LiteralPath $cache) -and
        [IO.File]::ReadAllText($cache).Contains('CMAKE_INSTALL_PREFIX:PATH=$<TARGET_FILE_DIR:xmly_flutter>')) {
        Remove-Item -LiteralPath $cache
    }
    foreach ($name in @('xmly_flutter.exe', 'cnativeapi.dll')) {
        $obsolete = Join-Path $ProjectRoot ('build\windows\x64\runner\Release\' + $name)
        if (Test-Path -LiteralPath $obsolete -PathType Leaf) { Remove-Item -LiteralPath $obsolete }
    }
    Invoke-Flutter -Arguments @('build', 'windows', '--release', '--no-pub')
    Assert-Hash (Join-Path $source 'pubspec.lock') $lockHash

    $release = Join-Path $source 'build\windows\x64\runner\Release'
    Copy-File (Join-Path $release 'XMPlus.exe') (Join-Path $bundle 'XMPlus.exe')
    Copy-Tree (Join-Path $release 'data') (Join-Path $bundle 'data') 'runtime'
    foreach ($dll in Get-ChildItem -LiteralPath $release -Filter '*.dll' -File) {
        Copy-File $dll.FullName (Join-Path $bundle $dll.Name)
    }
    foreach ($required in @('data\app.so', 'data\icudtl.dat', 'data\flutter_assets', 'flutter_windows.dll',
        'libmpv-2.dll', 'flutter_inappwebview_windows_plugin.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "Incomplete runner bundle: $required" }
    }
    $enginePath = Join-Path $SdkRoot 'bin\cache\artifacts\engine\windows-x64-release\flutter_windows.dll'
    $engineHash = File-Hash $enginePath
    Assert-Hash (Join-Path $bundle 'flutter_windows.dll') $engineHash
    $mpv = @($nativeManifest.components | Where-Object { $_.name -eq 'libmpv-2.dll' })
    if ($mpv.Count -ne 1) { throw 'Missing unique libmpv manifest entry.' }
    Assert-Hash (Join-Path $bundle 'libmpv-2.dll') $mpv[0].binary.sha256
    $crt = @($nativeManifest.components | Where-Object { $_.name -eq 'Microsoft Visual C++ runtime' })
    if ($crt.Count -ne 1 -or @($crt[0].candidates).Count -ne 3) { throw 'Expected three declared CRT DLLs.' }
    foreach ($candidate in $crt[0].candidates) {
        if ($candidate.name -notin @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) { throw 'Unexpected CRT candidate.' }
        Assert-Hash $candidate.sourcePath $candidate.sha256
        $destination = Join-Path $bundle $candidate.name
        if (Test-Path -LiteralPath $destination) { Assert-Hash $destination $candidate.sha256 }
        else { Copy-File $candidate.sourcePath $destination }
    }

    if ($FFmpegZip) { $FFmpegZip = (Resolve-Path -LiteralPath $FFmpegZip).Path }
    elseif (Test-Path -LiteralPath $ffmpegManifest.package.localPath -PathType Leaf) { $FFmpegZip = $ffmpegManifest.package.localPath }
    else {
        $FFmpegZip = Join-Path $stage 'ffmpeg-9.0.2-essentials_build.zip'
        try { Download-File 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip' $FFmpegZip }
        catch { Download-File 'https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip' $FFmpegZip }
    }
    Assert-Hash $FFmpegZip $FixedFFmpegHash
    $ffmpegTools = Join-Path $bundle 'tools\ffmpeg'
    Ensure-Directory $ffmpegTools
    $archive = [IO.Compression.ZipFile]::OpenRead($FFmpegZip)
    try {
        foreach ($name in @('ffmpeg.exe', 'ffprobe.exe', 'LICENSE')) {
            $entries = @($archive.Entries | Where-Object {
                if ($name -eq 'LICENSE') { $_.FullName -match '^[^/]+/LICENSE$' }
                else { $_.FullName -eq ('ffmpeg-9.0.2-essentials_build/bin/' + $name) }
            })
            if ($entries.Count -ne 1) { throw "Expected one fixed FFmpeg ZIP member: $name" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], (Join-Path $ffmpegTools $name), $false)
        }
    } finally { $archive.Dispose() }
    $identities = @()
    foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
        $tool = @($ffmpegManifest.package.tools | Where-Object { $_.name -eq $name })
        if ($tool.Count -ne 1) { throw "Missing pinned executable digest: $name" }
        $executable = Join-Path $ffmpegTools $name
        Assert-Hash $executable $tool[0].sha256
        $versionText = Tool-Identity $executable '-version'
        if ($versionText -notmatch 'version 9\.0\.2') { throw "Unexpected FFmpeg version: $name" }
        $buildConf = (($versionText -split '\r?\n' | Where-Object { $_ -match '^configuration:' }) -join "`r`n")
        if (-not $buildConf) { throw "Missing embedded FFmpeg build configuration: $name" }
        [IO.File]::WriteAllText((Join-Path $ffmpegTools ($name + '.buildconf.txt')), $buildConf, $Utf8)
        $identities += [pscustomobject]@{ name = $name; sha256 = $tool[0].sha256; version = $versionText; buildConfiguration = $buildConf }
    }
    Write-Json (Join-Path $ffmpegTools 'version-identity.json') ([ordered]@{ packageSha256 = $FixedFFmpegHash; tools = $identities })

    Copy-File (Join-Path $ProjectRoot 'LICENSE') (Join-Path $bundle 'LICENSE')
    Copy-File (Join-Path $ProjectRoot 'NOTICE') (Join-Path $bundle 'NOTICE')
    Copy-File (Join-Path $ProjectRoot 'windows\LICENSE.PiliPlus') (Join-Path $bundle 'LICENSE.PiliPlus')
    # Runtime payload: licenses and notices only, not source archives or build evidence.
    $nativeLicenses = @($nativeManifest.artifacts | Where-Object {
        $_.path -like 'licenses/native/licenses/*' -and $_.path -notlike '*.docx'
    })
    foreach ($artifact in $nativeLicenses) {
        Assert-Hash (Child-Path $ProjectRoot $artifact.path) $artifact.sha256
        $destination = Child-Path $bundle $artifact.path
        Copy-File (Child-Path $ProjectRoot $artifact.path) $destination
        Assert-Hash $destination $artifact.sha256
    }
    foreach ($name in @('FFmpeg-LICENSE.txt', 'Flutter-windows-binary-license.txt', 'mpv-Copyright.txt')) {
        $relative = 'licenses/native/evidence/' + $name
        $artifact = @($nativeManifest.artifacts | Where-Object { $_.path -eq $relative })
        if ($artifact.Count -ne 1) { throw "Missing native copyright notice: $name" }
        Assert-Hash (Child-Path $ProjectRoot $relative) $artifact[0].sha256
        Copy-File (Child-Path $ProjectRoot $relative) (Join-Path $bundle ('licenses\native\licenses\' + $name))
    }
    foreach ($name in @('LICENSE-GPL-3.0.txt', 'THIRD-PARTY-LICENSES.txt')) {
        Copy-File (Join-Path $ProjectRoot ('licenses\ffmpeg\' + $name)) (Join-Path $bundle ('licenses\ffmpeg\' + $name))
    }
    $mpv = @($nativeManifest.components | Where-Object { $_.name -eq 'libmpv-2.dll' })[0]
    $nativeSdk = @($nativeManifest.components | Where-Object { $_.name -eq 'WebView2Loader, WIL, nlohmann.json' })[0]
    $origins = [ordered]@{
        schemaVersion = 1
        application = 'XMPlus 1.0.0+1'
        notice = 'Version and upstream origin references only; matching complete corresponding source is not asserted. Source archives and build evidence are maintained separately from this runtime bundle.'
        flutter = [ordered]@{ version = $sdk.frameworkVersion; frameworkCommit = $sdk.frameworkRevision; engineCommit = $sdk.engineRevision; url = 'https://github.com/flutter/flutter' }
        upstreamEntries = $nativeManifest.aboutSourceEntry.upstreamEntries
        packages = @($nativeManifest.packages | Select-Object name, version, url, archiveSha256)
        nativeSdk = @($nativeSdk.packages | ForEach-Object {
            [ordered]@{ name = $_.name; version = $_.version; url = $_.artifact.source; sha256 = $_.artifact.sha256 }
        })
        libmpv = [ordered]@{ binarySha256 = $mpv.binary.sha256; url = $mpv.download.url; mpvSourceCommit = $mpv.mpvSourceCommit; ffmpegBaseCommit = $mpv.ffmpegBaseCommit; license = $mpv.licenseClassification }
        sourcePins = $nativeManifest.sourcePins
        ffmpeg = [ordered]@{
            version = $ffmpegManifest.version; url = $ffmpegManifest.package.url; packageSha256 = $FixedFFmpegHash; license = $ffmpegManifest.package.license
            tools = @($ffmpegManifest.package.tools | Select-Object name, sha256)
            sourcePins = @($ffmpegManifest.sourceArchives | Select-Object component, repository, ref, license)
        }
    }
    Write-Json (Join-Path $bundle 'licenses\SOURCES.json') $origins
    $private = [bool]$LocalCandidate
    $statusValue = 'redistribution-material-gates-cleared'
    if ($private) { $statusValue = 'local-verification-only' }
    $status = [ordered]@{
        schemaVersion = 1; application = 'XMPlus'; version = '1.0.0+1'; package = $PackageName
        status = $statusValue; redistributionReady = (-not $private -and $blockers.Count -eq 0)
        generatedAtUtc = [DateTime]::UtcNow.ToString('o'); blockers = @($blockers.ToArray())
        ffmpegReleaseCompliance = $ffmpegManifest.releaseCompliance
        nativeDistributionReady = $nativeManifest.distributionReady
        functionalValidation = 'Not performed by this script; SMS/reward UI and no-playback acceptance belong to the parent.'
        sourceArchive = $null
    }
    if ($private) {
        [IO.File]::WriteAllText((Join-Path $bundle 'SOURCE-MATERIALS-INCOMPLETE.txt'),
            "PRIVATE LOCAL VERIFICATION ONLY - NOT FOR REDISTRIBUTION.`r`n" +
            "Corresponding-source and functional-validation gates are not asserted by this build.`r`n" +
            ($blockers -join "`r`n") + "`r`nSee licenses/SOURCES.json for version and origin references; source materials are maintained separately.`r`n", $Utf8)
    }

    $stagedSourceZip = $null
    if (-not $private) {
        # A clean app-only allowlist; no whole-workspace/archive glob, Python or account data.
        $appSource = Join-Path $stage $SourceName
        Ensure-Directory $appSource
        foreach ($tree in @('lib', 'windows', 'assets')) {
            $mode = $tree
            if ($tree -eq 'lib') { $mode = 'dart' }
            Copy-Tree (Join-Path $source $tree) (Join-Path $appSource $tree) $mode
        }
        foreach ($name in @('pubspec.yaml', 'pubspec.lock')) { Copy-File (Join-Path $source $name) (Join-Path $appSource $name) }
        foreach ($name in @('LICENSE', 'NOTICE', 'CHANGELOG.md')) { Copy-File (Join-Path $ProjectRoot $name) (Join-Path $appSource $name) }
        foreach ($name in @('build_windows.ps1', 'ffmpeg_sources.json', 'native_sources.json')) {
            Copy-File (Join-Path $ProjectRoot ('tool\' + $name)) (Join-Path $appSource ('tool\' + $name))
        }
        $stagedSourceZip = Join-Path $stage ($SourceName + '.zip')
        New-VerifiedZip $appSource $stagedSourceZip
        $status.sourceArchive = [ordered]@{ file = ($SourceName + '.zip'); sha256 = (File-Hash $stagedSourceZip) }
    }
    Write-Json (Join-Path $bundle 'RELEASE-STATUS.json') $status
    $manifest = [ordered]@{
        schemaVersion = 1; application = 'XMPlus'; version = '1.0.0+1'; buildMode = 'release'; target = 'windows-x64'
        flutterVersion = $sdk.frameworkVersion; dartVersion = $sdk.dartSdkVersion
        frameworkRevision = $sdk.frameworkRevision; engineRevision = $sdk.engineRevision
        engineSha256 = $engineHash; pubspecLockSha256 = $lockHash; ffmpegPackageSha256 = $FixedFFmpegHash
        fileHashScope = 'Every payload file except BUILD-MANIFEST.json itself; ZIP creation also hashes and verifies the manifest.'
        files = @(File-Inventory $bundle)
    }
    Write-Json (Join-Path $bundle 'BUILD-MANIFEST.json') $manifest
    $stagedZip = Join-Path $stage ($PackageName + '.zip')
    New-VerifiedZip $bundle $stagedZip
    $zipHash = File-Hash $stagedZip

    # Both new artifacts are complete and verified before an existing candidate moves.
    Ensure-Directory $dist
    Stop-ProjectClients
    Assert-Replacement $target $targetZip $targetSourceZip
    $moves = @(@{ from = $bundle; to = $target }, @{ from = $stagedZip; to = $targetZip })
    if ($stagedSourceZip) { $moves += @{ from = $stagedSourceZip; to = $targetSourceZip } }
    $backups = @()
    $installed = @()
    try {
        foreach ($destination in @($target, $targetZip)) {
            if (Test-Path -LiteralPath $destination) {
                $backup = $destination + '.backup-' + [Guid]::NewGuid().ToString('N')
                Move-Item -LiteralPath $destination -Destination $backup
                $backups += @{ from = $backup; to = $destination }
            }
        }
        foreach ($move in $moves) {
            Move-Item -LiteralPath $move.from -Destination $move.to
            $installed += $move
        }
    } catch {
        for ($i = $installed.Count - 1; $i -ge 0; $i--) {
            Move-Item -LiteralPath $installed[$i].to -Destination $installed[$i].from
        }
        for ($i = $backups.Count - 1; $i -ge 0; $i--) {
            Move-Item -LiteralPath $backups[$i].from -Destination $backups[$i].to
        }
        throw
    }
    Write-Host "Bundle: $target"
    Write-Host "ZIP: $targetZip"
    Write-Host "ZIP SHA-256: $zipHash"
    Write-Host "Status: $statusValue"
    Write-Host "Workspace build: $release"
    Write-Host "Packaging staging retained: $stage"
} finally {
    $env:PATH = $oldPath
    [Net.ServicePointManager]::SecurityProtocol = $oldTls
    Set-Location -LiteralPath $oldLocation.Path
}
