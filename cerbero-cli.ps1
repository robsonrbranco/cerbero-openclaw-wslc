<#
.SYNOPSIS
  Roda um comando avulso do OpenClaw CLI (plugins install, models auth login,
  channels login, models list, etc.) num container descartavel que reusa os
  mesmos volumes do gateway do Cerbero (config/workspace/secrets), sem precisar
  mexer no container do gateway que ja esta rodando.

.NOTES
  Esse e o caminho que se mostrou mais confiavel no WSLC: instalar plugins e
  configurar modelos direto pelo proprio openclaw, em vez de tentar
  pre-configurar tudo no Dockerfile/JSON antes de subir. Comandos que so
  escrevem em ~/.openclaw (plugins install, channels login/QR, models auth
  login) nao precisam falar com o processo do gateway - so precisam enxergar
  os mesmos arquivos, que e exatamente o que os volumes compartilhados dao.

  O container do gateway (rodando via setup-cerbero-wslc.ps1) recarrega a config e os
  plugins instalados no proximo restart (wslc container stop cerbero-gateway
  seguido de wslc container start cerbero-gateway - o wslc desta preview nao
  tem um subcomando "restart" unico, so stop/start separados)
  se a mudanca exigir isso - a maioria das mudancas de canal/plugin ja e
  detectada em runtime, mas reiniciar garante.

.EXAMPLE
  .\cerbero-cli.ps1 plugins install clawhub:@openclaw/whatsapp
  .\cerbero-cli.ps1 channels login --channel whatsapp
  .\cerbero-cli.ps1 models list --provider anthropic
  .\cerbero-cli.ps1 models auth login --provider deepseek-api-key
#>

param(
    [string]$BaseDir = "C:\wslc\data\cerbero",
    [string]$ImageTag = "cerbero:local",
    # Position=0 explicito aqui desliga a numeracao posicional automatica do
    # PowerShell para TODOS os parametros deste script (regra do PowerShell:
    # se algum parametro declara Position, os demais deixam de ser
    # posicionais). Sem isso, "models status" virava $BaseDir="models",
    # $ImageTag="status" e $Args ficava vazio/errado - bug real do erro
    # "Imagem 'list' nao encontrada".
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"

if (-not $Args -or $Args.Count -eq 0) {
    Write-Host "Uso: .\cerbero-cli.ps1 <comando openclaw> [args...]" -ForegroundColor Yellow
    Write-Host "Ex.:  .\cerbero-cli.ps1 plugins install clawhub:@openclaw/whatsapp"
    exit 1
}

$ConfigDir    = Join-Path $BaseDir "config"
$WorkspaceDir = Join-Path $BaseDir "workspace"
$SecretDir    = Join-Path $BaseDir "secrets"
$LogsDir      = Join-Path $BaseDir "logs"
$EnvFile      = Join-Path $BaseDir ".env"

$EnvArgs = @()
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $k, $v = $line.Split("=", 2)
            $EnvArgs += @("-e", "$($k.Trim())=$($v.Trim())")
        }
    }
}

# --- Auto-correcao de ownership dos volumes nomeados ------------------------
# O virtiofs do WSLC as vezes reseta o dono de volumes nomeados para root
# entre execucoes (observado apos instalacoes de plugin que falham/limpam
# arquivos parcialmente). Em vez de confiar num chown manual unico, corrigimos
# o dono ANTES de toda invocacao - custo pequeno (container descartavel rapido,
# so toca esses dois volumes), robusto contra a causa exata do reset.
wslc run --rm --user root `
    -v cerbero-npm:/home/cerbero/.openclaw/npm `
    -v cerbero-agents:/home/cerbero/.openclaw/agents `
    -v cerbero-extensions:/home/cerbero/.openclaw/extensions `
    -v cerbero-state:/home/cerbero/.openclaw/state `
    --entrypoint chown $ImageTag -R cerbero:cerbero /home/cerbero/.openclaw/npm /home/cerbero/.openclaw/agents /home/cerbero/.openclaw/extensions /home/cerbero/.openclaw/state 2>$null | Out-Null

$runArgs = @(
    "run", "--rm", "-i", "-t",
    "-v", "${ConfigDir}:/home/cerbero/.openclaw",
    # Mesmo volume nomeado usado pelo setup-cerbero-wslc.ps1 - ver comentario
    # la para o motivo (bind mount do Windows bloqueia plugin loading por
    # world-writable path). Tem que ser o MESMO nome de volume dos dois
    # scripts para os plugins instalados por aqui aparecerem no gateway.
    "-v", "cerbero-npm:/home/cerbero/.openclaw/npm",
    # Auth-profile-store (~/.openclaw/agents/main/agent/openclaw-agent.sqlite)
    # tambem mora aqui - o bind mount do Windows nao suporta bem locking de
    # sqlite (erro "auth store lock may be busy"), entao isolamos em volume
    # nomeado tambem, mesma logica do cerbero-npm acima.
    "-v", "cerbero-agents:/home/cerbero/.openclaw/agents",
    # Plugins instalados via ClawHub (ex.: whatsapp) vao para extensions/, nao
    # npm/ - mesmo problema de world-writable, precisa do proprio volume.
    "-v", "cerbero-extensions:/home/cerbero/.openclaw/extensions",
    # State principal (state/openclaw.sqlite + -wal/-shm) - sqlite sobre bind
    # mount do Windows nao segura chmod/lock direito ("skipped permission
    # hardening ... EPERM"), mesmo padrao dos volumes acima.
    "-v", "cerbero-state:/home/cerbero/.openclaw/state",
    "-v", "${WorkspaceDir}:/home/cerbero/.openclaw/workspace",
    "-v", "${SecretDir}:/home/cerbero/.config/openclaw",
    "-v", "${LogsDir}:/tmp/openclaw"
) + $EnvArgs + @(
    "--entrypoint", "node",
    $ImageTag,
    "dist/index.js"
) + $Args

wslc @runArgs
