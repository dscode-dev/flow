import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('readiness', pathlib.Path(__file__).with_name('auth-readiness.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AuthReadinessTests(unittest.TestCase):
    def test_release_audit_rejects_temporary_phone_on_either_side(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            public, server = root / 'public.json', root / 'server.env'
            for client_enabled, backend_enabled in [(True, 'false'), (False, 'true')]:
                public.write_text(json.dumps({'FLOW_ENV': 'production', 'DEVELOPMENT_PHONE_LOGIN_ENABLED': client_enabled}))
                server.write_text('FLOW_ENV=production\nAUTH_DEVELOPMENT_PHONE_ENABLED=' + backend_enabled + '\n')
                checks = module.audit(public, server)
                self.assertFalse(next(c['passed'] for c in checks if c['code'] == 'development_phone_disabled'))

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

    def test_personal_signing_cannot_approve_apple_or_production_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            files = {
                'apps/mobile/android/app/build.gradle.kts': 'applicationId = "dev.approved.flow"',
                'apps/mobile/ios/Runner.xcodeproj/project.pbxproj': 'PRODUCT_BUNDLE_IDENTIFIER = "$(FLOW_IOS_BUNDLE_IDENTIFIER)";',
                'apps/mobile/ios/Flutter/Auth.xcconfig': 'FLOW_IOS_BUNDLE_IDENTIFIER = dev.approved.flow\nFLOW_CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements\n',
                'public.json': json.dumps({'APPLE_SIGN_IN_ENABLED': True}),
                'server.env': 'APPLE_CLIENT_IDS=dev.approved.flow\n',
            }
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            runner = root / 'apps/mobile/ios/Runner'
            runner.mkdir(parents=True)
            (runner / 'Runner.entitlements').write_bytes(plistlib.dumps({'com.apple.developer.applesignin': ['Default']}))
            (runner / 'RunnerPersonal.entitlements').write_bytes(plistlib.dumps({}))
            local = root / 'apps/mobile/ios/Flutter/Auth.local.xcconfig'
            with patch.object(module, 'ROOT', root):
                def passed(code):
                    return next(c['passed'] for c in module.audit(root / 'public.json', root / 'server.env') if c['code'] == code)
                self.assertTrue(passed('apple_native'))
                local.write_text('FLOW_CODE_SIGN_ENTITLEMENTS = Runner/RunnerPersonal.entitlements\n')
                self.assertFalse(passed('apple_native'))
                local.write_text('FLOW_IOS_BUNDLE_IDENTIFIER = dev.flow.local.provisional\n')
                self.assertFalse(passed('ios_bundle'))


if __name__ == '__main__':
    unittest.main()
