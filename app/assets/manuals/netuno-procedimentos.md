# Netuno — Manual de Procedimentos

> Manual inicial para barco com leme e ESC reversível. Neutro, vante, ré e limites do leme precisam ser calibrados no Netuno real.

## Antes de energizar

1. Confirme hélice, eixo e leme livres.
2. Inspecione servo, link, horn, batentes e alinhamento do leme.
3. Confira ESC reversível, motor, bateria, fusível e vedação.
4. Ligue primeiro o transmissor com acelerador neutro.

## Inicialização

1. Aguarde Arduino e Raspberry Pi iniciarem.
2. No aplicativo, selecione netuno-01.
3. Verifique RC, GPS, bateria, temperatura e sensor de água.
4. Teste leme, vante e ré separadamente e em baixa potência.

## Operação manual

- Toda mudança vante-ré passa pelo neutro.
- Aguarde o tempo de proteção do ESC antes de aplicar potência oposta.
- Em ré, a ação efetiva do leme é invertida.
- Não aplique potência alta com o leme no batente.

## Gravação e piloto automático

1. Inicie a gravação e mova o barco em até cinco segundos.
2. Com até dois pontos sem novo movimento, a gravação é descartada.
3. Revise a rota e evite manobras impossíveis perto de obstáculos.
4. Envie a rota, coloque em AUTO e acione o latch.
5. Confirme a partida no perfil de capitão.
6. Em retorno, o motor reduz, permanece em neutro e só depois entra em ré.
7. Durante a ré, o controlador inverte a ação do leme.
8. Mantenha o rádio pronto para assumir em MANUAL.

## Emergência e encerramento

- Volte a MANUAL em trajetória incorreta, leme travado ou inversão brusca.
- Cancele o latch para impedir novos comandos.
- Em falha de RC, GPS ou comando, o motor deve parar.
- Ao encerrar: MANUAL, leme central, neutro, latch desligado e bateria desconectada.
