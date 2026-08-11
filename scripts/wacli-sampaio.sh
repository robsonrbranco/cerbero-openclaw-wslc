#!/bin/sh
# Consulta local e estritamente read-only das mensagens recentes do grupo
# "Condições de voo sampaio" (postagens do Werneck sobre condições de voo
# e estradas de acesso).
# Uso: wacli-sampaio [dias]   (padrao: 3 dias)
# Garantias: nunca envia mensagem, nunca marca como lida, nunca muta o store
# local (WACLI_READONLY=1).
set -eu

: "${WACLI_STORE_DIR:=/home/cerbero/.openclaw/state/wacli}"
export WACLI_STORE_DIR WACLI_READONLY=1

# JID confirmado em 11/08/2026 via `wacli groups list` (nome do grupo tem
# sufixo de emojis, o que quebra o --query do `chats list`). JID de grupo e
# estavel; usado como fallback se a busca por nome falhar.
CHAT_JID="5522998070904-1478002525@g.us"

days="${1:-3}"
case "$days" in
  *[!0-9]*|'') echo "uso: wacli-sampaio [dias]" >&2; exit 2 ;;
esac

after="$(date -u -d "$days days ago" +%Y-%m-%d)"

# 1) Busca por nome no indice de grupos.
chat_json="$(wacli --json groups list --limit 200 2>/dev/null || true)"
chat_jid="$(printf '%s' "$chat_json" | jq -r '[.. | objects | select((.Name? // "") | ascii_downcase | contains("sampaio")) | .JID] | first // empty' 2>/dev/null || true)"

# 2) Fallback: JID conhecido.
[ -n "$chat_jid" ] || chat_jid="$CHAT_JID"

if [ -z "$chat_jid" ]; then
  echo "grupo 'Condições de voo sampaio' ainda não encontrado no índice local" >&2
  exit 3
fi

exec wacli --read-only --json messages list --chat "$chat_jid" --after "$after" --limit 200
