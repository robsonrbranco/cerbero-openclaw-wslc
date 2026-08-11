#!/bin/sh
# Consulta local e estritamente read-only das mensagens recentes do grupo.
# O primeiro argumento pode sobrescrever a janela (padrao: 3 dias).
set -eu

: "${WACLI_STORE_DIR:=/home/cerbero/.openclaw/state/wacli}"
export WACLI_STORE_DIR WACLI_READONLY=1

days="${1:-3}"
case "$days" in
  *[!0-9]*|'') echo "uso: wacli-sampaio [dias]" >&2; exit 2 ;;
esac

after="$(date -u -d "$days days ago" +%Y-%m-%d)"
chat_json="$(wacli --json chats list --query 'Condições de voo sampaio' --limit 10)"

# A busca por nome pode variar em acentuacao conforme o dado recebido do
# WhatsApp. Se nao houver correspondencia exata, tenta a parte estavel do nome.
chat_jid="$(printf '%s' "$chat_json" | jq -r '
  [.. | objects | select((.name? // .display_name? // "") | ascii_downcase | contains("condições de voo sampaio")) | (.jid? // .id?)]
  | map(select(. != null)) | first // empty')"
if [ -z "$chat_jid" ]; then
  chat_json="$(wacli --json chats list --query 'voo sampaio' --limit 10)"
  chat_jid="$(printf '%s' "$chat_json" | jq -r '[.. | objects | (.jid? // .id?) | select(. != null)] | first // empty')"
fi

if [ -z "$chat_jid" ]; then
  echo "grupo 'Condições de voo sampaio' ainda não encontrado no índice local" >&2
  exit 3
fi

exec wacli --read-only --json messages list --chat "$chat_jid" --after "$after" --limit 200
