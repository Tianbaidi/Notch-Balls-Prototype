#!/usr/bin/env python3
"""Local Keychain signing + resumable GitHub publication. No private-key export."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPO = 'Tianbaidi/Notch-Balls-Prototype'
FEED = f'https://raw.githubusercontent.com/{REPO}/main/appcast.xml'
APP = 'Notch Balls Prototype.app'
ACCOUNT = 'Notch-Balls-Prototype'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)

def run(*args, capture=False, env=None):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                            text=True, stdout=subprocess.PIPE if capture else None, env=env)
    return result.stdout.strip() if capture else None

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def git(*args):
    return run('git', *args, capture=True)

def gh_json(*args):
    return json.loads(run('gh', *args, capture=True))

def public_download(url, destination):
    # curl does not inherit gh credentials; -q disables any personal curlrc.
    run('curl', '-q', '--fail', '--location', '--retry', '3', '--max-time', '180',
        '--proto', '=https', '--proto-redir', '=https', '--silent', '--show-error',
        '--output', destination, url)

def info(path):
    with Path(path).open('rb') as f:
        return plistlib.load(f)

def verifier():
    target = ROOT / 'build/verify_signature'
    source = ROOT / 'scripts/verify_signature.swift'
    if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
        target.parent.mkdir(exist_ok=True)
        run('xcrun', 'swiftc', '-module-cache-path', '/private/tmp/notch-balls-swift-cache', str(source), '-o', str(target))
    return target

def verify_archive(path, manifest):
    require(digest(path) == manifest['sha256'], 'Archive SHA-256 mismatch')
    require(Path(path).stat().st_size == manifest['length'], 'Archive length mismatch')
    run(verifier(), path, manifest['signature'], manifest['public_key'])

def check_archive_app(archive, manifest):
    with tempfile.TemporaryDirectory(prefix='notch-verify-') as temp:
        run('ditto', '-x', '-k', archive, temp)
        contents = Path(temp) / APP / 'Contents'
        bundle = info(contents / 'Info.plist')
        for key, value in {'CFBundleVersion': manifest['build'],
                           'CFBundleShortVersionString': manifest['version'],
                           'CFBundleIdentifier': 'local.codex.NotchBallsPrototype',
                           'SUPublicEDKey': manifest['public_key'], 'SUFeedURL': FEED,
                           'NBReleaseMode': manifest['mode']}.items():
            require(bundle.get(key) == value, f'Bundle {key} mismatch')
        run('codesign', '--verify', '--deep', '--strict', contents.parent)
        if manifest['mode'] == 'stable':
            run('xcrun', 'stapler', 'validate', contents.parent)
            run('spctl', '--assess', '--type', 'execute', '--verbose=2', contents.parent)

def build_number(item):
    value = item.findtext(f'{{{NS}}}version')
    if value is None:
        enclosure = item.find('enclosure')
        value = enclosure.get(f'{{{NS}}}version') if enclosure is not None else None
    require(value is not None and value.isdigit(), 'Feed contains non-integer build number')
    return int(value)

def make_feed(original, m):
    root = ET.fromstring(original)
    channel = root.find('channel')
    require(root.tag == 'rss' and channel is not None, 'Invalid appcast')
    for old in channel.findall('item'):
        require(build_number(old) < int(m['build']), 'Build must exceed every existing appcast item')
    item = ET.Element('item')
    label = '未公证测试版 / Unnotarized test' if m['mode'] == 'testing' else 'macOS'
    ET.SubElement(item, 'title').text = f"Notch Balls Prototype {m['version']} — {label}"
    ET.SubElement(item, 'link').text = f"https://github.com/{REPO}/releases/tag/{m['tag']}"
    for name, value in [('version', m['build']), ('shortVersionString', m['version']),
                        ('minimumSystemVersion', '14.0.0'), ('hardwareRequirements', 'arm64')]:
        ET.SubElement(item, f'{{{NS}}}{name}').text = value
    if m['mode'] == 'testing':
        # 0.35 has no beta-channel delegate. This must be in its existing default feed.
        # Prevent silent installation of this test into all earlier builds.
        ET.SubElement(item, f'{{{NS}}}minimumAutoupdateVersion').text = m['build']
    ET.SubElement(item, 'pubDate').text = m['date']
    ET.SubElement(item, 'description', {f'{{{NS}}}format': 'plain-text'}).text = m['notes']
    ET.SubElement(item, 'enclosure', {'url': m['url'], 'length': str(m['length']),
                    'type': 'application/octet-stream', f'{{{NS}}}edSignature': m['signature']})
    channel.insert(0, item)
    ET.indent(root, space='  ')
    return ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n'

def prepare(args):
    require(re.fullmatch(r'\d+(?:\.\d+){0,2}', args.version), 'Version must be numeric')
    require(re.fullmatch(r'[1-9]\d*', args.build), 'Build must be a positive integer')
    require(not git('status', '--porcelain'), 'Commit reviewed source first; working tree must be clean')
    require(int(args.build) > int(info(ROOT / 'Info.plist')['CFBundleVersion']),
            'Release build must exceed baseline Info.plist build')
    config = info(ROOT / 'UpdateConfig.plist')
    require(config['SUFeedURL'] == FEED, 'Unexpected feed URL')
    require(run('vendor/bin/generate_keys', '--account', ACCOUNT, '-p', capture=True)
            == config['SUPublicEDKey'], 'Keychain public key differs from UpdateConfig.plist')
    tag = f'v{args.version}'
    output = ROOT / 'dist' / tag
    require(not output.exists(), f'{output} already exists; resume using publish, or choose a new version')
    identity = os.environ.get('CODE_SIGN_IDENTITY', '-')
    if args.mode == 'stable':
        require(identity.startswith('Developer ID Application: '), 'Stable requires Developer ID Application signing')
        require(os.environ.get('NOTARYTOOL_PROFILE'), 'Stable requires a local NOTARYTOOL_PROFILE')
    else:
        require(identity == '-', 'Testing mode uses ad-hoc signing; use stable for Developer ID distribution')
    notes = args.notes.read_text().strip()
    require(notes, 'Release notes required')
    if args.mode == 'testing':
        notes = ('未公证测试版（Unnotarized test build）。仅用于现有安装的更新验证，'
                 '不是正式公开版；未通过 Developer ID 签名或 Apple 公证。\n\n' + notes)
    env = dict(os.environ, APP_VERSION=args.version, APP_BUILD=args.build,
               RELEASE_MODE=args.mode, ENABLE_UPDATES='1', CODE_SIGN_IDENTITY=identity, BUILD_PREVIEW='1')
    # Environment overrides may not silently redirect a release to a different key/feed.
    env.pop('SU_FEED_URL', None)
    env.pop('SU_PUBLIC_ED_KEY', None)
    run('./build.sh', env=env)
    with tempfile.TemporaryDirectory(prefix='notch-package-') as temp:
        stage = Path(temp)
        app = stage / APP
        run('ditto', ROOT / 'build' / 'Notch Balls Prototype Preview.app', app)
        if args.mode == 'stable':
            submission = stage / 'notarize.zip'
            run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, submission)
            run('xcrun', 'notarytool', 'submit', submission, '--keychain-profile',
                os.environ['NOTARYTOOL_PROFILE'], '--wait')
            run('xcrun', 'stapler', 'staple', app)
            run('xcrun', 'stapler', 'validate', app)
            run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
        name = f'Notch-Balls-Prototype-{args.version}-macOS-arm64.zip'
        archive = stage / name
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
        signature = run('vendor/bin/sign_update', '--account', ACCOUNT, '-p', archive, capture=True)
        from email.utils import format_datetime
        m = dict(version=args.version, build=args.build, mode=args.mode, tag=tag,
                 asset=name, source_commit=git('rev-parse', 'HEAD'), public_key=config['SUPublicEDKey'],
                 url=f'https://github.com/{REPO}/releases/download/{tag}/{name}',
                 length=archive.stat().st_size, sha256=digest(archive), signature=signature,
                 notes=notes, date=format_datetime(dt.datetime.now(dt.timezone.utc)),
                 base_feed_sha256=digest(ROOT / 'appcast.xml'))
        verify_archive(archive, m)
        check_archive_app(archive, m)
        candidate = make_feed((ROOT / 'appcast.xml').read_bytes(), m)
        output.mkdir(parents=True)
        run('ditto', archive, output / name)
        (output / 'manifest.json').write_text(json.dumps(m, indent=2, ensure_ascii=False) + '\n')
        (output / 'appcast.xml').write_bytes(candidate)
        (output / 'release-notes.md').write_text(notes + '\n')
        (output / 'SHA256SUMS').write_text(f"{m['sha256']}  {name}\n")
    print(f'Prepared {output.relative_to(ROOT)}; no remote changes. Run publish with manifest.json.')

def release_state(tag):
    # Listing avoids treating transient network/authorization failures as "not found".
    pages = gh_json('api', f'repos/{REPO}/releases?per_page=100', '--paginate', '--slurp')
    return next((r for page in pages for r in page if r['tag_name'] == tag), None)

def remote_feed():
    data = gh_json('api', f'repos/{REPO}/contents/appcast.xml?ref=main')
    return data, base64.b64decode(data['content'])

def verify_asset_metadata(asset, path):
    require(asset.get('state') == 'uploaded', 'Remote asset upload incomplete')
    require(asset.get('size') == path.stat().st_size, 'Remote asset size mismatch')
    require(asset.get('digest') == 'sha256:' + digest(path), 'Remote asset SHA-256 missing or mismatched')


def publish(args):
    m = json.loads(args.manifest.read_text())
    directory = args.manifest.resolve().parent
    archive = directory / m['asset']
    require(m['mode'] in ('testing', 'stable'), 'Invalid release mode')
    require(m['tag'] == f"v{m['version']}", 'Tag/version mismatch')
    require(m['asset'] == f"Notch-Balls-Prototype-{m['version']}-macOS-arm64.zip", 'Unexpected asset name')
    require(m['url'] == f"https://github.com/{REPO}/releases/download/{m['tag']}/{m['asset']}", 'Unexpected URL')
    require(m['public_key'] == info(ROOT / 'UpdateConfig.plist')['SUPublicEDKey'], 'Public key mismatch')
    if m['mode'] == 'testing':
        require('未公证' in m['notes'], 'Testing release must disclose notarization status')
    verify_archive(archive, m)
    check_archive_app(archive, m)
    # Source must already be reviewed and pushed, and reachable from main.
    run('git', 'fetch', 'origin', 'main')
    run('git', 'merge-base', '--is-ancestor', m['source_commit'], 'origin/main')
    content, original = remote_feed()
    candidate = (directory / 'appcast.xml').read_bytes()
    already_live = original == candidate
    if not already_live:
        require(hashlib.sha256(original).hexdigest() == m['base_feed_sha256'],
                'Remote feed changed; stop and prepare against the current feed')
        require(candidate == make_feed(original, m), 'Candidate appcast differs from signed manifest metadata')
    refs = git('ls-remote', 'origin', f"refs/tags/{m['tag']}", f"refs/tags/{m['tag']}^{{}}")
    if refs:
        tag_commit = refs.splitlines()[-1].split()[0]
        require(tag_commit == m['source_commit'], 'Existing remote tag differs from prepared source')
    release = release_state(m['tag'])
    if release is None:
        label = '未公证测试版' if m['mode'] == 'testing' else 'macOS'
        run('gh', 'release', 'create', m['tag'], '-R', REPO, '--draft', '--target', m['source_commit'],
            '--title', f"{m['version']} {label}", '--notes-file', directory / 'release-notes.md',
            '--prerelease' if m['mode'] == 'testing' else '--prerelease=false', '--latest=false')
        release = release_state(m['tag'])
    require(release['prerelease'] == (m['mode'] == 'testing'), 'Existing release mode differs')
    require(release['body'].strip() == m['notes'].strip(), 'Existing release notes differ')
    if not release['draft']:
        tag_object = gh_json('api', f"repos/{REPO}/commits/{m['tag']}")
        require(tag_object['sha'] == m['source_commit'], 'Existing tag points at another source commit')
    else:
        require(release['target_commitish'] == m['source_commit'], 'Draft target differs')
    # Upload missing assets only; never clobber artifacts already downloaded by users.
    for name in (m['asset'], 'SHA256SUMS'):
        asset = next((a for a in release['assets'] if a['name'] == name), None)
        if asset is None:
            require(release['draft'], 'Published release is missing an expected asset; refuse to modify')
            run('gh', 'release', 'upload', m['tag'], str(directory / name), '-R', REPO)
        elif args.metadata_only:
            verify_asset_metadata(asset, directory / name)
        else:
            with tempfile.TemporaryDirectory(prefix='notch-remote-') as temp:
                run('gh', 'release', 'download', m['tag'], '-R', REPO, '--pattern', name, '--dir', temp)
                require(digest(Path(temp) / name) == digest(directory / name), 'Existing remote asset differs')
    if release['draft']:
        run('gh', 'release', 'edit', m['tag'], '-R', REPO, '--draft=false',
            '--prerelease' if m['mode'] == 'testing' else '--prerelease=false', '--latest=false')
    # Verify availability before advertising. Optional metadata mode never downloads the package.
    if args.metadata_only:
        published = release_state(m['tag'])
        require(published is not None and not published['draft'], 'Release is not public')
        for name in (m['asset'], 'SHA256SUMS'):
            asset = next((a for a in published['assets'] if a['name'] == name), None)
            require(asset is not None, 'Published asset missing')
            verify_asset_metadata(asset, directory / name)
        run('curl', '-q', '--fail', '--head', '--location', '--retry', '3', '--max-time', '60',
            '--proto', '=https', '--proto-redir', '=https', '--silent', '--show-error',
            '--output', os.devnull, m['url'])
    else:
        with tempfile.TemporaryDirectory(prefix='notch-public-') as temp:
            downloaded = Path(temp) / m['asset']
            public_download(m['url'], downloaded)
            verify_archive(downloaded, m)
    if not already_live:
        payload = dict(message=f"Publish {m['version']} {m['mode']} Sparkle update", branch='main',
                       sha=content['sha'], content=base64.b64encode(candidate).decode())
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as body:
            json.dump(payload, body)
            body.flush()
            # GitHub Contents API uses the old blob SHA as a compare-and-swap guard.
            result = gh_json('api', '--method', 'PUT', f'repos/{REPO}/contents/appcast.xml', '--input', body.name)
            print('Feed commit:', result['commit']['sha'])
    print(f"Published https://github.com/{REPO}/releases/tag/{m['tag']}")
    print('GitHub raw CDN may cache the old feed for several minutes; run verify-live next.')

def verify_live(args):
    with tempfile.TemporaryDirectory(prefix='notch-live-') as temp:
        feed = Path(temp) / 'appcast.xml'
        public_download(FEED, feed)
        channel = ET.fromstring(feed.read_bytes()).find('channel')
        require(channel is not None and channel.findall('item'), 'Live feed has no update items (CDN may be stale)')
        item = max(channel.findall('item'), key=build_number)
        enclosure = item.find('enclosure')
        require(enclosure is not None, 'Missing enclosure')
        version = item.findtext(f'{{{NS}}}shortVersionString')
        require(args.build is None or build_number(item) == int(args.build), 'Live build differs from requested build')
        archive = Path(temp) / 'update.zip'
        url = enclosure.get('url')
        require(url.startswith(f'https://github.com/{REPO}/releases/download/'), 'Unexpected download host/path')
        public_download(url, archive)
        require(archive.stat().st_size == int(enclosure.get('length')), 'Live enclosure length mismatch')
        run(verifier(), archive, enclosure.get(f'{{{NS}}}edSignature'), info(ROOT / 'UpdateConfig.plist')['SUPublicEDKey'])
        print(f'Anonymous live feed + archive verified: {version} ({build_number(item)}), SHA256 {digest(archive)}')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('prepare', help='Build, sign and validate locally; never publishes')
    p.add_argument('--version', required=True)
    p.add_argument('--build', required=True)
    p.add_argument('--mode', choices=('testing', 'stable'), required=True)
    p.add_argument('--notes', type=Path, required=True)
    p.set_defaults(func=prepare)
    p = sub.add_parser('publish', help='Resume upload/publish, then update main appcast via compare-and-swap')
    p.add_argument('manifest', type=Path)
    p.add_argument('--metadata-only', action='store_true',
                   help='Verify GitHub SHA-256/size and anonymous HEAD without downloading assets')
    p.set_defaults(func=publish)
    p = sub.add_parser('verify-live', help='Anonymous verification of the actual installed feed URL')
    p.add_argument('--build')
    p.set_defaults(func=verify_live)
    args = parser.parse_args()
    args.func(args)

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f'Release stopped: {error}')
