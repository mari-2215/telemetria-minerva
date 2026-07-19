# Operacao do sistema

## Desenvolvimento local

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
pytest

export MINERVA_DEVICE_TOKEN=dev-device-token
export MINERVA_ACCESS_TOKENS_JSON='{"capitao-minerva-2026":{"name":"Capitã","role":"captain"},"tripulacao-minerva-2026":{"name":"Tripulação","role":"crew"},"dev-viewer-token":{"name":"Desenvolvimento","role":"admin"}}'
export MINERVA_CHIRPSTACK_TOKEN=dev-chirpstack-token
minerva-api
```

A API fica em `http://localhost:8080`, com OpenAPI em `/docs`.

## Perfis do aplicativo

O mesmo APK atende os dois perfis. O endereço do servidor é igual; o token define as permissões e o visual:

- `captain`: tema claro azul-marinho, gravação de trajetória, criação e ativação de missão;
- `crew`: visualização de frota, telemetria, mapa, trilha, motor e alarmes, sem comandos;
- `admin` e `operator`: mantêm permissão de capitão para compatibilidade;
- `read`: mantém comportamento de tripulação para compatibilidade.

Use tokens longos e exclusivos em produção. Os valores acima são apenas exemplos de desenvolvimento.

## Gravação da trajetória

O botão **Gravar trajetória** do perfil de capitão inicia uma sessão no backend da margem. Enquanto a sessão estiver ativa, cada telemetria válida do NEO-6M é adicionada à rota. Isso significa que a gravação continua mesmo se a tela do celular bloquear ou o aplicativo for minimizado.

Somente uma gravação por barco pode ficar ativa. Ao parar, o backend reduz a rota para no máximo 200 waypoints, cria uma missão em estado `draft` e mantém todos os pontos brutos da gravação no banco.

## Raspberry Pi embarcado

Interfaces padrao:

- `/dev/ttyACM0`: Arduino Mega por USB, 115200 baud;
- `/dev/ttyUSB0`: RAK3172 por USB-UART de 3,3 V, 115200 baud;
- `/var/lib/minerva-telemetry/outbox.db`: fila persistente.

Exemplo de `/etc/minerva-telemetry/boat.env`:

```dotenv
MINERVA_SERIAL_PORT=/dev/ttyACM0
MINERVA_SERIAL_BAUD=115200
MINERVA_BOAT_ID=azimutal-01
MINERVA_EDGE_DB=/var/lib/minerva-telemetry/outbox.db
MINERVA_API_URL=https://telemetria.exemplo.org
MINERVA_DEVICE_TOKEN=segredo-exclusivo-do-barco
MINERVA_LORA_SERIAL=/dev/ttyUSB0
MINERVA_LORA_DEV_EUI=0011223344556677
MINERVA_LORA_APP_EUI=0102030405060708
MINERVA_LORA_APP_KEY=00112233445566778899AABBCCDDEEFF
```

As chaves OTAA nunca entram no Git. O RAK3172 e configurado como LoRaWAN Class A, OTAA, ADR e AU915. A mascara de canais deve coincidir com o gateway/servidor escolhido e respeitar a faixa autorizada.

A Raspberry consulta uma missao pendente a cada 5 segundos quando existe acesso IP ao backend. Depois do download, a rota fica no SQLite local e continua sendo executada sem internet. O transporte de rotas completas por downlink LoRaWAN ainda nao faz parte deste driver: LoRaWAN permanece como uplink de telemetria/alarmes, e o envio da missao usa Wi-Fi, Ethernet ou 4G.

## Segurança do piloto automático

O CH3 apenas coloca o sistema em estado AUTO/armado. O motor continua parado até o canal de latch, conectado ao CH4 do receptor, receber uma borda de acionamento. Cada novo toque alterna START/STOP.

Ao sair de AUTO, perder sinal RC, perder GPS ou deixar de receber comandos frescos da Raspberry, o Arduino cancela o latch e manda o ESC para parada. O aplicativo não substitui esse intertravamento físico.

## Aplicativo

```bash
cd app
flutter create --platforms=android,web --org br.org.minervanautica .
flutter pub get
flutter run
```

No primeiro acesso, informar a URL da API e o token correspondente ao perfil. Para produção, distribuir tokens individuais e revogá-los pela configuração `MINERVA_ACCESS_TOKENS_JSON`.

## Backup

- copiar o volume do backend com o servico parado ou usar backup online do SQLite;
- guardar o `outbox.db` de cada ensaio ate validar a sincronizacao;
- exportar dados e logs por numero do ensaio e commit do software;
- nunca incluir tokens, AppKeys ou bancos com credenciais no repositorio.
