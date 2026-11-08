import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mobile_local', Path(__file__).with_name('mobile-local.py'))
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


class MobileLocalTests(unittest.TestCase):
    def prepare(self, root, dependency_host='127.0.0.1', environment='development'):
        compose = {'services': {
            'api': {'environment': {'FLOW_ENV': environment, 'MEDIA_S3_PUBLIC_ENDPOINT': 'http://192.168.100.6:18333'}, 'ports': [
                {'host_ip': '127.0.0.1', 'target': 8080, 'published': '18080'},
                {'host_ip': '192.168.100.6', 'target': 8080, 'published': '18080'}]},
            'postgres': {'ports': [{'host_ip': dependency_host, 'target': 5432, 'published': '15432'}]},
            'storage': {'ports': [{'host_ip': '192.168.100.6', 'target': 8333, 'published': '18333'}]},
        }}
        with patch.object(local, 'ROOT', root), patch.object(local, 'output', return_value=json.dumps(compose)), \
                patch.dict(os.environ, {'FLOW_MOBILE_BIND_IP': '192.168.100.6'}), \
                contextlib.redirect_stdout(io.StringIO()):
            local.main()

    def test_generates_device_config_preserving_other_public_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'apps/mobile/config/device.local.json'
            config.parent.mkdir(parents=True)
            config.write_text(json.dumps({'GOOGLE_IOS_CLIENT_ID': 'approved-public-id'}))
            self.prepare(root)
            data = json.loads(config.read_text())
            self.assertEqual(data['API_BASE_URL'], 'http://192.168.100.6:18080/')
            self.assertEqual(data['FLOW_ENV'], 'development')
            self.assertIs(data['APPLE_SIGN_IN_ENABLED'], False)
            self.assertEqual(data['GOOGLE_IOS_CLIENT_ID'], 'approved-public-id')

    def test_refuses_exposed_dependencies_and_production(self):
        for host, environment in [('0.0.0.0', 'development'), ('', 'development'),
                                  ('192.168.100.6', 'development'), ('127.0.0.1', 'production')]:
            with self.subTest(host=host, environment=environment), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self.assertRaises(ValueError):
                    self.prepare(root, host, environment)
                self.assertFalse((root / 'apps/mobile/config/device.local.json').exists())

    def test_refuses_public_or_loopback_as_device_address(self):
        for address in ['0.0.0.0', '127.0.0.1', '8.8.8.8', '::1']:
            with patch.dict(os.environ, {'FLOW_MOBILE_BIND_IP': address}), self.assertRaises(ValueError):
                local.main()


if __name__ == '__main__':
    unittest.main()
