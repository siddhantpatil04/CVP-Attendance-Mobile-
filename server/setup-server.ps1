# CVP Attendance - OFFICE SERVER SETUP  (run ONCE on the server computer)
#
#   1. Open PowerShell as ADMINISTRATOR (right-click -> Run as administrator)
#   2. cd to this "server" folder, then:   .\setup-server.ps1
#
# It: checks Docker, starts the database (Supabase), loads the CVP tables, creates the first Admin login,
#     opens the office-network port, saves the daily backup job and the auto-start job,
#     and prints the CONNECTION CODE that the desktop / phone apps need.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root
$project = 'cvp-attendance'

function Step($n, $text) { Write-Host ""; Write-Host "[$n] $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host ""; Write-Host "STOP: $text" -ForegroundColor Red; exit 1 }

# ---- 0. administrator?
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'Run PowerShell as Administrator (right-click PowerShell -> Run as administrator), then try again.' }

# ---- 1. Docker
Step 1 'Checking Docker ...'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail 'Docker Desktop is not installed. Install it from https://www.docker.com/products/docker-desktop , restart the computer, open Docker Desktop once, then run this again.' }
docker info *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Docker Desktop is installed but not running. Open Docker Desktop, wait until it says "Engine running", then run this again.' }
Write-Host '    Docker is running.'

# ---- 2. start the database
Step 2 'Starting the database (the first time this downloads about 2-3 GB: wait 10-20 minutes) ...'
New-Item -ItemType Directory -Force "$root\supabase\functions" | Out-Null
Copy-Item "$root\..\supabase\functions\*" "$root\supabase\functions\" -Recurse -Force   # the admin-users function (create employees, reset passwords)
npx --yes supabase start --workdir $root
if ($LASTEXITCODE -ne 0) { Fail 'The database did not start. Read the message above.' }

# ---- 3. keys
Step 3 'Reading the server keys ...'
$envText = npx --yes supabase status -o env --workdir $root
$vals = @{}
foreach ($line in $envText) { if ($line -match '^\s*([A-Z_]+)="?([^"]*)"?\s*$') { $vals[$Matches[1]] = $Matches[2] } }
$anon = $vals['ANON_KEY']; $service = $vals['SERVICE_ROLE_KEY']
if (-not $anon -or -not $service) { Fail 'Could not read ANON_KEY / SERVICE_ROLE_KEY from "npx supabase status -o env". Send me the output of that command.' }
$ip = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address.IPAddress
if (-not $ip) { $ip = Read-Host 'Could not find this computer''s network address. Type it (for example 192.168.1.50)' }
$apiLocal = 'http://127.0.0.1:54321'
$apiLan = "http://${ip}:54321"
Write-Host "    This server's address:  $apiLan"

# ---- 4. tables
Step 4 'Loading the CVP tables and rules (cvp_attendance_schema.sql) ...'
$schema = Join-Path $root '..\supabase\cvp_attendance_schema.sql'
Get-Content $schema -Raw -Encoding UTF8 | docker exec -i "supabase_db_$project" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
if ($LASTEXITCODE -ne 0) { Fail 'The tables could not be loaded. Read the error above.' }
Write-Host '    Done.'

# ---- 5. first admin
Step 5 'Creating the first Admin login ...'
$hasAdmin = (docker exec -i "supabase_db_$project" psql -U postgres -d postgres -t -A -c "select count(*) from public.profiles") -join ''
if ([int]$hasAdmin -gt 0) {
  Write-Host '    A login already exists: skipped.'
} else {
  $user = Read-Host 'Admin username (for example: admin)'
  $name = Read-Host 'Admin full name'
  $sec = Read-Host 'Admin password (at least 12 characters)' -AsSecureString
  $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  if ($pw.Length -lt 12) { Fail 'The password must be at least 12 characters.' }
  $body = @{ email = "$($user.ToLower())@cvp-attendance.app"; password = $pw; email_confirm = $true; user_metadata = @{ username = $user.ToLower(); full_name = $name } } | ConvertTo-Json -Depth 5
  Invoke-RestMethod -Method Post -Uri "$apiLocal/auth/v1/admin/users" -ContentType 'application/json' -Body $body -Headers @{ apikey = $service; Authorization = "Bearer $service" } | Out-Null
  Write-Host "    Admin '$($user.ToLower())' created (the first login is the Admin)."
}

# ---- 6. firewall
Step 6 'Opening the office-network port (54321) and closing the database ports ...'
Remove-NetFirewallRule -DisplayName 'CVP Attendance server' -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'CVP Attendance block database ports' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'CVP Attendance server' -Direction Inbound -Protocol TCP -LocalPort 54321 -Action Allow -Profile Private,Domain | Out-Null
New-NetFirewallRule -DisplayName 'CVP Attendance block database ports' -Direction Inbound -Protocol TCP -LocalPort 54322-54329 -Action Block | Out-Null
Write-Host '    Done. (If the office Wi-Fi is set to "Public" in Windows, change it to "Private".)'

# ---- 7. connection code
Step 7 'Creating the connection code ...'
$json = (@{ u = $apiLan; k = $anon } | ConvertTo-Json -Compress)
$code = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
Set-Content -Path "$root\connection-code.txt" -Value $code -Encoding ascii
Set-Clipboard -Value $code
Write-Host '    Saved in server\connection-code.txt and copied to the clipboard.'

# ---- 8. auto start + daily backup
Step 8 'Setting up auto-start and the daily backup ...'
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$startArg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\start-server.ps1`""
$backupArg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\backup-db.ps1`""
Unregister-ScheduledTask -TaskName 'CVP Attendance server start' -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'CVP Attendance daily backup' -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName 'CVP Attendance server start' -Action (New-ScheduledTaskAction -Execute $ps -Argument $startArg) -Trigger (New-ScheduledTaskTrigger -AtLogOn) -RunLevel Highest | Out-Null
Register-ScheduledTask -TaskName 'CVP Attendance daily backup' -Action (New-ScheduledTaskAction -Execute $ps -Argument $backupArg) -Trigger (New-ScheduledTaskTrigger -Daily -At '23:00') -RunLevel Highest | Out-Null
Write-Host '    The server starts when you sign in to Windows; a backup is made every night at 11:00 PM.'

Write-Host ''
Write-Host '=================================================================' -ForegroundColor Green
Write-Host ' SERVER READY' -ForegroundColor Green
Write-Host " Address : $apiLan"
Write-Host ' Next    : on every desktop / phone open the app -> Login screen -> "Server settings" -> paste the code below -> Connect.'
Write-Host ''
Write-Host $code
Write-Host '=================================================================' -ForegroundColor Green
Write-Host 'Tip: give this computer a FIXED address in your router (DHCP reservation), so the address never changes.'
