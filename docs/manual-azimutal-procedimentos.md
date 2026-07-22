# Azimutal — Manual de Procedimentos

> Documento operacional inicial. Valide em bancada e em água abrigada antes de ensaios oficiais. O controle RC e a parada de emergência têm prioridade sobre o piloto automático.

## Antes de energizar

1. Confirme hélices livres e área sem pessoas próximas.
2. Inspecione servos, pod, acoplamentos, cabos e batentes.
3. Verifique bateria, fusível, ESC, Arduino, Raspberry Pi e vedação.
4. Confirme GPS, rádio, antenas, sensor de água e ADXL345 firmes.
5. Ligue primeiro o transmissor com acelerador neutro.

## Inicialização

1. Aguarde Arduino e Raspberry Pi iniciarem.
2. Abra o aplicativo e selecione azimutal-01.
3. Confira RC saudável, GPS válido, bateria e ausência de água.
4. Faça teste breve e de baixa potência em modo manual.

## Operação manual

- Vante usa o centro azimutal calibrado próximo de 45 graus.
- Ré usa o centro próximo de 225 graus.
- Ao inverter, passe pelo neutro e espere o pod alinhar antes de acelerar.
- Corte a potência se houver vibração, batente ou resposta divergente.

## Gravação de rota

1. Toque em Gravar rota no perfil de capitão.
2. Inicie o deslocamento em até cinco segundos.
3. Com até dois pontos e cinco segundos sem ponto novo, a gravação é descartada.
4. Ao terminar, toque em Parar e salvar rota e revise a trajetória.

## Piloto automático

1. Envie a rota e confira o minimapa.
2. Coloque o rádio em AUTO; o motor deve continuar parado.
3. Acione fisicamente o latch.
4. Confirme a partida somente com GPS, RC e área livres.
5. Em retorno de 180 graus, o motor para enquanto o pod gira para a orientação de ré.
6. O ADXL345 reduz potência em inclinação ou aceleração excessiva.
7. Mantenha o operador pronto para retornar a MANUAL.

## Emergência e encerramento

- Retorne imediatamente a MANUAL em resposta inesperada.
- Solte ou alterne o latch para cancelar comandos automáticos.
- Em perda de RC, GPS ou comando fresco, o ESC deve ir à parada.
- Em água, fumaça, cheiro ou aquecimento anormal, desligue a alimentação.
- Ao encerrar: MANUAL, neutro, latch desligado, retirar da água e desconectar bateria.
