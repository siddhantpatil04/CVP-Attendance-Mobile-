# Builds the Windows installer:  .\build-desktop.ps1
#   1. exports the website  2. packs it into the desktop app  3. creates desktop\release\CVP Attendance Setup x.x.x.exe
# Optional: put your Netlify address in desktop\app-config.json ("url") so every installed copy always loads the newest version.
$ErrorActionPreference = 'Stop'
Set-Location "$PSScriptRoot\app"
Write-Host '1/3 Exporting the website ...' -ForegroundColor Cyan
npx expo export -p web --output-dir ..\desktop\web
Set-Location "$PSScriptRoot\desktop"
if (-not (Test-Path node_modules)) { Write-Host '2/3 Installing Electron (first time only) ...' -ForegroundColor Cyan; npm install }
Write-Host '3/3 Creating the installer ...' -ForegroundColor Cyan
npm run dist
Write-Host ''
Write-Host 'Done. Installer: desktop\release\  (CVP Attendance Setup *.exe)' -ForegroundColor Green