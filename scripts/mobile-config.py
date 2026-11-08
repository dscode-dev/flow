#!/usr/bin/env python3
"""Validate compile-time app configuration without printing define values."""
import json
import pathlib
import re
import sys
from urllib.parse import urlsplit

APP_BUILDS = {'apk', 'appbundle', 'ios', 'ipa', 'web', 'macos', 'linux', 'windows', 'bundle'}


def configuration_error(args):
    if '--help' in args or '-h' in args:
        return None
    if not args or (args[0] != 'run' and not (args[0] == 'build' and len(args) > 1 and args[1] in APP_BUILDS)):
        return None
    files, direct = [], []
    index = 1
    while index < len(args):
        value = args[index]
        target = None
        if value in ('--dart-define-from-file', '--dart-define', '-D'):
            if index + 1 == len(args):
                return 'Falta o valor de uma opção dart-define.'
            target = files if value == '--dart-define-from-file' else direct
            index += 1
            target.append(args[index])
        elif value.startswith('--dart-define-from-file='):
            files.append(value.split('=', 1)[1])
        elif value.startswith('--dart-define='):
            direct.append(value.split('=', 1)[1])
        elif value.startswith('-D') and len(value) > 2:
            direct.append(value[2:])
        index += 1
    defines = {}
    for name in files:
        try:
            path = pathlib.Path(name)
            raw = path.read_text()
            if raw.lstrip().startswith('{'):
                values = json.loads(raw)
                if not isinstance(values, dict):
                    return 'O arquivo de dart-defines deve conter um objeto JSON.'
            else:
                values = {}
                for line in raw.splitlines():
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        values[key.strip()] = value.strip().strip('\"\x27')
            defines.update(values)
        except (OSError, ValueError, UnicodeError):
            return 'Não foi possível ler o arquivo de dart-defines. Confira o caminho e o formato.'
    # Flutter loads file values first; explicit command-line defines win.
    for entry in direct:
        key, separator, value = entry.partition('=')
        if not separator:
            return 'dart-define deve ter o formato CHAVE=valor.'
        defines[key] = value
    environment = defines.get('FLOW_ENV', 'development')
    if environment not in ('development', 'test', 'production'):
        return 'FLOW_ENV deve ser development, test ou production.'
    if environment == 'production' and defines.get('DEVELOPMENT_PHONE_LOGIN_ENABLED') in (True, 'true'):
        return 'Desabilite DEVELOPMENT_PHONE_LOGIN_ENABLED para produção.'
    map_token = defines.get('MAPBOX_PUBLIC_ACCESS_TOKEN', '')
    # Empty public token is allowed: only Radar is unavailable. Never compile a secret token.
    if not isinstance(map_token, str) or (map_token and not re.fullmatch(r'pk\.[A-Za-z0-9._-]{20,4096}', map_token)):
        return 'Mapbox requer token público pk.; token secreto ou inválido não pode ser incorporado ao app.'
    for key, value in defines.items():
        if 'MAPBOX' in key and ('SECRET' in key or 'DOWNLOAD' in key or 'ADMIN' in key):
            return 'Credenciais privadas Mapbox não são dart-defines.'
    raw = defines.get('API_BASE_URL', '')
    if not isinstance(raw, str) or not raw:
        return ('API_BASE_URL ausente: informe --dart-define-from-file=config/device.local.json '
                'ou --dart-define=API_BASE_URL=<URL real com barra final>.')
    try:
        uri = urlsplit(raw)
        _ = uri.port
        valid = (raw == raw.strip() and uri.scheme in ('https', 'http') and uri.hostname and
                 not uri.username and not uri.password and '?' not in raw and '#' not in raw and
                 uri.path.endswith('/') and (environment != 'production' or uri.scheme == 'https'))
    except ValueError:
        valid = False
    if not valid:
        return 'API_BASE_URL inválida: use URL absoluta com barra final, sem credenciais/query/fragmento; produção exige HTTPS.'
    return None


if __name__ == '__main__':
    error = configuration_error(sys.argv[1:])
    if error:
        print('Configuração do app: ' + error, file=sys.stderr)
        sys.exit(2)
