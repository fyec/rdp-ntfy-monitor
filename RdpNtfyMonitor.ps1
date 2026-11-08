<#
.SYNOPSIS
  Sends an ntfy notification for Remote Desktop logons and reconnections.

.DESCRIPTION
  Run -Install from an elevated PowerShell window to install a startup task running
  as LocalSystem. The worker watches Terminal Services events 21 and 25.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Test,
    [switch]$Run
)

$ErrorActionPreference = 'Stop'
$TaskName = 'RdpNtfyMonitor'
$InstallRoot = Join-Path $env:ProgramData 'RdpNtfyMonitor'
$InstalledScript = Join-Path $InstallRoot 'RdpNtfyMonitor.ps1'
$ConfigPath = Join-Path $InstallRoot 'config.json'
$StatePath = Join-Path $InstallRoot 'lsm-state.json'
$LogPath = Join-Path $InstallRoot 'monitor.log'

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Protect-InstallFolder {
    $acl = Get-Acl -LiteralPath $InstallRoot
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $adminsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    foreach ($sid in @($systemSid, $adminsSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $InstallRoot -AclObject $acl
}

function Send-Ntfy {
    param(
        [pscustomobject]$Config,
        [string]$Title,
        [string]$Message,
        [string]$Tags = 'computer'
    )

    $headers = @{ Title = $Title; Tags = $Tags }
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.Token)) {
        $headers.Authorization = 'Bearer ' + [string]$Config.Token
    }
    $uri = ([string]$Config.Server).TrimEnd('/') + '/' + [string]$Config.Topic
    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'text/plain; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($Message)) -TimeoutSec 20 | Out-Null
}

function Install-Monitor {
    if (-not (Test-Administrator)) { throw 'Open Windows PowerShell as Administrator to install.' }

    $existingConfig = Test-Path -LiteralPath $ConfigPath
    if ($existingConfig) {
        $config = Load-Config
    } else {
        $server = Read-Host 'ntfy server (default: https://ntfy.sh)'
        if ([string]::IsNullOrWhiteSpace($server)) { $server = 'https://ntfy.sh' }
        $server = $server.Trim().TrimEnd('/')
        if ($server -notmatch '^https?://[^\s/]+(?:/[^\s]*)?$') { throw 'The server address must look like https://ntfy.sh.' }

        $topic = (Read-Host 'ntfy topic name').Trim()
        if ($topic -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'Topic must be 1-64 letters, numbers, hyphens, or underscores.' }
        $secureToken = Read-Host 'Access token (leave blank if none)' -AsSecureString
        $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr) }
        $config = [pscustomobject]@{ Server = $server; Topic = $topic; Token = $token }
    }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force
    Protect-InstallFolder

    if (-not $existingConfig) { $config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 }

    $powershell = Join-Path $PSHOME 'powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$InstalledScript`" -Run"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Notifies ntfy of Remote Desktop logons and reconnections.' -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Installed. ntfy topic: $($config.Topic)"
    Write-Host 'Existing events are skipped on first start; subsequent RDP sessions are reported.'
}

function Uninstall-Monitor {
    if (-not (Test-Administrator)) { throw 'Open Windows PowerShell as Administrator to uninstall.' }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
    Write-Host 'RdpNtfyMonitor was uninstalled.'
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration not found: $ConfigPath" }
    Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

function Start-Monitor {
    $config = Load-Config
    $channel = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
    if (-not (Test-Path -LiteralPath $StatePath)) {
        $latest = Get-WinEvent -LogName $channel -MaxEvents 1 -ErrorAction Stop
        @{ RecordId = [long]$latest.RecordId; TimeUtc = $latest.TimeCreated.ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
        Write-Log 'Started Terminal Services monitor; initialized event watermark.'
    } else {
        Write-Log 'Started Terminal Services monitor.'
    }

    while ($true) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            $watermark = [long]$state.RecordId
            $startTime = [DateTime]::Parse([string]$state.TimeUtc).ToLocalTime()
            try {
                $filter = @{ LogName = $channel; Id = 21, 25; StartTime = $startTime }
                $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop | Where-Object { $_.RecordId -gt $watermark } | Sort-Object RecordId)
            } catch {
                if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $events = @() }
                else { throw }
            }
            foreach ($eventRecord in $events) {
                $xml = [xml]$eventRecord.ToXml()
                $address = [string]$xml.Event.UserData.EventXML.Address
                if ($address -ne 'LOCAL') {
                    $message = "$($eventRecord.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))`n$($eventRecord.Message)"
                    Send-Ntfy -Config $config -Title 'Remote Desktop connection' -Message $message -Tags 'computer,desktop_computer'
                    Write-Log "Notified Terminal Services event $($eventRecord.Id), record $($eventRecord.RecordId)."
                }
                $watermark = [long]$eventRecord.RecordId
                @{ RecordId = $watermark; TimeUtc = $eventRecord.TimeCreated.ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
            }
        }
        catch {
            Write-Log ("Error: " + $_.Exception.Message)
        }
        Start-Sleep -Seconds 5
    }
}

try {
    if ($Install) { Install-Monitor; exit 0 }
    if ($Uninstall) { Uninstall-Monitor; exit 0 }
    if ($Test) {
        $cfg = Load-Config
        Send-Ntfy -Config $cfg -Title 'ntfy test notification' -Message 'RdpNtfyMonitor successfully reached ntfy.' -Tags 'white_check_mark'
        Write-Host 'Test notification sent.'
        exit 0
    }
    if ($Run) { Start-Monitor; exit 0 }
    Write-Host 'Usage: .\RdpNtfyMonitor.ps1 -Install | -Test | -Uninstall'
}
catch {
    Write-Error $_
    exit 1
}
