# Restores a database backup made by backup-db.ps1 (this REPLACES the current data).
#   .\restore-db.ps1 -File "C:\...\cvp_db_2026-10-17_2300.sql"
param([Parameter(Mandatory = $true)][string]$File)
$ErrorActionPreference = 'Stop'
$project = 'cvp-attendance'
if (-not (Test-Path $File)) { Write-Host "File not found: $File" -ForegroundColor Red; exit 1 }
$ok = Read-Host 'This replaces ALL current data with the backup. Type YES to continue'
if ($ok -ne 'YES') { Write-Host 'Cancelled.'; exit 0 }
Get-Content $File -Raw -Encoding UTF8 | docker exec -i "supabase_db_$project" psql -U postgres -d postgres -q
Write-Host 'Restored. Reload the apps.' -ForegroundColor Green
