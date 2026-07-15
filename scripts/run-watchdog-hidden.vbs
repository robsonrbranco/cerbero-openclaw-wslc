' Lanca o watchdog do Cerbero via powershell.exe SEM nenhuma janela de
' console piscando na tela.
'
' Motivo de existir: "powershell.exe -WindowStyle Hidden" (usado antes,
' direto na acao da tarefa agendada) ainda deixa o conhost.exe abrir uma
' janela por uma fracao de segundo antes do WindowStyle ser aplicado - da
' o efeito de "pisca e fecha" que aparece no desktop. WScript.Shell.Run com
' o parametro de janela = 0 nao tem esse problema: o processo nunca chega a
' criar uma janela visivel, nem por um instante.
'
' Chamado pela tarefa agendada "Cerbero Watchdog" via:
'   wscript.exe //B "run-watchdog-hidden.vbs"
' (//B = modo batch, suprime qualquer dialogo de erro do proprio wscript)

Set objShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
psScript = scriptDir & "\watchdog-cerbero.ps1"

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & psScript & """"

' 0 = janela oculta; True = espera terminar (mantem o "IgnoreNew" da tarefa
' coerente - a tarefa so considera a execucao encerrada quando o script sair)
objShell.Run cmd, 0, True
