# Autonomia, gravação e rotas

## Fluxo completo

1. Crie ou grave uma rota no aplicativo.
2. A Raspberry baixa a missão e a mantém no SQLite local.
3. O Mega permanece em MANUAL enquanto o latch físico CH1 estiver desligado.
4. Um acionamento do CH1 alterna o latch para AUTO.
5. O ESC continua parado até existir GPS válido e comando fresco da Raspberry.
6. Perda do CH1, dos canais RC, do GPS, do USB ou do watchdog para o ESC.
7. Um novo acionamento do CH1 cancela AUTO imediatamente.

## Mapa do receptor no Azimutal

| Canal | Mega | Função |
| ---: | ---: | --- |
| CH4 | D2 | Movimento horizontal conjunto dos dois pods, ±45° |
| CH3 | D3 | Seleção travada FRENTE/RÉ; não controla o ESC |
| CH2 | D18 | Potência manual |
| CH1 | D19 | Latch físico START/STOP do piloto automático |

O CH3 é dedicado somente à seleção travada FRENTE/RÉ dos pods.
A gravação de trajetória é iniciada e encerrada pelo app e executada pelo
backend, independentemente dos canais RC.

Ao retornar ao manual, CH2 precisa permanecer neutro por 500 ms antes de o
firmware liberar novamente o ESC.

## Dois servos azimutais

Os sinais saem do Mega em D9 e D11. Os servos não são ligados ao receptor:
usam BEC/fonte externa e GND comum com Arduino, receptor e ESC. O firmware
aplica o mesmo ângulo lógico e permite inversão individual para montagem
espelhada.

## Calibração

- Remova a hélice ou desconecte o motor.
- Teste CH4 e confirme os dois pods acompanhando o movimento.
- Teste CH3 com CH2 neutro e confirme FRENTE/RÉ após 180 ms.
- Mantenha CH2 neutro por pelo menos 500 ms após ligar.
- Teste CH1: primeiro acionamento arma AUTO; o seguinte desarma.
- Em AUTO sem Raspberry ou GPS, o ESC deve permanecer em 1500 us.
- Interrompa o USB durante um comando e confirme a parada pelo watchdog.
