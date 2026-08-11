#!/bin/sh
# Consulta local e estritamente read-only das mensagens recentes do grupo
# "Suporte Base Software" (contrato de consultoria CIPA / ERP Base Condomínio).
# Uso: wacli-base [dias]   (padrao: 1 dia)
# Garantias: nunca envia mensagem, nunca marca como lida, nunca muta o store
# local (WACLI_READONLY=1).
set -eu

: "${WACLI_STORE_DIR:=/home/cerbero/.openclaw/state/wacli}"
export WACLI_STORE_DIR WACLI_READONLY=1

# JID confirmado em 11/08/2026 via `wacli groups list`.
CHAT_JID="120363420555956896@g.us"

days="${1:-1}"
case "$days" in
  *[!0-9]*|'') echo "uso: wacli-base [dias]" >&2; exit 2 ;;
esac

after="$(date -u -d "$days days ago" +%Y-%m-%d)"

# 1) Busca por nome no indice de grupos (fallback para mudanca de JID).
chat_json="$(wacli --json groups list --limit 200 2>/dev/null || true)"
resolved="$(printf '%s' "$chat_json" | jq -r '[.. | objects | select((.Name? // "") | ascii_downcase | contains("suporte base software")) | .JID] | first // empty' 2>/dev/null || true)"

# 2) Fallback: JID conhecido.
[ -n "$resolved" ] || resolved="$CHAT_JID"

if [ -z "$resolved" ]; then
  echo "grupo 'Suporte Base Software' ainda não encontrado no índice local" >&2
  exit 3
fi

exec wacli --read-only --json messages list --chat "$resolved" --after "$after" --limit 300
