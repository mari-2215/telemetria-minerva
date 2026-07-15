# Operacao do sistema

## Desenvolvimento local

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
pytest

export MINERVA_DEVICE_TOKEN=dev-device-token
export MINERVA_ACCESS_TOKENS_JSON='{"dev-viewer-token":{"name":"Desenvolvimento","role":"admin"}}'
export MINERVA_CHIRPSTACK_TOKEN=dev-chirpstack-token
minerva-api
```

A API fica em `http://localhost:8080`, com OpenAPI em `/docs`.

## Raspberry Pi embarcado

Interfaces padrao:

- `/dev/ttyACM0`: Arduino Mega por USB, 115200 baud;
- `/dev/ttyUSB0`: RAK3172 por USB-UART de 3,3 V, 115200 baud;
- `/var/lib/minerva-telemetry/outbox.db`: fila persistente.

Exemplo de `/etc/minerva-telemetry/boat.env`:

```dotenv
MINERVA_SERIAL_PORT=/dev/ttyACM0
MINERVA_SERIAL_BAUD=115200
MINERVA_EDGE_DB=/var/lib/minerva-telemetry/outbox.db
MINERVA_API_URL=https://telemetria.exemplo.org
MINERVA_DEVICE_TOKEN=segredo-exclusivo-do-barco
MINERVA_LORA_SERIAL=/dev/ttyUSB0
MINERVA_LORA_DEV_EUI=0011223344556677
MINERVA_LORA_APP_EUI=0102030405060708
MINERVA_LORA_APP_KEY=00112233445566778899AABBCCDDEEFF
```

As chaves OTAA nunca entram no Git. O RAK3172 e configurado como LoRaWAN Class A, OTAA, ADR e AU915. A mascara de canais deve coincidir com o gateway/servidor escolhido e respeitar a faixa autorizada.

## ChirpStack

1. Configurar regiao AU915/LA915 compativel com o gateway e a mascara do endpoint.
2. Cadastrar cada barco com DevEUI, AppEUI/JoinEUI e AppKey unicos.
3. Configurar integracao HTTP para `POST /v1/integrations/chirpstack`.
4. Adicionar `X-Integration-Token` com o mesmo valor de `MINERVA_CHIRPSTACK_TOKEN`.
5. Usar o nome do dispositivo como `boat_id`, por exemplo `azimutal-01`.
6. Confirmar que RSSI e SNR aparecem no payload armazenado pelo backend.

## Aplicativo

```bash
cd app
flutter create --platforms=android,web --org br.org.minervanautica .
flutter pub get
flutter run
```

No primeiro acesso, informar a URL da API e um token de equipe/laboratorio. Para producao, distribuir tokens individuais e revoga-los pela configuracao `MINERVA_ACCESS_TOKENS_JSON`. Uma fase posterior pode substituir esse mecanismo por OIDC institucional sem alterar os endpoints de telemetria.

## Backup

- copiar o volume do backend com o servico parado ou usar backup online do SQLite;
- guardar o `outbox.db` de cada ensaio ate validar a sincronizacao;
- exportar dados e logs por numero do ensaio e commit do software;
- nunca incluir tokens, AppKeys ou bancos com credenciais no repositorio.
