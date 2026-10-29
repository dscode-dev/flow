#!/usr/bin/env python3
"""Structural checks only; never proof of provider/physical/release acceptance.

Reads public Dart defines and backend environment without executing either file.
Only categories/booleans are printed. Never print exceptions containing input values.
"""
import argparse
import json
import os
import pathlib
import re
import sys
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parent.parent
PUBLIC_KEYS = {
    'FLOW_ENV', 'API_BASE_URL', 'GOOGLE_SERVER_CLIENT_ID', 'GOOGLE_IOS_CLIENT_ID',
    'APPLE_SIGN_IN_ENABLED', 'TERMS_URL', 'PRIVACY_URL', 'LEGAL_LINKS_APPROVED',
}


def secure_url(raw):
    try:
        u = urlsplit(raw)
        return (u.scheme == 'https' and bool(u.hostname) and not u.username and
                not u.password and u.hostname not in {'localhost', '127.0.0.1', '::1', 'example.com', 'example.org', 'example.net'} and
                not u.hostname.endswith(('.example', '.test', '.invalid', '.localhost', '.example.com', '.example.org', '.example.net')))
    except (ValueError, TypeError):
        return False


def configured(raw):
    return isinstance(raw, str) and bool(raw.strip()) and not re.search(
        r'(?i)(example|placeholder|replace|seu_host|todo|\[|<|>)', raw)


def load_environment(path):
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip().strip('\"\'')
    return {**values, **os.environ}


def audit(config_path, server_env_path):
    checks = []
    def check(code, passed, owner, action):
        checks.append({'code': code, 'passed': bool(passed), 'owner': owner, 'action': action})
    public = {}
    try:
        public = json.loads(config_path.read_text())
        valid = (isinstance(public, dict) and set(public) <= PUBLIC_KEYS and
                 all(isinstance(v, bool) if k in {'APPLE_SIGN_IN_ENABLED', 'LEGAL_LINKS_APPROVED'} else isinstance(v, str)
                     for k, v in public.items()))
    except (OSError, ValueError, UnicodeError):
        valid = False
    check('public_config', valid, 'Mobile', 'Criar arquivo público local a partir do exemplo; somente chaves permitidas, sem segredos.')
    if not valid:
        public = {}
    try:
        server = load_environment(server_env_path)
    except (OSError, UnicodeError):
        server = {}
    check('environment', public.get('FLOW_ENV') == 'production' and server.get('FLOW_ENV') == 'production', 'Mobile/Infra', 'Separar configuração de produção e homologação; release exige FLOW_ENV=production no app e no servidor.')
    api = public.get('API_BASE_URL', '')
    check('api_https', secure_url(api) and api.endswith('/') and not urlsplit(api).query and not urlsplit(api).fragment,
          'Infra', 'Definir origem API HTTPS aprovada, sem credenciais/query/fragment e com barra final; validar DNS/TLS no ambiente real.')
    google = public.get('GOOGLE_SERVER_CLIENT_ID', '')
    ios_google = public.get('GOOGLE_IOS_CLIENT_ID', '')
    client_pattern = r'[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com'
    check('google_clients', bool(re.fullmatch(client_pattern, str(google))) and bool(re.fullmatch(client_pattern, str(ios_google))),
          'Google Cloud/Mobile', 'Criar clientes Web e iOS aprovados; registrar também package/SHA-1 do cliente Android no console.')
    audiences = {v.strip() for v in server.get('GOOGLE_CLIENT_IDS', '').split(',') if v.strip()}
    check('google_audiences', bool(google and ios_google) and {google, ios_google} <= audiences,
          'Backend/Google Cloud', 'Configurar GOOGLE_CLIENT_IDS com audiences/azp reais aprovados, sem wildcard.')
    gradle = (ROOT / 'apps/mobile/android/app/build.gradle.kts').read_text()
    app_id = re.search(r'applicationId\s*=\s*"([^"]+)"', gradle)
    check('android_application_id', app_id is not None and configured(app_id[1]) and not app_id[1].startswith('com.example.'),
          'Mobile/Produto', 'Aprovar e aplicar applicationId/namespace/package; gerar fingerprints das chaves efetivas debug e release.')
    pbx = (ROOT / 'apps/mobile/ios/Runner.xcodeproj/project.pbxproj').read_text()
    bundles = set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);', pbx))
    app_bundles = {v.strip().strip('"') for v in bundles if not v.strip().strip('"').endswith('.RunnerTests')}
    native_id_ok = len(app_bundles) == 1 and all(configured(v) and not v.startswith('com.example.') for v in app_bundles)
    check('ios_bundle', native_id_ok, 'Apple Developer/Mobile', 'Aprovar bundle e aplicar em todos os build configurations e App ID Apple.')
    check('ios_signing_team', bool(re.search(r'DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10};', pbx)),
          'Apple Developer/Mobile', 'Selecionar equipe/provisionamento compatível com bundle, Keychain e Sign in with Apple; não versionar chaves.')
    local = ROOT / 'apps/mobile/ios/Flutter/Auth.local.xcconfig'
    reversed_id = ''
    if local.exists():
        match = re.search(r'^\s*FLOW_GOOGLE_REVERSED_CLIENT_ID\s*=\s*([^\n]*)', local.read_text(), re.M)
        if match:
            reversed_id = match[1].strip()
    check('ios_google_callback', bool(ios_google) and reversed_id == '.'.join(str(ios_google).split('.')[::-1]),
          'Mobile/Google Cloud', 'Preencher Auth.local.xcconfig com reversed client ID correspondente; confirmar Info.plist no app compilado.')
    apple_ids = {v.strip() for v in server.get('APPLE_CLIENT_IDS', '').split(',') if v.strip()}
    check('apple_native', public.get('APPLE_SIGN_IN_ENABLED') is True and native_id_ok and app_bundles <= apple_ids,
          'Apple Developer/Backend', 'Habilitar capability no App ID e provisioning; configurar APPLE_CLIENT_IDS com bundle real e notificação HTTPS.')
    twilio = (server.get('TWILIO_ACCOUNT_SID', ''), server.get('TWILIO_VERIFY_SERVICE_SID', ''), server.get('TWILIO_AUTH_TOKEN', ''))
    check('twilio_verify', bool(re.fullmatch(r'AC[0-9a-fA-F]{32}', twilio[0])) and bool(re.fullmatch(r'VA[0-9a-fA-F]{32}', twilio[1])) and len(twilio[2]) >= 16,
          'Twilio/Backend', 'Provisionar Verify/Geo Permissions/Fraud Guard/orçamento e injetar credenciais exclusivamente no servidor.')
    check('backend_hmac', bool(re.fullmatch(r'[0-9a-fA-F]{64}', server.get('IDENTITY_HMAC_KEY', ''))),
          'Infra/Segurança', 'Injetar chave HMAC persistente e independente por ambiente, com rotação controlada e sem expô-la ao app.')
    check('legal_urls', public.get('LEGAL_LINKS_APPROVED') is True and all(secure_url(public.get(k, '')) for k in ('TERMS_URL', 'PRIVACY_URL')),
          'Produto/Privacidade', 'Publicar destinos reais revisados, verificar conteúdo/status/redirecionamentos e só então aprovar os links.')
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-config', type=pathlib.Path, default=ROOT / 'apps/mobile/config/auth.public.local.json')
    parser.add_argument('--server-env', type=pathlib.Path, default=ROOT / '.env')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    checks = audit(args.public_config, args.server_env)
    if args.json:
        print(json.dumps({'scope': 'structural_only', 'checks': checks,
                          'external_homologation_verified': False}, ensure_ascii=False, indent=2))
    else:
        for item in checks:
            print(f"{'OK' if item['passed'] else 'PENDENTE'} {item['code']} — {item['owner']}: {item['action']}")
        print('Somente configuração estrutural. Marca, assinatura real, HTTPS, providers, aparelhos e CI exigem evidência separada.')
    return 0 if all(item['passed'] for item in checks) else 1


if __name__ == '__main__':
    sys.exit(main())
