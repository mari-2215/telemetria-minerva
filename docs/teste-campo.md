# Plano de validacao

Nenhuma etapa de alcance deve ocorrer antes da aprovacao de bancada e do fail-safe do controle RC.

## 1. Bancada eletrica

- motor desconectado;
- conferir 12 V, 5,1 V e 3,3 V com carga;
- ligar/desligar ESC e servo repetidamente e confirmar ausencia de reset ou `undervoltage` no Pi;
- medir corrente de repouso e pico;
- validar botao de emergencia por corte de hardware;
- executar telemetria por 2 h sem perda de processo ou corrupcao do SQLite.

Criterio: zero reset, zero perda de RC causada pela telemetria e zero erro de filesystem.

## 2. Calibracao

- tensao: cinco pontos contra multimetro de referencia;
- corrente: zero + pelo menos quatro cargas conhecidas;
- LM35/SHT31: comparacao em duas temperaturas;
- ADXL345: offsets por eixo e orientacao no casco;
- GPS: fix parado de 20 min e trajeto conhecido;
- sensor de agua: seco, respingo e contato continuo.

Guardar coeficientes, data, instrumento e responsavel por embarcacao.

## 3. Enlace progressivo

Em cada distancia (100 m, 500 m, 1 km e 2 km), permanecer pelo menos 10 min e registrar:

- RSSI e SNR minimo/mediano/p95;
- pacotes transmitidos, recebidos e duplicados;
- latencia mediana e p95;
- orientacao e inclinacao do barco;
- altura e tipo das duas antenas;
- clima, ondas e obstrucoes.

Criterios iniciais em 2 km:

- entrega bruta >= 95% em janela de 10 min;
- latencia p95 <= 5 s para telemetria normal;
- nenhum alarme critico perdido quando repetido tres vezes;
- margem de enlace sem quedas prolongadas ao girar o barco 360 graus.

## 4. Falhas induzidas

1. Desligar internet do gateway por 30 min: dados locais continuam e sincronizam depois.
2. Desligar LoRa: Pi grava localmente e o controle continua normal.
3. Desligar Raspberry Pi: Arduino mantem controle e fail-safe.
4. Retirar GPS/ADXL/DHT individualmente: alarme identifica sensor sem travar aquisicao.
5. Simular bateria baixa com fonte limitada: alarme precede desligamento.
6. Acionar sensor de agua: app e margem recebem prioridade critica.

## 5. Navegacao supervisionada

- primeiro ensaio com cabo/retencao ou area rasa;
- observador dedicado ao controle, outro a telemetria;
- barco de apoio e procedimento de resgate;
- checklist antes/depois e numero da versao de firmware registrado;
- exportar CSV/JSON e comparar trilha com observacao do laboratorio.

## Evidencias a arquivar

- logs brutos do Arduino, Pi, gateway e backend;
- banco SQLite original e exportacao;
- fotos da montagem e altura de antena;
- versoes/commits do firmware e servicos;
- planilha de calibracao;
- relatorio com PDR, latencia, RSSI/SNR e ocorrencias.

