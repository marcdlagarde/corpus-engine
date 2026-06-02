# setup-backup-task.ps1
# ONE-TIME SETUP. Run this from an elevated PowerShell window.
# If you see "Access is denied" anywhere below, close and re-launch PowerShell
# as Administrator (right-click PowerShell -> Run as administrator).
#
# Registers (or re-registers) a scheduled task "CorpusBackup" that runs
# backup.ps1 every 30 minutes, regardless of logon state. Uses a Once trigger
# with post-hoc Repetition assignment so the schedule survives sleep/wake/lock
# cycles cleanly.
#
# Resolves backup.ps1 location from the same directory this script lives in.

$ErrorActionPreference = 'Stop'

# Fail loud if not elevated. The "Done" message at the end will then never
# print on a half-broken registration.
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "ERROR: This script must run as Administrator." -ForegroundColor Red
    Write-Host "Close this window, right-click PowerShell, choose 'Run as administrator', and re-run." -ForegroundColor Red
    exit 1
}

$backupScript = Join-Path (Split-Path $PSCommandPath -Parent) 'backup.ps1'
if (-not (Test-Path $backupScript)) {
    Write-Host "ERROR: backup.ps1 not found at $backupScript" -ForegroundColor Red
    exit 1
}

# -WindowStyle Hidden + -NonInteractive belt-and-suspenders the no-window behavior;
# the real reason no window appears is the S4U principal below (no interactive session).
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$backupScript`""

# Trigger: register-time start + 30-minute repetition, indefinite.
# Pattern: Once trigger as base + post-hoc Repetition assignment so the
# Duration defaults to empty (Task Scheduler interprets as "repeat forever").
# Long explicit durations like P36500D get rejected by the XML validator.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30)).Repetition

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

# LogonType S4U ("Service For User"): task runs as the user but without an interactive
# desktop session — so no console window flashes every 30 min. Tradeoff: the task
# can't prompt for credentials. Git push relies on cached Windows Credential Manager
# entries; if those expire, the push fails silently and shows up in the task's
# "Last Run Result" rather than as a popup.
$taskPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited

# Clear any older task name from previous installs.
Unregister-ScheduledTask -TaskName 'CorpusBackup' -Confirm:$false -ErrorAction SilentlyContinue

$registered = Register-ScheduledTask `
    -TaskName 'CorpusBackup' `
    -Description 'Commit + push the corpus every 30 min. Survives sleep/wake.' `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $taskPrincipal `
    -Force

if (-not $registered) {
    Write-Host "ERROR: Registration returned no task object. Something went wrong silently." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Done. 'CorpusBackup' is registered with a 30-min repetition trigger." -ForegroundColor Green
Write-Host "It will fire 1 minute from now and every 30 minutes thereafter, regardless of logon state." -ForegroundColor Green
Get-ScheduledTask -TaskName 'CorpusBackup' | Select-Object TaskName, State
