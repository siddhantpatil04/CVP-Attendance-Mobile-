# Stops the office server. Your data is kept (it is in Docker volumes) and is there again after start-server.ps1.
Set-Location $PSScriptRoot
npx --yes supabase stop --workdir $PSScriptRoot
