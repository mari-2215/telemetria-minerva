# Hardware inicial

## Enlace recomendado

### No barco

- transceptor LoRa/LoRaWAN SX1262 ou STM32WLE5 para 902-928 MHz, em variante homologada pela Anatel;
- antena vertical omnidirecional de 915 MHz, 50 ohms, 2 a 3 dBi, IP67, preferencialmente meia onda sem plano de terra;
- montagem vertical, acima da linha d'agua e afastada de motor, ESC, cabos de potencia e partes metalicas;
- cabo coaxial LMR-200/LMR-240 ou equivalente, o mais curto possivel, com conectores impermeabilizados.

Antena de ganho alto nao e desejavel no barco: o diagrama vertical estreito pode criar perda de sinal quando a embarcacao aderna.

### Na margem

- gateway LoRaWAN multicanal para AU915, ou Heltec ESP32 V3/SX1262 quando o enlace estiver configurado em LoRa P2P;
- antena omni de 5 a 6 dBi em mastro quando barcos podem estar em qualquer direcao; ou Yagi de 8 a 11 dBi quando toda a area fica em um unico setor;
- mastro de 6 a 10 m sempre que possivel;
- protecao contra surtos e aterramento de acordo com a instalacao do laboratorio;
- backhaul Ethernet/Wi-Fi e modem 4G de contingencia.

## Altura e propagacao

Em 915 MHz, a agua e uma superficie refletora forte; por isso altura de antena, polarizacao vertical, cabo curto e testes de campo importam mais que simplesmente aumentar a potencia.

## Energia do Raspberry Pi

Nao usar o pequeno LM2596 do desenho para alimentar o Raspberry Pi junto com radio e perifericos. Usar um conversor 12 V -> 5,1 V dedicado, filtrado e dimensionado para o modelo do Pi:

- Raspberry Pi 4: 5 V / 3 A;
- Raspberry Pi 5: 5 V / 5 A para operacao sem limitacao de perifericos;
- Pi Zero 2 W: 5 V / 2 A, suficiente para o servico de telemetria e mais economico.

Adicionar fusivel proprio, protecao contra inversao, TVS, filtro e desligamento limpo. O circuito de propulsao deve ficar separado da alimentacao logica tanto quanto praticavel.

## Pinagem do firmware integrado — Azimutal

### Receptor FlySky

| Função real | Canal | Mega 2560 |
| --- | ---: | --- |
| Direção horizontal dos dois pods, ±45° | CH4 | D2 |
| Seleção travada FRENTE/RÉ, giro de 180° | CH3 | D3 |
| Potência do propulsor | CH2 | D18 |
| Latch físico START/STOP do piloto automático | CH1 | D19 |

O receptor é alimentado uma única vez pelo BEC ou pela alimentação prevista
para o rádio. Para cada canal adicional, o Arduino precisa do sinal e do GND
comum. Não una positivos provenientes de fontes diferentes.

### Atuadores

| Função | Mega 2560 |
| --- | --- |
| Sinal do servo azimutal 1 | D9 |
| Sinal do ESC | D10 |
| Sinal do servo azimutal 2 | D11 |

Os dois servos recebem o mesmo ângulo lógico. Caso a montagem seja espelhada,
use `kServo1Inverted` e `kServo2Inverted` individualmente. Os servos recebem
somente o sinal do Mega e alimentação de BEC/fonte externa dimensionada.
GND do BEC, servos, ESC, receptor e Mega deve ser comum.

### Sensores e comunicação

| Função | Mega 2560 |
| --- | --- |
| GPS TX → Mega RX2 | D17 |
| GPS RX ← Mega TX2, opcional | D16 |
| ADXL345 | SDA D20 / SCL D21 |
| LM35 | A0 |
| ACS712 | A3 |
| Divisor de tensão | A4 |
| DHT11 | D22 |
| Sensor de água, ativo em LOW | D23 |

D18 e D19 ficam reservados ao receptor. O GPS permanece na `Serial2`,
D16/D17. Raspberry e Mega conversam por USB a 115200 baud.

## Melhorias recomendadas nos sensores

- adicionar sensor de agua no casco em pelo menos dois pontos;
- substituir DHT11 por SHT31 ou BME280;
- considerar GNSS u-blox M8N/M10 com antena externa;
- adicionar magnetometro/IMU se rumo parado for requisito;
- manter o ADXL345 para vibracao, com montagem mecanica documentada;
- calibrar ACS712 e voltimetro contra instrumentos de referencia;
- medir RSSI, SNR, perda de pacotes, temperatura do Pi e `undervoltage`.

## Pontos de seguranca encontrados

- Mega trabalha com logica de 5 V; Raspberry Pi e radios modernos usam 3,3 V. Preferir USB ou usar conversor de nivel adequado.
- O ESP8266 mostrado no esquema nao alcanca 2 km e pode ser removido do enlace principal.
- O botao de emergencia deve cortar energia do atuador/ESC por hardware, nao apenas sinalizar software.
- Todos os radios usados em campo devem possuir homologacao aplicavel da Anatel.
