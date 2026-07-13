#!/bin/bash
# bootstrap-gog.sh — Restaura CLI gog (Google Workspace) após rebuild
# Chamado pelo setup-cerbero-wslc.ps1 durante bootstrap
# Dados persistentes em /home/cerbero/.openclaw/state/gogcli/
# Binário em /home/cerbero/.openclaw/extensions/gog

set -e

GOG_STATE=/home/cerbero/.openclaw/state/gogcli
GOG_BIN_SRC=/home/cerbero/.openclaw/extensions/gog
GOG_BIN_DST=/usr/local/bin/gog
KEYRING_PASS_FILE=$GOG_STATE/keyring-password.txt
GOG_ENV_FILE=/etc/profile.d/gog.sh

echo "== bootstrap-gog: restaurando Google Workspace CLI =="

# 1. Copiar binário gog
if [ -f "$GOG_BIN_SRC" ]; then
    cp "$GOG_BIN_SRC" "$GOG_BIN_DST"
    chmod +x "$GOG_BIN_DST"
    echo "✅ gog v$($GOG_BIN_DST --version 2>/dev/null) restaurado"
else
    echo "⚠️  Baixando gog via GitHub..."
    curl -sL "https://api.github.com/repos/openclaw/gogcli/releases/latest" \
        | grep browser_download_url \
        | grep linux_amd64 \
        | head -1 \
        | cut -d'"' -f4 \
        | xargs curl -sL \
        | tar xz -C /tmp/
    cp /tmp/gog "$GOG_BIN_DST"
    cp /tmp/gog "$GOG_BIN_SRC"
    chmod +x "$GOG_BIN_DST" "$GOG_BIN_SRC"
    echo "✅ gog baixado e instalado"
fi

# 2. Garantir senha do keyring persistente
if [ -f "$KEYRING_PASS_FILE" ]; then
    GOG_KEYRING_PASSWORD=$(cat "$KEYRING_PASS_FILE")
    echo "✅ Keyring password lida do arquivo persistente"
else
    GOG_KEYRING_PASSWORD="gog-cerbero-$(openssl rand -hex 6 2>/dev/null || date +%s)"
    echo "$GOG_KEYRING_PASSWORD" > "$KEYRING_PASS_FILE"
    chmod 600 "$KEYRING_PASS_FILE"
    echo "✅ Keyring password gerada e salva"
fi

# 3. Config vars de ambiente globais
mkdir -p /etc/profile.d
cat > "$GOG_ENV_FILE" << EOF
export GOG_HOME=$GOG_STATE
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=$GOG_KEYRING_PASSWORD
EOF
chmod +x "$GOG_ENV_FILE"
echo "✅ Env vars configuradas em $GOG_ENV_FILE"

# 4. Aplicar no shell atual
export GOG_HOME=$GOG_STATE
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=$GOG_KEYRING_PASSWORD

# 5. Verificar se a autenticação funciona
if [ -f "$GOG_STATE/config/config.json" ]; then
    HEALTH=$($GOG_BIN_DST auth doctor --check --no-input 2>&1 | grep -c "ok" || true)
    echo "✅ gog auth doctor: $HEALTH checks ok"
    $GOG_BIN_DST auth status 2>&1 | grep account || true
else
    echo "⚠️  Config do gog não encontrada — execute OAuth manualmente:"
    echo "   gog auth credentials <client_secret.json>"
    echo "   gog auth add <email> --services gmail,calendar"
fi

echo "== bootstrap-gog concluído =="
