<#
.SYNOPSIS
  Adiciona uma entrada no arquivo hosts do Windows para que o navegador (ou
  qualquer app) rodando NO HOST consiga abrir o Cerbero pelo nome, em vez de
  precisar decorar 127.0.0.1:<porta>:

    http://cerbero-gateway:18789

.NOTES
  Este script e AUTOSSUFICIENTE - so cuida da entrada do Cerbero. Nao
  depende de nenhum outro projeto WSLC neste host, e nenhum outro projeto
  depende dele (se voce tambem roda o Hermes ou outro container WSLC, cada
  um tem seu proprio "scripts/add-hosts-entries.ps1" - ver o projeto
  correspondente em ../hermes).

  Por que isso e necessario: a rede nomeada do WSLC (-SharedNetwork no
  setup-cerbero-wslc.ps1, ver LICOES-APRENDIDAS.md) so da resolucao de nome
  ENTRE containers (um container WSLC enxergando outro pelo nome). O HOST
  Windows nao participa dessa rede - ele so alcanca o container pela porta
  publicada em 127.0.0.1 (ver "Port publishing currently relays localhost
  TCP" na documentacao do wslc). Como o Windows nao tem um resolvedor de DNS
  pro nome do container, a unica forma de fazer "http://cerbero-gateway:18789"
  funcionar no navegador do HOST e mapear esse nome pra 127.0.0.1 no arquivo
  hosts (C:\Windows\System32\drivers\etc\hosts) - o mesmo mecanismo usado
  por qualquer setup de desenvolvimento local (ex.: "myapp.local").

  Como o container ja publica sua porta em 127.0.0.1 (18789 por padrao - ver
  setup-cerbero-wslc.ps1), so precisamos que o NOME resolva pra 127.0.0.1; a
  porta digitada na URL continua sendo a porta publicada no host, nao muda.

  Precisa rodar como Administrador (o arquivo hosts so e editavel por admin).
  Se nao estiver elevado, o script se reinicia sozinho pedindo elevacao (UAC).

  Idempotente: nao duplica a entrada se rodado de novo. Faz backup do hosts
  antes de escrever (hosts.bak-<timestamp>, na mesma pasta).

.PARAMETER Hostname
  O nome a mapear pra 127.0.0.1. Default "cerbero-gateway" - MESMO valor
  default do parametro -Hostname em setup-cerbero-wslc.ps1. Se voce
  customizou -Hostname la (ex.: rumo a uma migracao futura pra um dominio
  real), passe o mesmo valor aqui, ou melhor ainda: nesse caso o dominio
  real ja teria DNS proprio na internet e este script pra uso local
  deixaria de ser necessario.

.PARAMETER TargetIp
  IP para o qual o Hostname deve apontar. Default "127.0.0.1" (o container
  publica a porta no proprio host).

.EXAMPLE
  .\add-hosts-entries.ps1
  .\add-hosts-entries.ps1 -Hostname cerbero-gateway -TargetIp 127.0.0.1
#>

param(
    [string]$Hostname = "cerbero-gateway",
    [string]$TargetIp = "127.0.0.1"
)

$ErrorActionPreference = "Stop"

# --- Auto-elevacao: reinicia como Administrador se necessario ---------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Precisa rodar como Administrador - reiniciando com elevacao (UAC)..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"",
        "-Hostname", "`"$Hostname`"", "-TargetIp", "`"$TargetIp`""
    )
    exit
}

$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"

if (-not (Test-Path $HostsFile)) {
    Write-Host "Arquivo hosts nao encontrado em $HostsFile - algo incomum na instalacao do Windows." -ForegroundColor Red
    exit 1
}

# --- Backup antes de mexer ----------------------------------------------------
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupFile = "$HostsFile.bak-$Timestamp"
Copy-Item $HostsFile $BackupFile
Write-Host "Backup criado: $BackupFile" -ForegroundColor DarkGray

# --- Le o conteudo atual, evita duplicar a entrada se ja existir -----------
$currentContent = Get-Content $HostsFile -Raw -Encoding UTF8

# Regex simples: procura uma linha nao-comentada que ja tenha esse hostname
# mapeado (qualquer IP) - evita duplicar OU deixar duas entradas
# conflitantes pro mesmo nome.
$pattern = "(?m)^\s*[^#\r\n]+\s+$([regex]::Escape($Hostname))\s*$"
if ($currentContent -match $pattern) {
    Write-Host "Ja existe uma entrada para '$Hostname' no hosts - nada a fazer (edite manualmente se o IP estiver errado)." -ForegroundColor Green
} else {
    $block = "`r`n# --- wslc: Cerbero ($Timestamp) ---`r`n$TargetIp`t$Hostname`t# wslc - adicionado por add-hosts-entries.ps1 ($Timestamp)`r`n"
    Add-Content -Path $HostsFile -Value $block -Encoding UTF8
    Write-Host "Adicionada entrada em $HostsFile" -ForegroundColor Green
    Write-Host "  $TargetIp`t$Hostname"
}

# --- Flush do cache de DNS do Windows, para a mudanca valer na hora --------
ipconfig /flushdns | Out-Null
Write-Host ""
Write-Host "Cache de DNS do Windows limpo. Teste agora: http://${Hostname}:18789" -ForegroundColor Cyan
Write-Host ""
Write-Host "Para desfazer: restaure o backup ($BackupFile) por cima de $HostsFile," -ForegroundColor DarkGray
Write-Host "ou remova manualmente a linha marcada '# wslc - adicionado por add-hosts-entries.ps1'." -ForegroundColor DarkGray
