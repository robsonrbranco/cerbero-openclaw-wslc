#!/usr/bin/env bash
set -euo pipefail

ZOHO_ACCOUNTS_URL="https://accounts.zoho.com"
ZOHO_MAIL_API="https://mail.zoho.com/api"

_require_env() {
  for v in ZOHO_CLIENT_ID ZOHO_CLIENT_SECRET ZOHO_REFRESH_TOKEN ZOHO_ACCOUNT_ID; do
    if [ -z "${!v:-}" ]; then
      echo "erro: env var $v nao definida" >&2
      exit 1
    fi
  done
}

_access_token() {
  curl -s -X POST "${ZOHO_ACCOUNTS_URL}/oauth/v2/token" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=${ZOHO_CLIENT_ID}" \
    --data-urlencode "client_secret=${ZOHO_CLIENT_SECRET}" \
    --data-urlencode "refresh_token=${ZOHO_REFRESH_TOKEN}" \
    | jq -r '.access_token'
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

_require_env

case "${1:-}" in
  folders) cmd_folders ;;
  list) shift; cmd_list "$@" ;;
  read) shift; cmd_read "$@" ;;
  draft) shift; cmd_draft "$@" ;;
  *) echo "uso: zoho-mail {folders|list [--unread] [--limit N] [--folder Nome]|read <folderId> <messageId>|draft --to X --subject Y --body Z [--cc W]}" >&2; exit 1 ;;
esac
