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
  [int]$WindowMinutes    = 30    # ...dentro desta janela, antes de parar e so alertar
)

function Write-Log([string]$msg) {
  $line = "{0:yyyy-MM-dd HH:mm:ss} $msg" -f (Get-Date)
  Add-Content -Path $LogPath -Value $line
}

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null

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

# --- restart ---
Write-Log "Reiniciando container '$ContainerName'..."
$out = & wslc container start $ContainerName 2>&1
$out | ForEach-Object { Write-Log "  $_" }

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
