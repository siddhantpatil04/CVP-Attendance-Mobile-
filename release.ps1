# Publishes a new version of CVP Attendance to EVERYONE, with no new install:
#   .\release.ps1 -Message "New salary report"
# 1. builds the website and uploads it (Netlify): every installed Windows desktop app and every browser loads it next time it opens
# 2. sends the phone update over the air (Expo EAS Update): every installed Android app gets it next time it opens
# 3. (optional) press "Publish Update" in the app (Admin -> More -> App Updates) so everyone signs out and loads it straight away
# Needed only when you changed the app's code. Database changes: paste cvp_attendance_schema.sql in Supabase.
param([string]$Message = 'App update')
$ErrorActionPreference = 'Stop'
Set-Location "$PSScriptRoot\app"
$env:EAS_NO_VCS = '1'

Write-Host '1/3  Building the web / desktop app ...' -ForegroundColor Cyan
npx expo export -p web
Write-Host '     Uploading to Netlify (first time only: npx netlify-cli login, then npx netlify-cli link) ...' -ForegroundColor Cyan
npx netlify-cli deploy --dir dist --prod

Write-Host '2/3  Sending the phone update (EAS Update) ...' -ForegroundColor Cyan
foreach ($branch in 'preview', 'production') {
  npx eas-cli update --branch $branch --message $Message --non-interactive
}

Write-Host ''
Write-Host 'Done. Desktops, browsers and phones pick the update up the next time the app is opened.' -ForegroundColor Green
Write-Host '3/3  Optional: Admin -> More -> App Updates -> Publish Update makes everyone sign out and load it right now.' -ForegroundColor Green