<#
.SYNOPSIS
  Registra o watchdog do Cerbero no Agendador de Tarefas do Windows,
  rodando a cada 5 minutos indefinidamente.

.NOTES
  Rode uma vez, manualmente, em um PowerShell normal (nao precisa ser admin,
  a tarefa e criada no escopo do usuario atual). Para remover depois:
    Unregister-ScheduledTask -TaskName "Cerbero Watchdog" -Confirm:$false
#>

$scriptPath = "C:\wslc\projects\cerbero\scripts\watchdog-cerbero.ps1"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) `
  -RepetitionDuration (New-TimeSpan -Days 3650)   # ~10 anos - [TimeSpan]::MaxValue estoura o schema do Agendador

$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -DontStopOnIdleEnd `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

try {
  Register-ScheduledTask -TaskName "Cerbero Watchdog" `
    -Action $action -Trigger $trigger -Settings $settings `
    -Description "Verifica /healthz do Cerbero a cada 5 min e reinicia o container se necessario (periodo de teste)." `
    -Force -ErrorAction Stop | Out-Null

  Write-Host "Tarefa 'Cerbero Watchdog' registrada. Rodando a cada 5 min a partir de agora." -ForegroundColor Green
  Write-Host "Para conferir: Get-ScheduledTask -TaskName 'Cerbero Watchdog' | Get-ScheduledTaskInfo"
  Write-Host "Para remover:  Unregister-ScheduledTask -TaskName 'Cerbero Watchdog' -Confirm:`$false"
} catch {
  Write-Host "FALHOU ao registrar a tarefa: $_" -ForegroundColor Red
  exit 1
}
