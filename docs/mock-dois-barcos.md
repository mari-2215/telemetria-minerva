# Mock com Azimutal e Netuno

O comando `minerva-dual-mock` publica dois barcos simultaneamente na mesma API:

- `azimutal-01`: propulsor azimutal, retorno feito girando o pod de 45° para aproximadamente 225°;
- `netuno-01`: barco convencional de leme e motor reversível, retorno feito parando o motor e selecionando ré.

## Iniciar

Em um terminal, suba a API:

```bash
cd ~/telemetria-minerva
source .venv/bin/activate
export MINERVA_DEVICE_TOKEN=dev-device-token
minerva-api
```

Em outro terminal:

```bash
cd ~/telemetria-minerva
source .venv/bin/activate
export MINERVA_DEVICE_TOKEN=dev-device-token
minerva-dual-mock
```

Os dois barcos começam em `AUTO`, com o latch desligado. Selecione uma rota no aplicativo e acione o latch no terminal:

```text
latch azimutal
latch netuno
```

O popup do aplicativo só aparece depois dessa transição.

## Comandos

```text
latch azimutal|netuno|all
latch azimutal|netuno|all on|off
mode azimutal|netuno|all auto|manual
waves 0.0..2.0
status
help
quit
```

`waves` aumenta ou reduz roll, pitch e acelerações simuladas. Acima de certo nível, o piloto reduz potência pelo limitador de estabilidade do ADXL; em condição extrema, o comando vai para potência zero.

## Ida e volta

Para testar uma trajetória de ida e volta, crie três destinos aproximadamente alinhados:

1. um ponto à frente;
2. o ponto de retorno;
3. um ponto próximo do primeiro.

No Azimutal, o pod gira para a direção oposta antes de voltar a acelerar. No Netuno, o mock para, espera o intertravamento e inicia a ré com o sinal do leme corrigido para navegação em marcha a ré.
