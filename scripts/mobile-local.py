#!/usr/bin/env python3
"""Prepare device config; only API and private S3 uploads may be LAN-bound."""
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def output(args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.PIPE)


def main():
    address = os.environ.get('FLOW_MOBILE_BIND_IP', '')
    if not address:
        route = output(['/sbin/route', '-n', 'get', 'default'])
        interface = next(line.split(':', 1)[1].strip() for line in route.splitlines()
                         if line.strip().startswith('interface:'))
        address = output(['/usr/sbin/ipconfig', 'getifaddr', interface]).strip()
    ip = ipaddress.IPv4Address(address)
    if not any(ip in ipaddress.ip_network(network) for network in
               ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')):
        raise ValueError('Use um endereço IPv4 privado da rede Wi-Fi do Mac.')

    (ROOT / '.env.mobile.local').write_text(f'FLOW_MOBILE_BIND_IP={ip}\n')
    compose = json.loads(output([
        'docker', 'compose', '--env-file', '.env', '--env-file', '.env.mobile.local',
        '-f', 'infra/compose/compose.yaml', '-f', 'infra/compose/mobile-local.yaml',
        'config', '--format', 'json',
    ]))
    services = compose['services']
    if services['api']['environment'].get('FLOW_ENV') != 'development':
        raise ValueError('O backend local exige FLOW_ENV=development em .env.')
    port = None
    storage_port = None
    for name, service in services.items():
        for binding in service.get('ports', []):
            host = binding.get('host_ip', '')
            if name == 'api' and host == str(ip) and binding['target'] == 8080:
                port = int(binding['published'])
            elif name == 'storage' and host == str(ip) and binding['target'] == 8333:
                storage_port = int(binding['published'])
            elif not host or not ipaddress.ip_address(host).is_loopback:
                raise ValueError('Mantenha HOST_BIND=127.0.0.1; somente API e S3 privado podem usar a rede local.')
    if port is None or storage_port is None:
        raise ValueError('API e S3 privado precisam de portas na rede local.')
    if services['api']['environment'].get('MEDIA_S3_PUBLIC_ENDPOINT') != f'http://{ip}:{storage_port}':
        raise ValueError('O endpoint de upload precisa corresponder ao S3 local acessível pelo iPhone.')

    config = ROOT / 'apps/mobile/config/device.local.json'
    values = json.loads(config.read_text()) if config.exists() else {}
    if not isinstance(values, dict):
        raise ValueError('device.local.json deve conter um objeto JSON.')
    values.update(FLOW_ENV='development', API_BASE_URL=f'http://{ip}:{port}/',
                  APPLE_SIGN_IN_ENABLED=False,
                  DEVELOPMENT_PHONE_LOGIN_ENABLED=services['api']['environment'].get('AUTH_DEVELOPMENT_PHONE_ENABLED') == 'true')
    config.write_text(json.dumps(values, indent=2, ensure_ascii=False) + '\n')
    print(f'Configuração pública local salva: {config.relative_to(ROOT)}')
    print(f'API para o iPhone: {values["API_BASE_URL"]}')
    print(f'S3 privado para upload: http://{ip}:{storage_port}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError):
        print('Não foi possível preparar o ambiente local. Confira Docker, rede privada, '
              'FLOW_ENV=development e HOST_BIND=127.0.0.1. Se necessário, informe '
              'FLOW_MOBILE_BIND_IP com o IPv4 do Mac na mesma rede do iPhone.', file=sys.stderr)
        sys.exit(1)
