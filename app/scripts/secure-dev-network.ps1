# Run ONCE in PowerShell "as Administrator" on the office PC that runs the Expo dev server.
# What it does (nothing in the app, database or Supabase is touched):
#   1. marks the office Wi-Fi as a Private (trusted) network
#   2. allows incoming connections to the Expo dev server (port 8081) ONLY from the office network (local subnet),
#      never from the internet and never from the Public profile
#   3. removes the broad "Node.js" allow rules Windows may have created when you clicked "Allow access"
# To undo:  Remove-NetFirewallRule -DisplayName "CVP Expo dev server (office network only)"
$ErrorActionPreference = 'Stop'

$cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
Write-Host "Network: $($cfg.InterfaceAlias)  PC address: $($cfg.IPv4Address.IPAddress)  router: $($cfg.IPv4DefaultGateway.NextHop)"
Set-NetConnectionProfile -InterfaceAlias $cfg.InterfaceAlias -NetworkCategory Private

Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match '^Node\.js' -and $_.Action -eq 'Allow' } |
  ForEach-Object { Disable-NetFirewallRule -Name $_.Name; Write-Host "Disabled broad rule: $($_.DisplayName)" }

$name = 'CVP Expo dev server (office network only)'
Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8081 `
  -RemoteAddress LocalSubnet -Profile Private | Out-Null
Write-Host "Done. Port 8081 is open to the office network only. Start the server with:  npm run dev:office"
