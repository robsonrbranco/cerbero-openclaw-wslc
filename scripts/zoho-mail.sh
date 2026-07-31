#!/usr/bin/env bash
set -euo pipefail

ZOHO_ACCOUNTS_URL="https://accounts.zoho.com"
ZOHO_MAIL_API="https://mail.zoho.com/api"
ZOHO_SEND_ALLOWED_TO="raquelprosadecastro@gmail.com"

_require_env() {
  for v in ZOHO_CLIENT_ID ZOHO_CLIENT_SECRET ZOHO_REFRESH_TOKEN ZOHO_ACCOUNT_ID; do
    if [ -z "${!v:-}" ]; then
      echo "erro: env var $v nao definida" >&2
      exit 1
    fi
  done
}

# Cacheia o access token (dura ~1h do lado do Zoho) num arquivo no volume
# persistente, evitando renovar a cada chamada -- renovar demais esbarra
# no rate-limit do endpoint OAuth do Zoho (ver LICOES-APRENDIDAS.md item 27).
_token_cache_file() {
  echo "${OPENCLAW_STATE_DIR:-/home/cerbero/.openclaw}/zoho-token-cache.json"
}

_access_token() {
  local cache; cache=$(_token_cache_file)
  local now; now=$(date +%s)

  if [ -f "$cache" ]; then
    local cached_token cached_exp
    cached_token=$(jq -r '.access_token // empty' "$cache" 2>/dev/null || true)
    cached_exp=$(jq -r '.expires_at // 0' "$cache" 2>/dev/null || echo 0)
    # Margem de 60s antes do vencimento real, pra nunca usar um token que
    # expira no meio de uma chamada em andamento.
    if [ -n "$cached_token" ] && [ "$cached_exp" -gt "$((now + 60))" ] 2>/dev/null; then
      echo "$cached_token"
      return 0
    fi
  fi

  local resp
  resp=$(curl -s -X POST "${ZOHO_ACCOUNTS_URL}/oauth/v2/token" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=${ZOHO_CLIENT_ID}" \
    --data-urlencode "client_secret=${ZOHO_CLIENT_SECRET}" \
    --data-urlencode "refresh_token=${ZOHO_REFRESH_TOKEN}")

  local token expires_in
  token=$(echo "$resp" | jq -r '.access_token // empty')
  expires_in=$(echo "$resp" | jq -r '.expires_in // empty')

  if [ -z "$token" ]; then
    echo "erro: falha ao renovar token OAuth do Zoho -- $(echo "$resp" | jq -c '.' 2>/dev/null || echo "$resp")" >&2
    exit 1
  fi

  local exp=$((now + ${expires_in:-3600}))
  jq -n --arg t "$token" --argjson e "$exp" '{access_token:$t, expires_at:$e}' > "$cache" 2>/dev/null || true
  chmod 600 "$cache" 2>/dev/null || true
  echo "$token"
}

_folder_id() {
  local name="${1:-Inbox}"
  local token; token=$(_access_token)
  curl -s "${ZOHO_MAIL_API}/accounts/${ZOHO_ACCOUNT_ID}/folders" \
    -H "Authorization: Zoho-oauthtoken ${token}" \
    | jq -r --arg n "$name" '.data[] | select(.folderName==$n) | .folderId'
}

cmd_folders() {
  local token; token=$(_access_token)
  curl -s "${ZOHO_MAIL_API}/accounts/${ZOHO_ACCOUNT_ID}/folders" \
    -H "Authorization: Zoho-oauthtoken ${token}" \
    | jq -r '.data[] | "\(.folderId)\t\(.folderName)\t\(.folderType)"'
}

cmd_list() {
  local unread="" limit=10 folder="Inbox"
  while [ $# -gt 0 ]; do
    case "$1" in
      --unread) unread="&status=unread" ;;
      --limit) limit="$2"; shift ;;
      --folder) folder="$2"; shift ;;
    esac
    shift
  done
  local fid; fid=$(_folder_id "$folder")
  local token; token=$(_access_token)
  curl -s "${ZOHO_MAIL_API}/accounts/${ZOHO_ACCOUNT_ID}/messages/view?folderId=${fid}&limit=${limit}${unread}&sortBy=date&sortorder=false" \
    -H "Authorization: Zoho-oauthtoken ${token}" \
    | jq -r '.data[] | "\(.messageId)\t\(.receivedTime)\t\(.sender)\t\(.subject)"'
}

cmd_read() {
  local folder_id="$1" message_id="$2"
  local token; token=$(_access_token)
  curl -s "${ZOHO_MAIL_API}/accounts/${ZOHO_ACCOUNT_ID}/folders/${folder_id}/messages/${message_id}/content" \
    -H "Authorization: Zoho-oauthtoken ${token}"
}

cmd_draft() {
  local to="" subject="" body="" cc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="$2"; shift ;;
      --subject) subject="$2"; shift ;;
      --body) body="$2"; shift ;;
      --cc) cc="$2"; shift ;;
    esac
    shift
  done
  local token; token=$(_access_token)
  local payload
  payload=$(jq -n --arg to "$to" --arg subj "$subject" --arg body "$body" --arg cc "$cc" \
    '{mode:"draft", fromAddress:"contato@ecomciencia.com", toAddress:$to, subject:$subj, content:$body} + (if $cc != "" then {ccAddress:$cc} else {} end)')
  curl -s -X POST "${ZOHO_MAIL_API}/accounts/${ZOHO_ACCOUNT_ID}/messages" \
    -H "Authorization: Zoho-oauthtoken ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

# cmd_send: envia e-mail de verdade (mode:"send", nao rascunho).
# Uso restrito a remetentes especiais com autonomia explicita aprovada em
# MEMORY.md (ex.: raquelprosadecastro@gmail.com) -- ver AGENTS.md "Rascunho
# de E-mail": para qualquer outro destinatario, o envio continua sendo
# SEMPRE acao humana (usar cmd_draft).
cmd_send() {
  local to="" subject="" body="" cc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="$2"; shift ;;
      --subject) subject="$2"; shift ;;
      --body) body="$2"; shift ;;
      --cc) cc="$2"; shift ;;
    esac
    shift
  done
  if [ "$to" != "$ZOHO_SEND_ALLOWED_TO" ]; then
    echo "erro: send restrito a ${ZOHO_SEND_ALLOWED_TO} -- para qualquer outro destinatario use 'draft'" >&2
    exit 1
  fi
  local token; token=$(_access_token)
  local payload
  payload=$(jq -n --arg to "$to" --arg subj "$subject" --arg body "$body" --arg cc "$cc" \
    '{mode:"send", fromAddress:"contato@ecomciencia.com", toAddress:$to, subject:$subj, content:$body} + (if $cc != "" then {ccAddress:$cc} else {} end)')
  curl -s -X POST "${ZOHO_MAIL_API}/accounts/${ZOHO_ACCOUNT_ID}/messages" \
    -H "Authorization: Zoho-oauthtoken ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

_require_env

case "${1:-}" in
  folders) cmd_folders ;;
  list) shift; cmd_list "$@" ;;
  read) shift; cmd_read "$@" ;;
  draft) shift; cmd_draft "$@" ;;
  send) shift; cmd_send "$@" ;;
  *) echo "uso: zoho-mail {folders|list [--unread] [--limit N] [--folder Nome]|read <folderId> <messageId>|draft --to X --subject Y --body Z [--cc W]|send --to X --subject Y --body Z [--cc W]}" >&2; exit 1 ;;
esac
