<#
.SYNOPSIS
  Sobe o OpenClaw (DeepSeek + Gemini + Claude + WhatsApp) num unico container
  no WSL Containers (wslc.exe), sem depender de docker compose, e faz TODO o
  bootstrap (auth dos 3 provedores, prioridade de modelos, allowlist, canal
  WhatsApp, plugins) via CLI do proprio openclaw - script idempotente, pode
  rodar de novo a qualquer momento (rebuild de imagem, troca de chave, etc.)
  sem quebrar nada que ja estava configurado.

.NOTES
  wslc.exe roda no lado Windows (PowerShell/Windows Terminal) - nao precisa abrir
  uma distro WSL antes. Requer: wsl --update --pre-release (feature em preview).

  Este script NAO usa docker-compose porque, na preview atual do WSLC, suporte a
  Compose nao e uma capacidade documentada. Em vez disso, replica manualmente
  os volumes/portas que o docker-compose.yml oficial do OpenClaw define.

  Historico de decisao (por que tudo via CLI e nao um openclaw.json pre-escrito):
  em tentativas anteriores, a taxa de sucesso foi maior configurando tudo via
  "openclaw onboard"/"openclaw config set" depois que o container ja existe,
  em vez de pre-escrever o JSON de config e so montar. Esse script replica
  exatamente essa sequencia, na ordem que ja se mostrou confiavel: build ->
  volumes nomeados -> bootstrap via CLI (container descartavel) -> sobe o
  gateway com a config ja pronta.

.PARAMETER BaseDir
  Pasta no Windows onde ficam config/workspace/secrets do Cerbero (persistente,
  sobrevive a rebuild/update de imagem). Default: C:\wslc\data\cerbero - parte
  do layout agnostico (fonte em C:\wslc\projects\cerbero, dados em
  C:\wslc\data\cerbero), separado de qualquer pasta especifica de ferramenta.

.PARAMETER WhatsappNumber
  Numero pessoal usado no canal WhatsApp (dmPolicy allowlist + selfChatMode).

.EXAMPLE
  .\setup-cerbero-wslc.ps1
  .\setup-cerbero-wslc.ps1 -BaseDir D:\wslc\data\cerbero
#>

param(
    [string]$BaseDir = "C:\wslc\data\cerbero",
    [string]$ImageTag = "cerbero:local",
    [string]$ContainerName = "cerbero-gateway",
    [string]$WhatsappNumber = "+55SEUNUMERO"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "== $msg ==" -ForegroundColor Cyan
}

# --- 0. Pre-checagem: wslc disponivel? -------------------------------------
Write-Step "Verificando wslc.exe"
try {
    $null = wslc version
} catch {
    Write-Host "wslc.exe nao encontrado. Rode primeiro:" -ForegroundColor Red
    Write-Host "  wsl --update --pre-release" -ForegroundColor Yellow
    Write-Host "e reabra o PowerShell." -ForegroundColor Yellow
    exit 1
}

# --- 1. Pastas persistentes (config/workspace/secrets = equivalente aos bind mounts
# do docker-compose.yml oficial; logs e extra, para reter /tmp/openclaw entre recriacoes) ---
Write-Step "Preparando pastas em $BaseDir"
$ConfigDir    = Join-Path $BaseDir "config"      # -> /home/cerbero/.openclaw
$WorkspaceDir = Join-Path $BaseDir "workspace"    # -> /home/cerbero/.openclaw/workspace
$SecretDir    = Join-Path $BaseDir "secrets"      # -> /home/cerbero/.config/openclaw
$LogsDir      = Join-Path $BaseDir "logs"         # -> /tmp/openclaw (logs rolantes; util para debug futuro)

foreach ($d in @($ConfigDir, $WorkspaceDir, $SecretDir, $LogsDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "Criado: $d"
    }
}

# --- 2. Segredos (.env) ------------------------------------------------------
# openclaw.json NAO e mais pre-escrito a partir de um template - ele nasce do
# proprio "openclaw onboard" na fase de Bootstrap (secao 5), rodando dentro do
# container. Isso evita o bug de "Config write rejected: size-drop" que um
# JSON5 com comentarios causava, e reflete a forma que se provou mais
# confiavel no WSLC.
Write-Step "Segredos (.env)"

$EnvFile = Join-Path $BaseDir ".env"
if (-not (Test-Path $EnvFile)) {
    Copy-Item ".\.env.example" $EnvFile
    Write-Host ""
    Write-Host "Criei $EnvFile a partir do .env.example." -ForegroundColor Yellow
    Write-Host "Preencha ANTHROPIC_API_KEY, DEEPSEEK_API_KEY, GEMINI_API_KEY e OPENCLAW_GATEWAY_TOKEN," -ForegroundColor Yellow
    Write-Host "depois rode este script de novo." -ForegroundColor Yellow
    exit 0
}

# Carrega .env em variaveis (ignora comentarios/linhas vazias)
$EnvVars = @{}
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $k, $v = $line.Split("=", 2)
        $EnvVars[$k.Trim()] = $v.Trim()
    }
}
foreach ($required in @("ANTHROPIC_API_KEY","DEEPSEEK_API_KEY","GEMINI_API_KEY","OPENCLAW_GATEWAY_TOKEN")) {
    if (-not $EnvVars.ContainsKey($required) -or $EnvVars[$required] -match "^(sk-|AIza)?xxxx|troque-por") {
        Write-Host "Preencha um valor real para $required em $EnvFile antes de continuar." -ForegroundColor Red
        exit 1
    }
}

# Numero de WhatsApp: dado pessoal, NAO fica hardcoded no script (que e
# publico no GitHub) - o default do parametro e so um placeholder generico
# ("+55SEUNUMERO"). O valor de verdade vem do .env local (nunca commitado,
# ver .gitignore). So usa o parametro -WhatsappNumber se ele foi passado
# explicitamente na linha de comando (nesse caso, tem prioridade sobre o .env).
if (-not $PSBoundParameters.ContainsKey('WhatsappNumber') -and $EnvVars.ContainsKey('WHATSAPP_NUMBER') -and $EnvVars['WHATSAPP_NUMBER']) {
    $WhatsappNumber = $EnvVars['WHATSAPP_NUMBER']
}

$EnvArgs = @()
foreach ($k in $EnvVars.Keys) {
    # WHATSAPP_NUMBER so serve pra montar o bootstrap.patch.json5 abaixo - nao
    # precisa (nem deveria) virar variavel de ambiente dentro do container.
    if ($k -eq "WHATSAPP_NUMBER") { continue }
    $EnvArgs += @("-e", "$k=$($EnvVars[$k])")
}

# --- 3. Build da imagem ------------------------------------------------------
Write-Step "Build da imagem ($ImageTag)"
# --pull forca checar de novo o registry pela imagem base (ghcr.io/openclaw/
# openclaw:latest) em vez de reusar a camada em cache local - sem isso ja
# ficamos presos numa versao antiga do core (2026.6.11) enquanto o "latest"
# real ja estava em 2026.7.1, o que quebrou a instalacao do plugin do
# WhatsApp (exigia core mais novo que o da imagem cacheada).
wslc build --pull -t $ImageTag -f Dockerfile .
if ($LASTEXITCODE -ne 0) { Write-Host "Build falhou." -ForegroundColor Red; exit 1 }

# --- 4. Volumes nomeados (npm/agents/extensions/state) -----------------------
# Volume nomeado (nao bind mount do Windows) para tudo que o OpenClaw grava em
# runtime (plugins npm/extensions, auth-profile-store, state/sqlite). O
# virtiofs do WSLC reporta bind mounts de pastas do Windows como mode=777
# (NTFS nao tem bits de permissao Unix reais) e nao segura lock de sqlite
# direito - isso bloqueava plugins ("blocked plugin candidate: world-writable
# path"), quebrava o auth-profile-store ("auth store lock may be busy") e
# gerava o aviso "skipped permission hardening ... EPERM" em todo comando. Um
# volume nomeado fica em ext4 de verdade dentro da VM do WSLC, com permissoes
# Unix reais, e sobrevive a recriacoes do container - so nao aparece
# navegavel direto no Explorer do Windows.
Write-Step "Volumes nomeados"
$Volumes = @("cerbero-npm", "cerbero-agents", "cerbero-extensions", "cerbero-state")
foreach ($vol in $Volumes) {
    try { wslc volume create $vol 2>$null | Out-Null } catch {}
}

function Repair-VolumeOwnership {
    # Fresh volumes nascem com dono root, e o dono as vezes reseta pra root
    # entre execucoes (observado apos instalacoes de plugin que falham/limpam
    # arquivos parcialmente). Chamado antes de CADA fase que usa esses volumes
    # (bootstrap E subida do gateway), nao so uma vez.
    wslc run --rm --user root `
        -v cerbero-npm:/home/cerbero/.openclaw/npm `
        -v cerbero-agents:/home/cerbero/.openclaw/agents `
        -v cerbero-extensions:/home/cerbero/.openclaw/extensions `
        -v cerbero-state:/home/cerbero/.openclaw/state `
        --entrypoint chown $ImageTag -R cerbero:cerbero /home/cerbero/.openclaw/npm /home/cerbero/.openclaw/agents /home/cerbero/.openclaw/extensions /home/cerbero/.openclaw/state 2>$null | Out-Null
}

# Mounts compartilhados entre a fase de bootstrap (container descartavel) e o
# gateway (container de longa duracao) - precisam ser IDENTICOS nos dois para
# tudo que o bootstrap grava aparecer no gateway.
$SharedVolumeArgs = @(
    "-v", "${ConfigDir}:/home/cerbero/.openclaw",
    "-v", "cerbero-npm:/home/cerbero/.openclaw/npm",
    "-v", "cerbero-agents:/home/cerbero/.openclaw/agents",
    "-v", "cerbero-extensions:/home/cerbero/.openclaw/extensions",
    "-v", "cerbero-state:/home/cerbero/.openclaw/state",
    "-v", "${WorkspaceDir}:/home/cerbero/.openclaw/workspace",
    "-v", "${SecretDir}:/home/cerbero/.config/openclaw",
    "-v", "${LogsDir}:/tmp/openclaw"
)

function Invoke-Bootstrap {
    # Roda um comando avulso do openclaw num container descartavel que reusa
    # os mesmos volumes do gateway - mesmo padrao do cerbero-cli.ps1. Nao
    # aborta o script inteiro se um passo individual falhar (ex.: "models
    # fallbacks clear" quando ja esta vazio), so avisa e segue - o objetivo e
    # que rodar este script de novo seja sempre seguro (idempotente).
    param([Parameter(Mandatory = $true)][string[]]$OpenClawArgs)
    $ba = @("run", "--rm", "-i") + $SharedVolumeArgs + $EnvArgs + @("--entrypoint", "node", $ImageTag, "dist/index.js") + $OpenClawArgs
    wslc @ba
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  (codigo $LASTEXITCODE - ok se for so 'ja configurado'; confira o log acima se parecer outra coisa)" -ForegroundColor Yellow
    }
}

Write-Step "Corrigindo ownership dos volumes (antes do bootstrap)"
Repair-VolumeOwnership

# --- 5. Bootstrap via CLI (auth, modelos, canais, plugins) -------------------
# Ordem que se provou confiavel: autenticar os 3 provedores primeiro (isso ja
# cria o openclaw.json e instala os plugins de provider automaticamente),
# depois prioridade/allowlist de modelos, depois gateway/canais, depois
# plugins de canal (whatsapp) e por fim plugins.allow.
Write-Step "Bootstrap via CLI"

Write-Host "-- Autenticando provedores (onboard --non-interactive) --"
Invoke-Bootstrap @("onboard","--non-interactive","--mode","local","--auth-choice","anthropic-api-key","--anthropic-api-key",$EnvVars["ANTHROPIC_API_KEY"],"--skip-health","--accept-risk")
Invoke-Bootstrap @("onboard","--non-interactive","--mode","local","--auth-choice","deepseek-api-key","--deepseek-api-key",$EnvVars["DEEPSEEK_API_KEY"],"--skip-health","--accept-risk")
# Flag correta e "gemini-api-key" (nao "google-api-key") - confirmado em
# docs.openclaw.ai/providers/google. O nome do provider e "google", mas o
# auth-choice/flag do onboard usa o nome "gemini".
Invoke-Bootstrap @("onboard","--non-interactive","--mode","local","--auth-choice","gemini-api-key","--gemini-api-key",$EnvVars["GEMINI_API_KEY"],"--skip-health","--accept-risk")

Write-Host "-- Prioridade de modelos: DeepSeek V4 Flash > Gemini 3.5 Flash > Claude Haiku 4.5 --"
Invoke-Bootstrap @("models","set","deepseek/deepseek-v4-flash")
Invoke-Bootstrap @("models","fallbacks","clear")
Invoke-Bootstrap @("models","fallbacks","add","google/gemini-3.5-flash")
Invoke-Bootstrap @("models","fallbacks","add","anthropic/claude-haiku-4-5")

Write-Host "-- Aliases, gateway, WhatsApp e plugins.allow (via config patch --file) --"
# IMPORTANTE: "config set <path> <json>" passa o JSON como argumento de linha
# de comando - e o PowerShell 5.1 tem DOIS bugs de marshalling pra exe nativo
# nessa rota: (1) engole aspas duplas embutidas (contornavel escapando como
# \") e (2) quebra o argumento em pedacos onde houver ESPACO, mesmo dentro de
# um valor JSON "protegido" (aconteceu com aliases tipo "Opus 4.8" - deu
# "Too many arguments for this command"). Em vez de brigar com esse
# escaping, escrevemos o payload inteiro num arquivo .json5 (sem passar por
# nenhum parser de argumento nativo) e aplicamos com "config patch --file",
# que faz merge recursivo de objetos (equivalente ao --merge do config set,
# mas pra tudo de uma vez). O arquivo fica dentro do proprio ConfigDir
# (bind mount), entao tanto o PowerShell quanto o container enxergam o
# mesmo arquivo.
$BootstrapPatch = @"
{
  agents: {
    defaults: {
      models: {
        "deepseek/deepseek-v4-flash": { alias: "V4 Flash" },
        "google/gemini-3.5-flash": { alias: "3.5 Flash" },
        "anthropic/claude-haiku-4-5": { alias: "Haiku 4.5" },
        "google/gemini-3.1-pro-preview": { alias: "3.1 Pro" },
        "anthropic/claude-sonnet-4-6": { alias: "Sonnet 4.6" },
        // Refs reais da Anthropic/Google que nao aparecem em "models list
        // --all" (catalogo estatico embutido no plugin esta desatualizado),
        // mas funcionam via API ao vivo - ver docs.openclaw.ai/providers/anthropic
        // e /providers/google. Nao mexem no primary/fallback configurado acima.
        "anthropic/claude-opus-4-8": { alias: "Opus 4.8" },
        "anthropic/claude-fable-5": { alias: "Fable 5" },
        "anthropic/claude-sonnet-5": { alias: "Sonnet 5" },
        "google/gemini-3.1-flash-lite": { alias: "3.1 Flash-Lite" },
      },
    },
  },
  gateway: {
    bind: "lan",
    controlUi: {
      allowedOrigins: ["http://localhost:18789", "http://127.0.0.1:18789"],
    },
  },
  env: {
    OPENCLAW_DISABLE_BONJOUR: "1",
  },
  channels: {
    whatsapp: {
      dmPolicy: "allowlist",
      allowFrom: ["$WhatsappNumber"],
      selfChatMode: true,
      groupPolicy: "disabled",
      sendReadReceipts: true,
      reactionLevel: "minimal",
    },
  },
  plugins: {
    allow: ["whatsapp", "deepseek"],
  },
}
"@
$BootstrapPatchFile = Join-Path $ConfigDir "bootstrap.patch.json5"
Set-Content -Path $BootstrapPatchFile -Value $BootstrapPatch -Encoding utf8
Invoke-Bootstrap @("config","patch","--file","/home/cerbero/.openclaw/bootstrap.patch.json5")

Write-Host "-- Confirmando/atualizando plugin do WhatsApp (ClawHub) --"
# O plugin ja vem pre-instalado NA IMAGEM (ver Dockerfile) - um volume
# cerbero-extensions novo/vazio ja nasce com ele funcionando, sem depender de
# rede nesse momento. Aqui so tentamos uma atualizacao por cima, com
# backup/restore seguro: se a reinstalacao falhar (ex.: ClawHub passou a
# exigir um core mais novo que o desta imagem - ja aconteceu uma vez e
# deixou o WhatsApp inteiro fora do ar), restauramos a copia anterior em vez
# de ficar sem plugin nenhum.
wslc run --rm --user root `
    -v cerbero-extensions:/home/cerbero/.openclaw/extensions `
    --entrypoint sh $ImageTag -c "if [ -d /home/cerbero/.openclaw/extensions/whatsapp ]; then rm -rf /home/cerbero/.openclaw/extensions/whatsapp.bak; mv /home/cerbero/.openclaw/extensions/whatsapp /home/cerbero/.openclaw/extensions/whatsapp.bak; fi" 2>$null | Out-Null

Invoke-Bootstrap @("plugins","install","clawhub:@openclaw/whatsapp")
if ($LASTEXITCODE -eq 0) {
    wslc run --rm --user root `
        -v cerbero-extensions:/home/cerbero/.openclaw/extensions `
        --entrypoint rm $ImageTag -rf /home/cerbero/.openclaw/extensions/whatsapp.bak 2>$null | Out-Null
    Write-Host "  Plugin do WhatsApp confirmado/atualizado." -ForegroundColor Green
} else {
    wslc run --rm --user root `
        -v cerbero-extensions:/home/cerbero/.openclaw/extensions `
        --entrypoint sh $ImageTag -c "rm -rf /home/cerbero/.openclaw/extensions/whatsapp; if [ -d /home/cerbero/.openclaw/extensions/whatsapp.bak ]; then mv /home/cerbero/.openclaw/extensions/whatsapp.bak /home/cerbero/.openclaw/extensions/whatsapp; fi" 2>$null | Out-Null
    Write-Host "  Reinstalacao via ClawHub falhou - restaurada a versao anterior (nao ficamos sem WhatsApp)." -ForegroundColor Yellow
}

Write-Host "-- Configurando Google Workspace (gog CLI) --"
# bootstrap-gog.sh e um script SHELL, nao um comando do openclaw - precisa
# rodar com --entrypoint sh (ou bash), nunca via Invoke-Bootstrap (que sempre
# monta "--entrypoint node ... dist/index.js <args>" e tentaria rodar
# "openclaw bash ...", que nao existe - bug real: "Unknown command: openclaw
# bash").
$gogArgs = @("run", "--rm") + $SharedVolumeArgs + $EnvArgs + @("--entrypoint", "bash", $ImageTag, "/home/cerbero/.openclaw/workspace/wslc/bootstrap-gog.sh")
wslc @gogArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (codigo $LASTEXITCODE - confira o log do gog acima)" -ForegroundColor Yellow
}

Write-Step "Corrigindo ownership dos volumes (antes de subir o gateway)"
Repair-VolumeOwnership

# --- 6. (Re)inicia o container do gateway -----------------------------------
Write-Step "Subindo o gateway ($ContainerName)"

Write-Host "Parando/removendo container anterior (se existir)..."
try { wslc container stop $ContainerName 2>$null | Out-Null } catch {}
try { wslc container rm $ContainerName 2>$null | Out-Null } catch {}

# Portas: 18789 e o Control UI/API do Gateway; 18790 e a porta de bridge que o
# docker-compose.yml oficial tambem publica. Env vars fixas abaixo replicam o
# que o compose oficial fixa explicitamente (evita qualquer valor vazando de
# fora e apontando para caminho errado dentro do container - ver comentario
# do bug #77436 no docker-compose.yml do OpenClaw).
$runArgs = @(
    "run", "-d",
    "--name", $ContainerName,
    "-p", "18789:18789",
    "-p", "18790:18790",
    "-e", "TERM=xterm-256color",
    "-e", "OPENCLAW_HOME=/home/cerbero",
    "-e", "OPENCLAW_STATE_DIR=/home/cerbero/.openclaw",
    "-e", "OPENCLAW_CONFIG_PATH=/home/cerbero/.openclaw/openclaw.json",
    "-e", "OPENCLAW_CONFIG_DIR=/home/cerbero/.openclaw",
    "-e", "OPENCLAW_WORKSPACE_DIR=/home/cerbero/.openclaw/workspace",
    "-e", "GOG_HOME=/home/cerbero/.openclaw/state/gogcli",
    "-e", "GOG_KEYRING_BACKEND=file"
    # GOG_KEYRING_PASSWORD NAO fica hardcoded aqui - e um segredo de verdade
    # (protege as credenciais do gog/Google Workspace). Vem do .env via
    # $EnvArgs abaixo, igual as outras chaves de API.
) + $SharedVolumeArgs + $EnvArgs + @($ImageTag)

wslc @runArgs
if ($LASTEXITCODE -ne 0) { Write-Host "Falha ao iniciar o container." -ForegroundColor Red; exit 1 }

# --- 7. Healthcheck -----------------------------------------------------------
Write-Step "Verificando saude do gateway"
# Tenta por ate ~20s (5 tentativas x 4s) em vez de uma unica checagem depois
# de 3s fixos - logo apos o bootstrap pesado o gateway pode demorar um pouco
# mais pra responder, e uma unica tentativa gerava falso-negativo.
$healthy = $false
for ($i = 1; $i -le 5; $i++) {
    Start-Sleep -Seconds 4
    try {
        $health = Invoke-WebRequest -Uri "http://127.0.0.1:18789/healthz" -UseBasicParsing -TimeoutSec 10
        Write-Host "healthz: $($health.StatusCode) $($health.Content)" -ForegroundColor Green
        $healthy = $true
        break
    } catch {
        Write-Host "Ainda sem resposta em /healthz (tentativa $i/5)..." -ForegroundColor DarkYellow
    }
}
if (-not $healthy) {
    Write-Host "Nao consegui bater em /healthz. Rode: wslc container logs $ContainerName" -ForegroundColor Yellow
}

Write-Step "Pronto"
Write-Host "Control UI: http://127.0.0.1:18789/  (token = OPENCLAW_GATEWAY_TOKEN do seu .env)"
Write-Host ""
Write-Host "Auth, modelos, allowlist e o plugin do WhatsApp ja foram configurados via CLI acima."
Write-Host "Unico passo que continua manual (so precisa ser feito uma vez, fica salvo no volume):"
Write-Host "  .\cerbero-cli.ps1 channels login --channel whatsapp   # escanear o QR"
Write-Host ""
Write-Host "Para conferir depois:"
Write-Host "  .\cerbero-cli.ps1 models status"
Write-Host "  wslc container exec $ContainerName openclaw channels status"
