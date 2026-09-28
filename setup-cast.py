"""Fetch Google's pinned static SDK from its official distribution."""
from pathlib import Path
import urllib.request, zipfile, hashlib
root = Path(__file__).resolve().parent / 'Vendor'
root.mkdir(exist_ok=True)
archive = root / 'GoogleCastSDK-4.8.3.zip'
if not archive.exists():
    urllib.request.urlretrieve('https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.3_static.zip', archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == 'b53cc17671154f5ff4ba99165a8b9a6d677e8165715830b91cc1857634b33901', 'Unexpected Google Cast archive checksum'
with zipfile.ZipFile(archive) as sdk:
    sdk.extractall(root / 'GoogleCast483')
print('Google Cast SDK 4.8.3 SHA256:', hashlib.sha256(archive.read_bytes()).hexdigest())

import tarfile
proto = root / 'protobuf-3.21.12.tar.gz'
if not proto.exists():
    urllib.request.urlretrieve('https://github.com/protocolbuffers/protobuf/archive/refs/tags/v3.21.12.tar.gz', proto)
assert hashlib.sha256(proto.read_bytes()).hexdigest() == '930c2c3b5ecc6c9c12615cf5ad93f1cd6e12d0aba862b572e076259970ac3a53', 'Unexpected Protobuf archive checksum'
with tarfile.open(proto) as archive:
    members = [m for m in archive.getmembers() if m.name.startswith('protobuf-3.21.12/objectivec/') or m.name == 'protobuf-3.21.12/LICENSE']
    # Xcode Cloud's bundled Python can predate tarfile's extraction filters.
    for member in members:
        if not (member.isfile() or member.isdir()) or '..' in Path(member.name).parts:
            raise ValueError('Unexpected Protobuf archive entry')
    options = {'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}
    archive.extractall(root, members=members, **options)
