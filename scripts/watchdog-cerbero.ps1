<#
.SYNOPSIS
  Watchdog do Cerbero (wslc/OpenClaw). Verifica /healthz do gateway; se nao
  responder, reinicia o container. Tem trava anti crash-loop: se reiniciar
  demais em pouco tempo, para de tentar e so alerta.

.NOTES
  Pensado para rodar via Agendador de Tarefas do Windows a cada 5 min
  (ver register-watchdog-task.ps1). Nao faz nada e nao gera log quando
  tudo esta saudavel, para nao poluir o arquivo de log.
#>

param(
  [string]$ContainerName = "cerbero-gateway",
  [string]$HealthUrl     = "http://127.0.0.1:18789/healthz",
  [int]$TimeoutSec       = 10,
  [string]$LogPath       = "C:\wslc\projects\cerbero\logs\watchdog.log",
  [string]$StatePath     = "C:\wslc\projects\cerbero\logs\watchdog-state.json",
  [int]$MaxRestarts      = 3,    # restarts permitidos...
  [int]$WindowMinutes    = 30,   # ...dentro desta janela, antes de parar e so alertar
  [int]$StartAttempts    = 3,    # tentativas de 'wslc container start' por episodio
  [int]$RetryDelaySec    = 10,   # espera entre tentativas (cobre a janela em que o
                                  # wslc recria o container - ID muda a cada reload de
                                  # config - e 'start' pode nao achar nada por 1-2 tentativas)
  [int]$StartupGraceSec  = 300   # o servico do WSLC demora pra subir depois de um boot
                                  # da maquina - nao adianta (nem e seguro) tentar
                                  # restart antes disso, o wslc.exe pode nem responder
                                  # ainda. Enquanto o uptime for menor que isso, so sai.
)

# Sem isso, a saida do wslc.exe (que fala UTF-8) chega mangled no log
# ("Contêiner" virava "Cont+ñiner") porque o console do PowerShell 5.1 no
# Windows normalmente usa a codepage OEM, nao UTF-8.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Log([string]$msg) {
  $line = "{0:yyyy-MM-dd HH:mm:ss} $msg" -f (Get-Date)
  Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null

# --- janela de graca pos-boot: o WSLC demora pra subir depois que o Windows
# reinicia, entao checar/reiniciar cedo demais so gasta tentativas do
# contador anti crash-loop (item 13 do LICOES-APRENDIDAS) por um motivo que
# nao e uma falha de verdade ---
try {
  $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
  $uptimeSec = [int]((Get-Date) - $bootTime).TotalSeconds
  if ($uptimeSec -lt $StartupGraceSec) {
    Write-Log "Dentro da janela de graca pos-boot (uptime ${uptimeSec}s < ${StartupGraceSec}s) - pulando checagem."
    exit 0
  }
} catch {
  # Se nao der pra ler o uptime por algum motivo, nao bloqueia o watchdog -
  # so segue com a checagem normal.
}

# --- checagem de saude ---
$healthy = $false
try {
  $resp = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec $TimeoutSec
  $healthy = ($resp.StatusCode -eq 200)
} catch {
  $healthy = $false
}

if ($healthy) {
  exit 0
}

Write-Log "FALHA: $HealthUrl nao respondeu (ou status != 200)."

# --- estado / trava de restart loop ---
$state = [pscustomobject]@{ restarts = @() }
if (Test-Path $StatePath) {
  try { $state = Get-Content $StatePath -Raw | ConvertFrom-Json } catch {}
}
$cutoff = (Get-Date).AddMinutes(-$WindowMinutes)
$recent = @($state.restarts | Where-Object { $_ -and ([datetime]$_ -gt $cutoff) })

if ($recent.Count -ge $MaxRestarts) {
  Write-Log "ALERTA: $($recent.Count) restarts nos ultimos $WindowMinutes min. Suspendendo restart automatico - precisa olhar 'wslc container logs $ContainerName' manualmente."
  try {
    Import-Module BurntToast -ErrorAction Stop
    New-BurntToastNotification -Text "Cerbero watchdog", "Crash-loop detectado - restart automatico suspenso. Confira os logs."
  } catch {
    # BurntToast nao instalado - sem problema, o log acima ja registra o alerta
  }
  exit 1
}

# --- restart, com retry (cobre a janela de recriacao do container: o wslc
# troca o ID do container a cada reload de config, entao 'start' pode falhar
# com WSLC_E_CONTAINER_NOT_FOUND por 1-2 tentativas ate o novo existir) ---
$started = $false
for ($i = 1; $i -le $StartAttempts; $i++) {
  Write-Log "Reiniciando container '$ContainerName' (tentativa $i/$StartAttempts)..."
  $out = & wslc container start $ContainerName 2>&1
  $out | ForEach-Object { Write-Log "  $_" }

  if ($LASTEXITCODE -eq 0) {
    $started = $true
    break
  }
  if ($i -lt $StartAttempts) {
    Start-Sleep -Seconds $RetryDelaySec
  }
}

if (-not $started) {
  Write-Log "Todas as $StartAttempts tentativas de start falharam. Estado atual do wslc para diagnostico:"
  $psOut = & wslc container ps -a 2>&1
  $psOut | ForEach-Object { Write-Log "  $_" }
}

Start-Sleep -Seconds 15
try {
  $resp2 = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec $TimeoutSec
  Write-Log "Pos-restart healthz: $($resp2.StatusCode)"
} catch {
  Write-Log "Pos-restart healthz: ainda sem resposta apos 15s."
}

$recent += (Get-Date).ToString("o")
$state = [pscustomobject]@{ restarts = $recent }
$state | ConvertTo-Json | Set-Content $StatePath
