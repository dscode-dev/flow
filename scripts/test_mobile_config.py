import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('mobile_config', Path(__file__).with_name('mobile-config.py'))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class MobileConfigTests(unittest.TestCase):
    def test_mapbox_secret_never_becomes_dart_define(self):
        base = ['run', '-DAPI_BASE_URL=https://api.flow.invalid/']
        for value in ('sk.private-value', 'not-a-public-token'):
            error = config.configuration_error(base + ['-DMAPBOX_PUBLIC_ACCESS_TOKEN=' + value])
            self.assertIsNotNone(error)
            self.assertNotIn(value, error)
        self.assertIsNotNone(config.configuration_error(base + ['-DMAPBOX_DOWNLOADS_TOKEN=private-value']))
        self.assertIsNone(config.configuration_error(base))

    def test_temporary_phone_flag_cannot_be_built_as_production(self):
        self.assertIsNotNone(config.configuration_error([
            'run', '-DFLOW_ENV=production', '-DAPI_BASE_URL=https://api.flow.invalid/',
            '-DDEVELOPMENT_PHONE_LOGIN_ENABLED=true']))

    def test_missing_api_fails_before_installation(self):
        for args in (['run', '--release', '--dart-define=APPLE_SIGN_IN_ENABLED=false'],
                     ['build', 'ios', '--release']):
            self.assertIn('API_BASE_URL ausente', config.configuration_error(args))

    def test_local_development_and_production_https(self):
        for environment, url in [('development', 'http://192.168.100.6:18080/'),
                                 ('production', 'https://api.flow.invalid/v1/')]:
            self.assertIsNone(config.configuration_error([
                'run', f'--dart-define=FLOW_ENV={environment}', f'-DAPI_BASE_URL={url}']))

    def test_invalid_urls_are_rejected_without_values(self):
        for url in ['', 'http://api.flow.invalid/', 'https://private-marker@api.flow.invalid/',
                    'https://api.flow.invalid/no-final-slash', 'https://api.flow.invalid/?key=private-marker',
                    'https://api.flow.invalid/#private-marker', 'https://api.flow.invalid:invalid/']:
            error = config.configuration_error([
                'run', '-D', 'FLOW_ENV=production', '--dart-define', f'API_BASE_URL={url}'])
            self.assertIsNotNone(error)
            self.assertNotIn('private-marker', error)

    def test_file_values_and_cli_precedence_match_flutter(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'defines.data'
            file.write_text(json.dumps({'FLOW_ENV': 'production', 'API_BASE_URL': ''}))
            self.assertIsNone(config.configuration_error([
                'build', 'ios', '--dart-define=API_BASE_URL=https://api.flow.invalid/',
                '--dart-define-from-file', str(file)]))
            file.write_text('FLOW_ENV=development\nAPI_BASE_URL="http://192.168.100.6:18080/"\n')
            self.assertIsNone(config.configuration_error([
                'run', f'--dart-define-from-file={file}']))

    def test_bad_file_and_environment_fail_without_tracebacks(self):
        self.assertIsNotNone(config.configuration_error(['run', '--dart-define-from-file=/absent/defines.json']))
        self.assertIsNotNone(config.configuration_error(['run', '-DFLOW_ENV=unknown']))
        self.assertIsNotNone(config.configuration_error(['run', '--dart-define']))

    def test_non_application_commands_and_help_do_not_require_api(self):
        for args in ([], ['--version'], ['test'], ['analyze'], ['pub', 'get'],
                     ['build', 'ios-framework'], ['run', '--help'], ['build', 'ios', '-h']):
            self.assertIsNone(config.configuration_error(args))


if __name__ == '__main__':
    unittest.main()
