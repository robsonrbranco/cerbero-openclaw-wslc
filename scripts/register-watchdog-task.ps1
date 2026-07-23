<#
.SYNOPSIS
  Registra o watchdog do Cerbero no Agendador de Tarefas do Windows,
  rodando a cada 5 minutos indefinidamente.

.NOTES
  IMPORTANTE (17/07/2026): precisa rodar este script a partir de um
  PowerShell "Executar como Administrador". A tarefa agora e registrada com
  -RunLevel Highest de proposito - se Branco sempre usa terminal elevado
  pra rodar wslc manualmente, o watchdog (que roda em background, sem
  terminal nenhum) precisa bater no MESMO contexto de privilegio, senao
  os dois acabam em sessoes wslc separadas e isoladas uma da outra
  (`wslc system session list` mostra sessoes diferentes pra admin vs
  usuario comum) - o watchdog fica cego pro container que voce criou.
  Ver LICOES-APRENDIDAS.md item 22. Para remover depois:
    Unregister-ScheduledTask -TaskName "Cerbero Watchdog" -Confirm:$false
#>

$vbsPath = "C:\wslc\projects\cerbero\scripts\run-watchdog-hidden.vbs"

# Chama o watchdog via wscript.exe + VBScript (WScript.Shell.Run com janela=0),
# nao powershell.exe direto - "-WindowStyle Hidden" ainda deixa o conhost.exe
# piscar uma janela por uma fracao de segundo, o VBScript nao tem esse problema.
$action = New-ScheduledTaskAction -Execute "wscript.exe" `
  -Argument "//B `"$vbsPath`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) `
  -RepetitionDuration (New-TimeSpan -Days 3650)   # ~10 anos - [TimeSpan]::MaxValue estoura o schema do Agendador

$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -DontStopOnIdleEnd `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

# -RunLevel Highest: roda elevado, no MESMO contexto de privilegio que
# Branco usa manualmente (terminal sempre como Administrador) - ver nota no
# cabecalho deste arquivo e item 22 do LICOES-APRENDIDAS.md.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive -RunLevel Highest

try {
  Register-ScheduledTask -TaskName "Cerbero Watchdog" `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "Verifica /healthz do Cerbero a cada 5 min e reinicia o container se necessario (periodo de teste)." `
    -Force -ErrorAction Stop | Out-Null

  Write-Host "Tarefa 'Cerbero Watchdog' registrada. Rodando a cada 5 min a partir de agora." -ForegroundColor Green
  Write-Host "Para conferir: Get-ScheduledTask -TaskName 'Cerbero Watchdog' | Get-ScheduledTaskInfo"
  Write-Host "Para remover:  Unregister-ScheduledTask -TaskName 'Cerbero Watchdog' -Confirm:`$false"
} catch {
  Write-Host "FALHOU ao registrar a tarefa: $_" -ForegroundColor Red
  exit 1
}
