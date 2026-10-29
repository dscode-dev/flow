import importlib.util
import json
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('readiness', pathlib.Path(__file__).with_name('auth-readiness.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AuthReadinessTests(unittest.TestCase):
    def test_missing_config_is_reported_without_secret_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            env = root / 'backend.env'
            env.write_text('TWILIO_AUTH_TOKEN=private-marker-do-not-print\n')
            checks = module.audit(root / 'missing.json', env)
            self.assertFalse(all(c['passed'] for c in checks))
            self.assertNotIn('private-marker-do-not-print', json.dumps(checks))
            self.assertIn('public_config', [c['code'] for c in checks if not c['passed']])

    def test_public_config_rejects_secret_keys_and_wrong_types(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            public = root / 'public.json'
            for data in [{'TWILIO_AUTH_TOKEN': 'never-in-app'}, {'GOOGLE_SERVER_CLIENT_ID': []}]:
                public.write_text(json.dumps(data))
                self.assertFalse(module.audit(public, root / 'missing.env')[0]['passed'])

    def test_app_production_does_not_approve_backend_development(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            public = root / 'public.json'
            public.write_text(json.dumps({'FLOW_ENV': 'production'}))
            server = root / 'backend.env'
            server.write_text('FLOW_ENV=development\n')
            checks = module.audit(public, server)
            self.assertFalse(next(c['passed'] for c in checks if c['code'] == 'environment'))

    def test_release_urls_reject_credentials_and_placeholder_destinations(self):
        for uri in ['http://real.domain/', 'https://secret@real.domain/', 'https://localhost/',
                    'https://legal.example/', 'https://example.com/', 'not-a-url']:
            self.assertFalse(module.secure_url(uri))
        self.assertTrue(module.secure_url('https://approved.domain/path'))


if __name__ == '__main__':
    unittest.main()
