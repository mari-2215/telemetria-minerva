# Autonomia, gravacao e rotas

## Fluxo completo

1. No app, abra a embarcacao e toque em **Rotas**.
2. Marque os waypoints na ordem desejada e escolha uma potencia de cruzeiro conservadora.
3. **Salvar e enviar ao barco** cria a missao no backend e a deixa pendente.
4. A Raspberry consulta o backend, valida a missao, salva no SQLite e confirma o estado `active`.
5. Com CH3 em AUTO, a Raspberry calcula distancia, bearing e erro de rumo. Um controlador fuzzy combina erro angular e distancia para escolher o angulo logico do pod e a potencia.
6. O Mega aceita o comando somente com RC saudavel e CH3 fisicamente em AUTO. Cada comando vale 500 ms.
7. Ao atingir a tolerancia do ultimo waypoint, a Raspberry envia potencia zero e conclui a missao.

## Modos do CH3

| Pulso | Modo | Quem controla |
| ---: | --- | --- |
| menor que 1300 us | MANUAL | CH1 e CH2 do receptor |
| 1300 a 1700 us | RECORD | CH1/CH2; Pi grava a trajetoria |
| maior que 1700 us | AUTO | Raspberry, somente com comando fresco |
| ausente/invalido | FAILSAFE | ESC parado e pods retornando ao seguro |

Trocar de AUTO para MANUAL invalida o comando armazenado e para de usar a Raspberry imediatamente. GPS invalido em AUTO tambem para o ESC. Perda de RC, timeout de comando, agua e bateria critica aparecem nos alarmes.

## Calibracao antes de colocar na agua

- Remova a helice ou desconecte o motor.
- Confirme que `SERVO1/2_MIN_US`, `MAX_US` e `INVERTED` correspondem a montagem mecanica.
- Confirme centro de frente em 45 graus e centro de re em 225 graus.
- Teste CH3: MANUAL, RECORD, AUTO e retorno instantaneo para MANUAL.
- Em AUTO sem Raspberry, confirme ESC em 1000 us e pods caminhando para 45 graus.
- Envie um comando e interrompa o USB; o ESC deve parar em no maximo 500 ms.
- Cubra a antena do GPS; AUTO nao pode movimentar o motor sem posicao valida.
- Valide primeiro em cavalete, depois em baixa potencia com cabo de seguranca e so entao em campo aberto.

## Limites atuais

O ADXL345 mede inclinacao e aceleracao, mas nao fornece rumo. Em movimento, o piloto usa o `course_deg` do GPS; em velocidade muito baixa, esse rumo pode oscilar. Para manobras precisas a partir do repouso, adicione magnetometro/IMU calibrado. O aplicativo mostra uma visualizacao 3D aproximada de roll e pitch derivada da gravidade medida pelo ADXL345.

O download de missao usa a API HTTP. Uma rota ja salva continua offline, mas enviar uma rota nova a dois quilometros exige conectividade IP com a Raspberry ou uma futura implementacao de downlink LoRaWAN fragmentado e autenticado.
