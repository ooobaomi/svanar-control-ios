"""Package an existing compiled arm64 iOS .app, never a source-only placeholder."""
from pathlib import Path
import os
import plistlib
import stat
import sys
import zipfile


def package(app, output):
    app, output = Path(app), Path(output)
    with (app / 'Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    binary = app / info['CFBundleExecutable']
    if info.get('CFBundlePackageType') != 'APPL' or not binary.is_file():
        raise ValueError('A compiled .app is required')
    if binary.read_bytes()[:4] not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                                       b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        raise ValueError('Executable is not Mach-O; refusing to create a fake IPA')
    platforms = info.get('CFBundleSupportedPlatforms', [])
    if platforms != ['iPhoneOS']:
        raise ValueError(f'Requires physical iPhoneOS build, got {platforms}')
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob('*')):
            if path.is_dir():
                continue
            name = 'Payload/' + app.name + '/' + path.relative_to(app).as_posix()
            if path.is_symlink():
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, os.readlink(path))
            else:
                entry = zipfile.ZipInfo.from_file(path, name)
                entry.create_system = 3
                mode = 0o755 if os.access(path, os.X_OK) or path == binary else 0o644
                entry.external_attr = (stat.S_IFREG | mode) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, path.read_bytes())
    print(output)


if __name__ == '__main__':
    package(*sys.argv[1:])
