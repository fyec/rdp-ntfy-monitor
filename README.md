# RDP ntfy Monitor

Get an ntfy notification when a Remote Desktop session is opened or reconnected on a Windows machine. The project is intended to help server owners notice Remote Desktop access they did not expect or authorize.

The notification includes the event's timestamp and Windows event message, which can contain the account name, session ID, and source network address. The event message uses the Windows display language.

## How it works

The PowerShell worker checks the Windows Terminal Services LocalSessionManager operational log for event 21 (session logon) and event 25 (session reconnection). It ignores events whose source address is reported as `LOCAL`. A scheduled task starts the worker as `SYSTEM` when Windows starts. Events are checked about every five seconds.

The first time the worker starts, it records the latest event as its starting point; it does not send old events. On later starts it resumes from the saved position. If an ntfy request fails, the worker retries that event while it remains available in the Windows event log.

## Requirements

- Windows with Remote Desktop and the Terminal Services LocalSessionManager operational event log available and enabled.
- Windows PowerShell 5.1, the ScheduledTasks module, and an Administrator account for installation.
- Network access to an ntfy server and an ntfy app or other subscriber using the same server and topic.

## Install

1. Download and extract this project on the Windows machine to monitor.
2. Open **Windows PowerShell as Administrator** and change to the extracted folder.
3. If script execution is disabled, allow scripts in this PowerShell session:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   ```

4. Install the monitor:

   ```powershell
   .\RdpNtfyMonitor.ps1 -Install
   ```

Enter your ntfy server URL (press Enter for `https://ntfy.sh`), topic name, and an access token if your server requires one. Subscribe to that same server and topic in the ntfy app. The token prompt hides your input.

The installer copies the script to `C:\ProgramData\RdpNtfyMonitor`, registers and starts the `RdpNtfyMonitor` scheduled task, and keeps the existing configuration when it is run again. Windows Group Policy can override the process execution policy.

## Test

From an elevated Windows PowerShell window in the extracted folder, send a test notification:

```powershell
.\RdpNtfyMonitor.ps1 -Test
```

This tests ntfy delivery only. To check event detection, wait a few seconds after installation and then make a new Remote Desktop connection or reconnect an existing session. Check the app for the event notification.

To inspect the worker and its log:

```powershell
Get-ScheduledTask -TaskName RdpNtfyMonitor | Select-Object State
Get-Content 'C:\ProgramData\RdpNtfyMonitor\monitor.log' -Tail 30
```

If a notification does not arrive, check that the task is running, the server and topic match the app subscription, the Windows event log contains events 21 or 25, and the machine can reach ntfy. The log records delivery and worker errors.

## Uninstall

Run from an elevated Windows PowerShell window in the extracted folder:

```powershell
.\RdpNtfyMonitor.ps1 -Uninstall
```

This removes the scheduled task and the `C:\ProgramData\RdpNtfyMonitor` folder, including its configuration, saved position, and log.

## Privacy and limitations

Notifications may contain account names and source IP addresses. On a public ntfy service, anyone with access to the topic may be able to read or post messages, depending on the server's access controls. Use a private, access-controlled topic or server and HTTPS appropriate to your environment. The access token is stored in plaintext in the local configuration file; the installer restricts the application folder to SYSTEM and local administrators. Local administrators can read it.

This is an alerting aid, not a guarantee that unauthorized access will be detected or prevented. It depends on Windows recording the relevant events, the task running, network connectivity, and ntfy delivery. Events may be missed if the event log is cleared or overwritten, or if its record numbering changes. Other remote access methods and failed connection attempts are outside its scope. A new session and a reconnection can each produce a notification.
