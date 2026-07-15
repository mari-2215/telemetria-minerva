# Telemetria Minerva

Plataforma de telemetria para os modelos navais da Minerva Nautica, com cobertura planejada para um lago de ate 2 km, processamento embarcado em Raspberry Pi e acesso por aplicativo para equipe e laboratorio.

## Escopo

- coleta no Arduino Mega dos sensores e estados do controle azimutal;
- processamento, armazenamento e reenvio no Raspberry Pi embarcado;
- enlace LoRa/LoRaWAN em 915-928 MHz entre barco e margem;
- gateway de margem com internet por Ethernet, Wi-Fi ou 4G;
- backend com autenticacao, historico, alertas e tempo real;
- aplicativo Flutter para Android, iOS e Web;
- operacao degradada quando a internet ou o radio falhar.

> Telemetria nao controla propulsao, leme ou parada de emergencia. Controle RC, fail-safe e botao fisico continuam independentes.

## Arquitetura

```mermaid
flowchart LR
  S["Sensores e controle"] --> A["Arduino Mega"]
  A -->|"USB serial com CRC"| P["Raspberry Pi embarcado"]
  P --> D["SQLite / fila persistente"]
  P -->|"LoRaWAN AU915"| G["Gateway na margem"]
  G -->|"Ethernet / Wi-Fi / 4G"| B["API + MQTT + PostgreSQL"]
  B --> APP["App Flutter"]
  P -. "4G opcional" .-> B
```

Mais detalhes: [arquitetura](docs/arquitetura.md), [hardware](docs/hardware.md), [BOM](docs/bom.md), [operacao](docs/operacao.md) e [teste de campo](docs/teste-campo.md).

## Sensores identificados nos esquemas

| Medida | Componente atual | Observacao |
| --- | --- | --- |
| Posicao | GPS NEO-6M | UART; considerar M8N/M10 para maior robustez |
| Aceleracao/inclinacao | ADXL345 | I2C; nao fornece rumo absoluto |
| Temperatura | LM35 | Analogico |
| Corrente | ACS712 | Analogico; requer calibracao de zero e filtragem |
| Tensao da bateria | Modulo 0-25 V | Analogico; requer calibracao |
| Umidade/temperatura interna | DHT11 | Trocar por SHT31/BME280 e adicionar sensor de agua |
| Estado do propulsor | Firmware azimutal | Angulo, aceleracao, PWM e fail-safe |

## Estrutura prevista

```text
firmware/mega/       aquisicao e enquadramento no Arduino
edge/boat/           servico do Raspberry Pi embarcado
edge/gateway/        servico do gateway de margem
backend/             API, ingestao MQTT, alertas e banco
app/                 aplicativo Flutter
protocol/            contratos de mensagens e versoes
deploy/              Docker Compose e servicos systemd
docs/                arquitetura, montagem e testes
```

## Fases

1. Reproduzir sensores em bancada e calibrar cada canal.
2. Implementar pacote serial versionado com CRC e simulador.
3. Gravar e visualizar dados localmente no Raspberry Pi.
4. Validar LoRa a 100 m, 500 m, 1 km e 2 km.
5. Subir backend e aplicativo com dados simulados.
6. Integrar um barco e executar teste de perda de enlace.
7. Escalar para os demais barcos e habilitar alertas.

## Projeto relacionado

- [mari-2215/azimutal-minerva](https://github.com/mari-2215/azimutal-minerva)

## Licenca

MIT.

## Estado atual

- protocolo USB serial com CRC-16 e recuperacao apos ruido;
- fila SQLite independente para nuvem e LoRaWAN;
- payload LoRaWAN binario de 37 bytes;
- driver RAK3172/RUI3 com OTAA e AU915;
- API FastAPI com ingestao, historico, WebSocket, papeis e alertas;
- integracao HTTP ChirpStack;
- app Flutter com login, frota, alarmes, mapa e painel ao vivo;
- firmware de aquisicao para Arduino Mega;
- Docker, systemd e CI para Python, firmware, Flutter e container.

## Aplicativos Android e iPhone

O GitHub Actions gera automaticamente um APK Android instalavel, um AAB para a Google Play e uma compilacao iOS sem assinatura. Os pacotes ficam disponiveis na secao **Artifacts** de cada execucao do workflow `CI`.

A distribuicao para iPhone exige assinatura Apple. O caminho recomendado para a equipe e o laboratorio e o TestFlight. Consulte [docs/aplicativos.md](docs/aplicativos.md) para baixar o APK e preparar a conta Apple.
