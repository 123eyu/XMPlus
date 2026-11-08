#!/usr/bin/env python3
"""Lightweight CI packaging checks; no downloads, compilers or Flutter build."""
import base64
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
import windows_native_build as native
from release_notes import release_notes


def rejected(action, message):
    try:
        action()
    except ValueError:
        return
    raise AssertionError(message)


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    root = Path(__file__).resolve().parent.parent
    tag = 'v' + re.search(r'^version:\s*(\d+\.\d+\.\d+)\+', (root / 'pubspec.yaml').read_text(), re.M)[1]
    changelog = (root / 'CHANGELOG.md').read_text(encoding='utf-8')
    notes = release_notes(changelog, tag)
    assert notes.startswith('## ' + tag[1:] + '\n')
    assert len(re.findall(r'^## ', notes, re.M)) == 1
    if tag != 'v1.0.0':
        assert '## 1.0.0' not in notes
    rejected(lambda: release_notes(changelog, 'v999.999.999'), 'Missing release section accepted')
    rejected(lambda: release_notes('## 2.0.0\n\n## 1.0.0\nold\n', 'v2.0.0'), 'Empty section accepted')
    rejected(lambda: release_notes('## 2.0.0\na\n## 2.0.0\nb\n', 'v2.0.0'), 'Duplicate section accepted')
    assert release_notes('## 2.0.0\r\nnew\r\n### Detail\r\nx\r\n## 1.0.0\r\nold\r\n', 'v2.0.0') == '## 2.0.0\r\nnew\r\n### Detail\r\nx\n'
    print(f'CHANGELOG: extracted only {tag}, {len(notes.splitlines())} lines; missing/empty/duplicate sections rejected.')

    powershell = shutil.which('pwsh') or shutil.which('powershell')
    if not powershell:
        raise RuntimeError('PowerShell is required for the real Windows ZIP boundary check')
    with tempfile.TemporaryDirectory(prefix='xmplus-ci-packaging-') as directory:
        base = Path(directory)
        for name in native.RUNTIME_MEMBERS:
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'packaging fixture, not an executable\n')
        native.save_json(base / 'sources/SOURCES.json', {
            'components': native.locked_sources(), 'patches': [],
            'recipes': [{'path': name, 'sha256': native.digest(root / 'tool' / name)} for name in native.RECIPES]})
        native.save_json(base / 'IMPORTS.json', {})
        # Deliberately present forbidden development inputs: the production packager must omit them.
        for name in ['sources/BUILD-OBJECTS.tar.gz', 'sources/source.tar.xz', 'work/prefix/lib/example.a', 'BUILD.log']:
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'not transferable')
        native.package_supply(base, True)
        with zipfile.ZipFile(base / 'windows-native-supply.zip') as archive:
            assert set(archive.namelist()) == set(native.RUNTIME_MEMBERS) | {'BUILD-RECEIPT.json'}
            receipt = json.loads(archive.read('BUILD-RECEIPT.json'))
            assert receipt['sourceComplete'] is False and receipt['supplyMode'] == 'runtime-only'
            print(f'Native transfer: exactly {len(archive.namelist())} allowed files; no source archives, objects, logs or work tree.')
        provenance = base / 'sources/SOURCES.json'
        original = provenance.read_bytes()
        for field in ['components', 'recipes']:
            changed = json.loads(original)
            changed[field][0]['sha256'] = '0' * 64
            native.save_json(provenance, changed)
            changed_receipt = json.loads((base / 'BUILD-RECEIPT.json').read_text())
            next(item for item in changed_receipt['files'] if item['path'] == 'sources/SOURCES.json')['sha256'] = native.digest(provenance)
            native.save_json(base / 'BUILD-RECEIPT.json', changed_receipt)
            rejected(lambda: native.verify_supply(base), f'Changed {field} accepted')
            provenance.write_bytes(original)
        native.save_json(base / 'BUILD-RECEIPT.json', receipt)
        print('Provenance: altered source lock and recipe rejected even with updated manifest hashes.')

        bundle = base / 'XMPlus-fixture-windows-x64'
        shutil.copytree(base / 'runtime', bundle)
        (bundle / 'XMPlus.exe').write_bytes(b'fixture application')
        (bundle / 'LICENSE').write_text('fixture license')
        (bundle / 'tools/ffmpeg/version-identity.json').write_text('{"fixture":true}')
        script = f"""
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptPath = {ps_quote(root / 'tool/build_windows.ps1')}
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) {{ throw ($parseErrors | Out-String) }}
foreach ($function in $ast.FindAll({{ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }}, $false)) {{
    . ([scriptblock]::Create($function.Extent.Text))
}}
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$ProjectRoot = {ps_quote(root)}
$PSScriptRoot = Join-Path $ProjectRoot 'tool'
$NativeSupply = {ps_quote(base)}
$RuntimeOnly = $true
$text = [IO.File]::ReadAllText($scriptPath)
$start = $text.IndexOf('$supplyReceipt = Read-Json')
$end = $text.IndexOf('$nativeFFmpegHash =', $start)
$admission = [scriptblock]::Create('$PSScriptRoot = Join-Path $ProjectRoot ''tool''' + "`n" + $text.Substring($start, $end - $start))
. $admission
$binary = Join-Path $NativeSupply 'runtime/tools/ffmpeg/ffmpeg.exe'
$original = [IO.File]::ReadAllBytes($binary)
try {{
    [IO.File]::WriteAllText($binary, 'tampered')
    $didReject = $false
    try {{ . $admission }} catch {{ $didReject = $true }}
    if (-not $didReject) {{ throw 'PowerShell accepted tampered native runtime' }}
}} finally {{ [IO.File]::WriteAllBytes($binary, $original) }}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-VerifiedZip {ps_quote(bundle)} {ps_quote(base / 'standard.zip')}
New-VerifiedZip {ps_quote(bundle)} {ps_quote(base / 'no-ffmpeg.zip')} -ExcludeFFmpeg
[IO.File]::WriteAllText((Join-Path {ps_quote(bundle)} 'injected.obj'), 'forbidden')
$didReject = $false
try {{ New-VerifiedZip {ps_quote(bundle)} {ps_quote(base / 'forbidden.zip')} }} catch {{ $didReject = $true }}
if (-not $didReject) {{ throw 'Development object accepted in runtime ZIP' }}
Write-Output 'PowerShell: full script parses; real supply admission accepts fixture and rejects tampering; both ZIP functions verify file hashes; development object rejected.'
"""
        encoded = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
        subprocess.run([powershell, '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], check=True)
        with zipfile.ZipFile(base / 'standard.zip') as standard, zipfile.ZipFile(base / 'no-ffmpeg.zip') as slim:
            full_names, slim_names = set(standard.namelist()), set(slim.namelist())
            removed = {bundle.name + '/tools/ffmpeg/' + name for name in ['ffmpeg.exe', 'ffprobe.exe', 'version-identity.json']}
            assert full_names - slim_names == removed and not slim_names - full_names
            assert bundle.name + '/libmpv-2.dll' in slim_names
            for name in slim_names:
                assert standard.read(name) == slim.read(name)
            print('Windows ZIP variants: exact difference is tools/ffmpeg/* (3 fixture files); libmpv retained byte-identically; shared payload unchanged.')


if __name__ == '__main__':
    main()
