#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_LOG="${TMPDIR:-/tmp}/minerva-api.log"
MOCK_LOG="${TMPDIR:-/tmp}/minerva-mock.log"
GATEWAY_LOG="${TMPDIR:-/tmp}/minerva-gateway.log"
API_PID=""; MOCK_PID=""; GATEWAY_PID=""

cleanup() {
  trap - EXIT INT TERM
  echo
  echo "Encerrando API, mock e aplicativo..."
  for pid in "$GATEWAY_PID" "$MOCK_PID" "$API_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$REPO_DIR"
[[ -x .venv/bin/python ]] || { echo "ERRO: .venv não encontrada" >&2; exit 1; }

fuser -k 8080/tcp 8765/tcp 2>/dev/null || true
sleep 1

source .venv/bin/activate
export MINERVA_DEVICE_TOKEN="${MINERVA_DEVICE_TOKEN:-dev-device-token}"
ACCESS_ENV="${MINERVA_ACCESS_ENV:-$HOME/.config/minerva/access.env}"
[[ -f "$ACCESS_ENV" ]] || { echo "ERRO: $ACCESS_ENV não existe" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ACCESS_ENV"

echo "Construindo aplicativo..."
(
  cd app
  flutter pub get
  flutter clean
  flutter build web --release
)

echo "Ligando API..."
MINERVA_BIND=127.0.0.1 MINERVA_PORT=8080 minerva-api >"$API_LOG" 2>&1 &
API_PID=$!
for _ in $(seq 1 40); do
  curl -fsS http://127.0.0.1:8080/docs >/dev/null 2>&1 && break
  kill -0 "$API_PID" 2>/dev/null || { cat "$API_LOG" >&2; exit 1; }
  sleep 0.25
done
curl -fsS http://127.0.0.1:8080/docs >/dev/null || { cat "$API_LOG" >&2; exit 1; }

echo "Ligando os dois barcos simulados..."
MINERVA_API_URL=http://127.0.0.1:8080 MINERVA_DEVICE_TOKEN="$MINERVA_DEVICE_TOKEN" \
  minerva-dual-mock >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!

echo "Ligando aplicativo e gateway..."
python3 scripts/minerva_web_gateway.py \
  --web-dir app/build/web --listen 127.0.0.1 --port 8765 \
  --api-host 127.0.0.1 --api-port 8080 >"$GATEWAY_LOG" 2>&1 &
GATEWAY_PID=$!
for _ in $(seq 1 40); do
  curl -fsS http://127.0.0.1:8765/api/docs >/dev/null 2>&1 && break
  kill -0 "$GATEWAY_PID" 2>/dev/null || { cat "$GATEWAY_LOG" >&2; exit 1; }
  sleep 0.25
done
curl -fsS http://127.0.0.1:8765/api/docs >/dev/null || { cat "$GATEWAY_LOG" >&2; exit 1; }

echo
echo "============================================================"
echo "MINERVA PRONTA — TUDO EM UM ÚNICO ENDEREÇO"
echo "============================================================"
echo "Aplicativo:       http://127.0.0.1:8765"
echo "Servidor no login: http://127.0.0.1:8765/api"
echo "QR capitão: $HOME/Downloads/minerva-access-qr/capitao.png"
echo
echo "Ctrl+C neste terminal desliga tudo."

xdg-open "http://127.0.0.1:8765/?v=$(date +%s)" >/dev/null 2>&1 || true
wait "$GATEWAY_PID"
