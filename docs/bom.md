# Lista de materiais orientativa

Esta BOM separa prototipo de bancada e instalacao de campo. Antes da compra, registrar fabricante, modelo, homologacao Anatel, conector, faixa e ganho de cada item RF. Nao comprar radio apenas porque o anuncio diz "915 MHz".

## Por barco

| Item | Quantidade | Especificacao recomendada | Observacao |
| --- | ---: | --- | --- |
| Raspberry Pi | 1 | Zero 2 W, Pi 4 ou o modelo ja disponivel | Zero 2 W reduz consumo; Pi 4 oferece mais margem |
| microSD industrial | 1 | 32-64 GB, high endurance | Banco local e sistema operacional |
| Conversor DC/DC | 1 | 12 V -> 5,1 V, 3 A (Pi 4) ou 2 A (Zero 2 W) | Dedicado, filtrado, com fusivel e TVS |
| Modem LoRaWAN | 1 | RAK3172(H)/RAK3272S ou equivalente, AU915/LA915 | Prototipo; confirmar homologacao antes do campo |
| Conversor USB-UART 3,3 V | 1 | CP2102/FTDI de qualidade | Pi para modem; nao usar UART 5 V |
| Antena de bordo | 1 | 915 MHz, 50 ohms, 2-3 dBi, meia onda, IP67 | Vertical, sem necessidade de plano de terra |
| Cabo RF | 1 | LMR-200/240, ate 1 m | Adaptadores e cabo longo consomem margem |
| Caixa | 1 | IP67 com prensa-cabos | Separar logica de ESC e cabos do motor |
| Sensor de agua | 2 | Contato/optico adequado ao casco | Dois pontos baixos independentes |
| Temperatura/umidade | 1 | SHT31 ou BME280 | Substitui DHT11 |
| GNSS | 1 | NEO-6M atual; M8N/M10 recomendado | Antena com visada do ceu |
| Acelerometro | 1 | ADXL345 atual | Montagem rigida e orientacao documentada |
| Corrente/tensao | 1 de cada | ACS712 e divisor atuais para bancada | Calibrar; avaliar sensor Hall isolado para campo |

## Estacao de margem

| Item | Quantidade | Especificacao recomendada | Observacao |
| --- | ---: | --- | --- |
| Gateway LoRaWAN outdoor | 1 | Khomp ITG 201 LoRa Outdoor 915 MHz ou equivalente homologado | Opcao brasileira para campo; confirmar integracao ChirpStack/API |
| Alternativa de laboratorio | 1 | RAK7268V2 AU915 | IP30: instalar dentro de caixa adequada; validar homologacao |
| Antena de margem | 1 | Omni 5-6 dBi; Yagi 8-11 dBi se o setor for fixo | Nunca exceder EIRP permitido |
| Mastro | 1 | 6-10 m | Altura melhora o enlace sobre agua |
| Backhaul | 1 | Ethernet/Wi-Fi e modem 4G de contingencia | Sem internet, apenas acesso local e sincronizacao posterior |
| Protecao | 1 conjunto | DPS RF, aterramento e protecao eletrica | Projeto conforme instalacao do laboratorio |
| Nobreak | 1 | Autonomia minima de 2 h | Gateway, roteador e modem |

## Escolha da antena

No barco, usar uma omni de 2-3 dBi. Ganho alto estreita o feixe vertical e pode causar sumico do sinal quando o casco aderna. Na margem, ganho e altura podem ser maiores porque a antena fica estavel.

Estimativa ideal em espaco livre para 2 km e 915 MHz:

- perda de percurso: aproximadamente 97,7 dB;
- transmissor a 20 dBm + antenas de 2 e 6 dBi - 2 dB de cabos: recepcao aproximada de -71,7 dBm;
- a margem teorica e grande, mas reflexao na agua, obstrucoes, conectores e interferencia precisam ser medidos em campo.

## Gate regulatorio

As faixas de radiacao restrita aplicaveis incluem 902-907,5 MHz e 915-928 MHz. Usar plano regional e mascara de canais que nao transmitam no intervalo proibido. Equipamentos em campo devem possuir certificacao/homologacao aceita pela Anatel e a potencia/EIRP deve respeitar os requisitos vigentes.

