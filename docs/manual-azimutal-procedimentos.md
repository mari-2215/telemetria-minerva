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
2. Mantenha CH2 neutro e confirme a área livre.
3. Acione o latch CH1; o motor continua parado até GPS e comando fresco.
4. CH3 permanece dedicado à seleção manual FRENTE/RÉ.
5. Confirme os dois servos em D9 e D11 acompanhando o mesmo ângulo.
6. Acione novamente CH1 para cancelar AUTO.

## Emergência e encerramento

- Acione novamente o latch CH1 ou use a parada física em resposta inesperada.
- Alterne o latch CH1 para cancelar comandos automáticos.
- Em perda de RC, GPS ou comando fresco, o ESC deve ir à parada.
- Em água, fumaça, cheiro ou aquecimento anormal, desligue a alimentação.
- Ao encerrar: CH1 desarmado, CH2 neutro, retirar da água e desconectar a bateria.
