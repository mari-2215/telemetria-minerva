#!/usr/bin/env bash
set -euo pipefail

ACCESS_ENV="${MINERVA_ACCESS_ENV:-$HOME/.config/minerva/access.env}"

if [[ ! -f "$ACCESS_ENV" ]]; then
  echo "ERRO: credenciais não encontradas em $ACCESS_ENV" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ACCESS_ENV"
exec minerva-api "$@"
