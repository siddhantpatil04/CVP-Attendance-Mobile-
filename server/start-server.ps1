# Starts the CVP Attendance office server (safe to run again; used by the auto-start job).
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

# wait up to 5 minutes for Docker Desktop to be ready after Windows starts
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
  docker info *> $null
  if ($LASTEXITCODE -eq 0) { $ready = $true; break }
  Start-Sleep -Seconds 5
}
if (-not $ready) { Write-Host 'Docker is not running. Open Docker Desktop and run this again.'; exit 1 }

New-Item -ItemType Directory -Force "$PSScriptRoot\supabase\functions" | Out-Null
Copy-Item "$PSScriptRoot\..\supabase\functions\*" "$PSScriptRoot\supabase\functions\" -Recurse -Force
npx --yes supabase start --workdir $PSScriptRoot
