# Backs up the whole office database (logins, attendance, leaves, salary ... ) and the selfie photos.
#   .\backup-db.ps1                         -> server\backups\
#   .\backup-db.ps1 -To "E:\CVP-backup"      -> e.g. a pen drive / external disk
# Runs automatically every night at 11:00 PM (set up by setup-server.ps1). The last 30 backups are kept.
param([string]$To = "$PSScriptRoot\backups", [int]$Keep = 30)
$ErrorActionPreference = 'Stop'
$project = 'cvp-attendance'
New-Item -ItemType Directory -Force $To | Out-Null
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'

# 1. database
$sql = Join-Path $To "cvp_db_$stamp.sql"
docker exec "supabase_db_$project" pg_dump -U postgres -d postgres --clean --if-exists | Out-File -FilePath $sql -Encoding utf8
if ($LASTEXITCODE -ne 0 -or (Get-Item $sql).Length -lt 1000) { Write-Host 'Database backup FAILED.' -ForegroundColor Red; exit 1 }
Write-Host "Database saved: $sql"

# 2. selfie photos (Docker volume)
$vol = "supabase_storage_$project"
docker volume inspect $vol *> $null
if ($LASTEXITCODE -eq 0) {
  $tgz = "cvp_photos_$stamp.tgz"
  docker run --rm -v "${vol}:/data:ro" -v "${To}:/backup" alpine tar czf "/backup/$tgz" -C /data .
  if ($LASTEXITCODE -eq 0) { Write-Host "Photos saved:   $(Join-Path $To $tgz)" }
}

# 3. keep only the newest backups
Get-ChildItem $To -Filter 'cvp_db_*.sql'  | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep | Remove-Item -Force
Get-ChildItem $To -Filter 'cvp_photos_*.tgz' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep | Remove-Item -Force
