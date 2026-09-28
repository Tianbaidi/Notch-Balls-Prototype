import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'scripts/release.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

class FeedTests(unittest.TestCase):
    def setUp(self):
        self.feed = b'<rss version="2.0"><channel><title>Test</title></channel></rss>'
        self.m = dict(version='0.36', build='36', mode='testing', tag='v0.36',
                      date='Mon, 28 Sep 2026 12:00:00 +0000', notes='Test & <safe>',
                      url='https://example.com/app.zip', length=123, signature='public-signature')

    def test_test_release_is_visible_to_035_but_not_silent(self):
        feed = r.make_feed(self.feed, self.m)
        item = ET.fromstring(feed).find('channel/item')
        self.assertIsNone(item.find(f'{{{r.NS}}}channel'))
        self.assertEqual(item.findtext(f'{{{r.NS}}}minimumAutoupdateVersion'), '36')
        self.assertEqual(item.findtext('description'), self.m['notes'])
        self.assertIn('未公证', item.findtext('title'))
        self.assertEqual(item.findtext(f'{{{r.NS}}}hardwareRequirements'), 'arm64')

    def test_duplicate_and_decreasing_build_are_rejected(self):
        feed = r.make_feed(self.feed, self.m)
        for build in ('36', '35'):
            with self.assertRaisesRegex(RuntimeError, 'exceed'):
                r.make_feed(feed, dict(self.m, build=build))

    def test_preserves_history(self):
        feed = r.make_feed(self.feed, self.m)
        newer = r.make_feed(feed, dict(self.m, build='37', version='0.37'))
        self.assertEqual([r.build_number(i) for i in ET.fromstring(newer).findall('channel/item')], [37,36])

    def test_legacy_enclosure_version(self):
        feed = f'<rss xmlns:sparkle="{r.NS}"><channel><item><enclosure sparkle:version="40"/></item></channel></rss>'
        with self.assertRaises(RuntimeError):
            r.make_feed(feed, self.m)

    def test_stable_has_no_test_install_policy(self):
        item = ET.fromstring(r.make_feed(self.feed, dict(self.m, mode='stable'))).find('channel/item')
        self.assertIsNone(item.find(f'{{{r.NS}}}minimumAutoupdateVersion'))
        self.assertNotIn('未公证', item.findtext('title'))

    def test_corruption_fails_before_signature_tool(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / 'update.zip'
            archive.write_bytes(b'tampered')
            with patch.object(r, 'verifier') as verifier:
                with self.assertRaisesRegex(RuntimeError, 'SHA-256'):
                    r.verify_archive(archive, dict(sha256='0'*64, length=8))
                verifier.assert_not_called()

if __name__ == '__main__':
    unittest.main()
