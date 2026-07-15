# Arquitetura de referencia

## Principios

1. O Arduino executa aquisicao deterministica e o fail-safe local.
2. O Raspberry Pi processa, registra e transporta dados, mas nao e necessario para manter o motor seguro.
3. Toda amostra recebe `boat_id`, sequencia, horario monotonicamente crescente e qualidade.
4. Toda fila de saida e persistente: perda de internet nao perde o ensaio.
5. O aplicativo e observador. Comandos remotos ficam desabilitados no MVP.

## Bordo

O Arduino Mega mantem o controle azimutal e le os sensores. A ligacao recomendada ao Raspberry Pi e USB, evitando ligar UART de 5 V diretamente aos GPIO de 3,3 V do Pi. O firmware publica um quadro binario ou CBOR a 10 Hz com CRC-16. O Pi agrega as amostras, executa filtros, calcula grandezas derivadas e salva tudo em SQLite antes de transmitir.

Taxas sugeridas:

| Dado | Aquisicao local | Envio ao app |
| --- | ---: | ---: |
| GPS | 1-5 Hz | 1-2 Hz |
| Acelerometro | 50-100 Hz | 2-5 Hz, ja agregado |
| Tensao/corrente | 10 Hz | 1-2 Hz |
| Temperaturas/umidade | 1 Hz | 0,2-1 Hz |
| Estado RC/servo/ESC | 10-50 Hz | 2-5 Hz |
| Alarmes | por evento | imediato e repetido ate confirmar |

## Radio

Para varios barcos, a referencia e LoRaWAN em plano AU915, limitado a frequencias permitidas e usando equipamentos homologados pela Anatel. O radio transporta telemetria compacta e alarmes; nao e adequado para video nem para amostras brutas de IMU.

O payload normal deve permanecer abaixo de 100 bytes. Prioridades:

- P0: entrada de agua, bateria critica, perda de RC e falha de sensor;
- P1: posicao, velocidade, corrente, tensao e estado do propulsor;
- P2: estatisticas de vibracao, temperaturas e diagnosticos;
- P3: logs extensos, enviados apenas por Wi-Fi/4G ao final do ensaio.

## Margem e nuvem

O gateway recebe LoRa e envia os pacotes ao backend. Se a internet cair, guarda uma fila local e oferece um painel pela rede Wi-Fi do proprio gateway. O backend recomendado possui:

- broker MQTT;
- API FastAPI;
- PostgreSQL com TimescaleDB opcional;
- WebSocket para atualizacao do app;
- armazenamento de arquivos para exportacoes e logs;
- autenticacao com papeis `admin`, `operador`, `laboratorio` e `leitura`.

## Aplicativo

Um unico projeto Flutter atende Android, iOS e navegador. Telas do MVP:

1. login e selecao de embarcacao;
2. mapa com trilha, velocidade e qualidade do enlace;
3. painel ao vivo de bateria, corrente, temperaturas e propulsor;
4. alarmes com confirmacao e linha do tempo;
5. lista de ensaios e replay;
6. exportacao CSV/JSON;
7. diagnostico de sensores e versoes de firmware.

## Operacao degradada

- Sem LoRa: o Pi continua gravando e tenta retransmitir.
- Sem internet na margem: usuarios locais acessam o gateway; sincronizacao ocorre depois.
- Sem Raspberry Pi: Arduino mantem controle e fail-safe, mas nao ha telemetria.
- Sem aplicativo: nada muda no controle do barco.

