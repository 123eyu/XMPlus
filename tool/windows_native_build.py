#!/usr/bin/env python3
"""Build real Windows FFmpeg/FFprobe/libmpv from hash-locked corresponding sources.
Linux x64 prerequisites: Python >=3.11, make, cmake, ninja, pkg-config, meson >=1.3,
Jinja2. No target libraries are taken from the host. Invoke through windows-native-build.sh.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')

def extract(archive, destination):
    destination.mkdir(parents=True)
    with tarfile.open(archive) as package:
        members = package.getmembers()
        roots = {Path(m.name).parts[0] for m in members if Path(m.name).parts}
        if len(roots) != 1:
            raise ValueError(f'Expected one archive root: {archive}')
        for member in members:
            parts = Path(member.name).parts[1:]
            if not parts or any(p.lower().startswith('readme') for p in parts):
                continue
            target = destination.joinpath(*parts)
            if '..' in parts or member.name.startswith('/'):
                raise ValueError(f'Unsafe archive member: {member.name}')
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as source, target.open('wb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)
            elif member.issym():
                # Toolchain wrappers are relative symlinks. Never permit an escaping link.
                resolved = (target.parent / member.linkname).resolve()
                if not resolved.is_relative_to(destination.resolve()):
                    raise ValueError(f'Escaping archive symlink: {member.name}')
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)

def inventory(base):
    return [{'path': str(p.relative_to(base)).replace('\\', '/'),
             'sha256': digest(p), 'bytes': p.stat().st_size}
            for p in sorted(base.rglob('*')) if p.is_file()]

def verify_supply(base):
    receipt = json.loads((base / 'BUILD-RECEIPT.json').read_text(encoding='utf-8'))
    if receipt['schemaVersion'] != 1 or receipt['target'] != 'windows-x64':
        raise ValueError('Unsupported native supply')
    for item in receipt['files']:
        path = (base / item['path']).resolve()
        if not path.is_relative_to(base.resolve()) or digest(path) != item['sha256']:
            raise ValueError(f'Native supply digest mismatch: {item["path"]}')
    for name in ['runtime/libmpv-2.dll', 'runtime/tools/ffmpeg/ffmpeg.exe',
                 'runtime/tools/ffmpeg/ffprobe.exe', 'sources/SOURCES.json',
                 'sources/BUILD-OBJECTS.tar.gz', 'licenses/THIRD-PARTY-NOTICES.txt']:
        if name not in {f['path'] for f in receipt['files']}:
            raise ValueError(f'Missing native supply member: {name}')
    print('Native supply hashes and required members verified.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--verify-supply', action='store_true')
    args = parser.parse_args()
    out = args.output.resolve()
    if args.verify_supply:
        verify_supply(out)
        return
    if out.exists():
        raise FileExistsError(f'Use a fresh output directory: {out}')
    for command in ['make', 'cmake', 'ninja', 'pkg-config', 'meson']:
        if not shutil.which(command):
            raise RuntimeError(f'Missing host build prerequisite: {command}')
    out.mkdir(parents=True)
    work = out / 'work'
    prefix = work / 'prefix'
    source_dir = out / 'sources'
    license_dir = out / 'licenses'
    runtime = out / 'runtime'
    for directory in [work, prefix, source_dir, license_dir, runtime / 'tools/ffmpeg']:
        directory.mkdir(parents=True, exist_ok=True)
    locks = [ROOT / 'tool/media_sources.json', ROOT / 'tool/windows_native_sources.json']
    entries = [item for lock in locks for item in json.loads(lock.read_text(encoding='utf-8'))['components']]
    sources = {}
    for item in entries:
        cached = ROOT / item['file']
        if not cached.exists():
            cached.parent.mkdir(parents=True, exist_ok=True)
            temporary = cached.with_suffix(cached.suffix + '.download')
            with urllib.request.urlopen(item['url'], timeout=180) as response, temporary.open('wb') as target:
                shutil.copyfileobj(response, target)
            if digest(temporary) != item['sha256']:
                temporary.unlink()
                raise ValueError(f'Download SHA-256 mismatch: {item["name"]}')
            temporary.rename(cached)
        if digest(cached) != item['sha256']:
            raise ValueError(f'Source SHA-256 mismatch: {cached}')
        archived = source_dir / cached.name
        shutil.copyfile(cached, archived)
        destination = work / item['name']
        # Compiler source archives are supplied intact, but are not needed to use the pinned toolchain.
        if item['name'] not in ['llvm-project', 'mingw-w64', 'llvm-mingw']:
            extract(cached, destination)
        sources[item['name']] = destination
    save_json(source_dir / 'SOURCES.json', {'schemaVersion': 1, 'components': entries,
        'patches': [], 'hostPrerequisites': 'Python3.11+, make, cmake, ninja, pkg-config, meson>=1.3, Jinja2',
        'note': 'Complete locked archives for these newly generated binaries, not for historical publisher binaries.'})
    for name in ['windows-native-build.sh', 'windows_native_build.py', 'windows_native_sources.json', 'media_sources.json']:
        shutil.copyfile(ROOT / 'tool' / name, source_dir / name)
    toolchain = sources['llvm-mingw-toolchain']
    env = os.environ.copy()
    env['PATH'] = str(toolchain / 'bin') + os.pathsep + env['PATH']
    env['PKG_CONFIG_LIBDIR'] = str(prefix / 'lib/pkgconfig')
    env['PKG_CONFIG_PATH'] = ''
    env.pop('XMLY_TEST_CREDENTIALS_JSON', None)
    triple = 'x86_64-w64-mingw32'
    cc, cxx = triple + '-clang', triple + '-clang++'
    env.update(CC=cc, CXX=cxx, AR=triple + '-ar', RANLIB=triple + '-ranlib',
               STRIP=triple + '-strip', RC=triple + '-windres')
    log = (out / 'BUILD.log').open('w', encoding='utf-8')
    def run(command, cwd=work):
        print('+', ' '.join(map(str, command)), flush=True)
        log.write('+ ' + ' '.join(map(str, command)) + '\n'); log.flush()
        subprocess.run(list(map(str, command)), cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    cross = work / 'windows.cross'
    cross.write_text(f"""[binaries]
c = '{cc}'
cpp = '{cxx}'
ar = '{triple}-ar'
strip = '{triple}-strip'
windres = '{triple}-windres'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_link_args = ['-static']
cpp_link_args = ['-static', '-static-libstdc++']
""", encoding='utf-8')
    jobs = str(min(os.cpu_count() or 2, 8))
    def meson(name, *options, shared=False):
        build = work / ('build-' + name)
        run(['meson', 'setup', build, sources[name], '--cross-file', cross,
             '--prefix', prefix, '--libdir=lib', '--buildtype=release', '--wrap-mode=nofallback',
             '--default-library=' + ('shared' if shared else 'static'), '--auto-features=disabled', *options])
        run(['ninja', '-C', build, '-j', jobs])
        run(['meson', 'install', '-C', build, '--no-rebuild'])
    # PNG covers need zlib; do not depend on host/system target libraries.
    zbuild = work / 'build-zlib'
    run(['cmake', '-S', sources['zlib'], '-B', zbuild, '-G', 'Ninja', '-DCMAKE_SYSTEM_NAME=Windows',
         '-DCMAKE_C_COMPILER=' + cc, '-DCMAKE_RC_COMPILER=' + triple + '-windres',
         '-DCMAKE_INSTALL_PREFIX=' + str(prefix), '-DCMAKE_BUILD_TYPE=Release', '-DZLIB_BUILD_EXAMPLES=OFF'])
    run(['cmake', '--build', zbuild, '--target', 'zlibstatic', '-j', jobs])
    (prefix / 'include').mkdir(exist_ok=True)
    (prefix / 'lib/pkgconfig').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(zbuild / 'libzlibstatic.a', prefix / 'lib/libz.a')
    for header in ['zlib.h', 'zconf.h']:
        shutil.copyfile((sources['zlib'] if header == 'zlib.h' else zbuild) / header, prefix / 'include' / header)
    (prefix / 'lib/pkgconfig/zlib.pc').write_text(f'prefix={prefix}\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include\nName: zlib\nDescription: zlib\nVersion: 1.3.1\nLibs: -L${{libdir}} -lz\nCflags: -I${{includedir}}\n')
    run([sources['lame'] / 'configure', '--host=' + triple, '--prefix=' + str(prefix),
         '--disable-shared', '--enable-static', '--disable-frontend', '--disable-decoder'], sources['lame'])
    run(['make', '-j', jobs], sources['lame']); run(['make', 'install'], sources['lame'])
    ffbuild = work / 'build-ffmpeg'; ffbuild.mkdir()
    run([sources['ffmpeg'] / 'configure', '--prefix=' + str(prefix), '--target-os=mingw32',
         '--arch=x86_64', '--enable-cross-compile', '--cc=' + cc, '--cxx=' + cxx,
         '--ar=' + triple + '-ar', '--ranlib=' + triple + '-ranlib', '--strip=' + triple + '-strip',
         '--pkg-config=pkg-config', '--pkg-config-flags=--static', '--disable-autodetect',
         '--disable-shared', '--enable-static', '--disable-gpl', '--disable-nonfree',
         '--disable-debug', '--disable-doc', '--disable-ffplay', '--disable-x86asm',
         '--enable-libmp3lame', '--enable-zlib', '--enable-schannel',
         '--extra-cflags=-I' + str(prefix / 'include'), '--extra-ldflags=-L' + str(prefix / 'lib') + ' -static'], ffbuild)
    run(['make', '-j', jobs], ffbuild); run(['make', 'install'], ffbuild)
    meson('freetype', '-Dzlib=disabled')
    meson('fribidi', '-Ddocs=false', '-Dtests=false')
    meson('harfbuzz', '-Dtests=disabled', '-Dutilities=disabled', '-Ddocs=disabled')
    meson('libass', '-Drequire-system-font-provider=false')
    # libc++18 lacks floating-point from_chars; use one fully pinned header-only dependency.
    shutil.copytree(sources['fast-float'], sources['libplacebo-current'] / '3rdparty/fast_float', dirs_exist_ok=True)
    meson('libplacebo-current', '-Ddemos=false', '-Dtests=false', '-Dbench=false')
    meson('mpv-current', '-Dgpl=false', '-Dlibmpv=true', '-Dcplayer=false', '-Dlua=disabled',
          '-Dgl=disabled', '-Dwasapi=enabled', '-Dwin32-threads=enabled', '-Dbuild-date=false',
          '-Dc_link_args=' + json.dumps(['-static', '-lc++', '-lc++abi', '-lunwind', '-Wl,-Map,' + str(work / 'libmpv.map')]), shared=True)
    shutil.copyfile(prefix / 'bin/libmpv-2.dll', runtime / 'libmpv-2.dll')
    for name in ['ffmpeg.exe', 'ffprobe.exe']:
        shutil.copyfile(prefix / 'bin' / name, runtime / 'tools/ffmpeg' / name)
    # Runtime license notices retain per-file attribution, including bundled vendor code.
    with (license_dir / 'THIRD-PARTY-NOTICES.txt').open('w', encoding='utf-8') as notices:
        for item in entries:
            notices.write('\n\n=== ' + item['name'] + ' | ' + item['url'] + ' ===\n')
            with tarfile.open(source_dir / Path(item['file']).name) as package:
                for member in package.getmembers():
                    name = Path(member.name).name.lower()
                    if member.isfile() and (name.startswith(('copying', 'copyright', 'license')) or name in ['ftl.txt', 'zlib.h']):
                        notices.write('\n--- ' + member.name + ' ---\n')
                        notices.write(package.extractfile(member).read().decode('utf-8', errors='replace'))
    (license_dir / 'WINDOWS-PREREQUISITES.txt').write_text('Windows 10 x64 or later. Microsoft Visual C++ v14 x64 Redistributable is required by the Flutter application.\nInstall only from Microsoft: https://aka.ms/vc14/vc_redist.x64.exe\nDocumentation: https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist\nThe package does not redistribute MSVC CRT DLLs and does not grant rights under any Microsoft license.\n', encoding='utf-8')
    # Preserve generated configure files, object files, static libraries and link map for relinking.
    with tarfile.open(source_dir / 'BUILD-OBJECTS.tar.gz', 'w:gz') as archive:
        archive.add(work, arcname='work', filter=lambda member: None if any(p.lower().startswith('readme') for p in Path(member.name).parts) else member)
    imports = {}
    for binary in runtime.rglob('*'):
        if binary.suffix.lower() in ['.exe', '.dll']:
            result = subprocess.check_output([str(toolchain / 'bin/llvm-readobj'), '--coff-imports', str(binary)], env=env, text=True)
            imports[str(binary.relative_to(out))] = result
            allowed = {'kernel32.dll', 'user32.dll', 'advapi32.dll', 'ole32.dll', 'oleaut32.dll', 'uuid.dll',
                       'ws2_32.dll', 'secur32.dll', 'crypt32.dll', 'bcrypt.dll', 'shell32.dll', 'shlwapi.dll',
                       'gdi32.dll', 'winmm.dll', 'version.dll', 'avrt.dll', 'dwmapi.dll', 'imm32.dll',
                       'uxtheme.dll', 'ucrtbase.dll', 'ntdll.dll', 'winhttp.dll', 'normaliz.dll', 'propsys.dll', 'dbghelp.dll'}
            for line in result.splitlines():
                if line.strip().startswith('Name:'):
                    dependency = line.split(':', 1)[1].strip().lower()
                    if dependency not in allowed and not dependency.startswith('api-ms-win-'):
                        raise ValueError(f'Unbundled/non-system DLL dependency {dependency}: {binary}')
    save_json(out / 'IMPORTS.json', imports)
    log.close()
    save_json(out / 'BUILD-RECEIPT.json', {'schemaVersion': 1, 'target': 'windows-x64',
        'producer': 'tool/windows_native_build.py', 'sourceComplete': True, 'patches': [],
        'toolchainSha256': next(x['sha256'] for x in entries if x['name'] == 'llvm-mingw-toolchain'),
        'functionalValidation': 'Not run by cross-build; Windows media_kit playback and FFmpeg format/remux/cover/hash checks required.',
        'files': [x for x in inventory(out) if not x['path'].startswith('work/')]})
    verify_supply(out)
    with zipfile.ZipFile(out / 'windows-native-supply.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for item in json.loads((out / 'BUILD-RECEIPT.json').read_text())['files'] + [{'path': 'BUILD-RECEIPT.json'}]:
            archive.write(out / item['path'], item['path'])
    print(out / 'windows-native-supply.zip')

if __name__ == '__main__':
    main()
