# CVP Attendance: Office server (works without internet)

The database runs on ONE office computer (the "server"). Every desktop and phone connects to it over the office Wi-Fi / LAN.
Internet is not needed. The server computer must stay switched on.

## A. Server computer (once)

1. Windows 10/11 64-bit, 8 GB RAM or more, 20 GB free disk. Give it a fixed address (router: "DHCP reservation").
2. Install **Docker Desktop** (https://www.docker.com/products/docker-desktop), restart the computer, open Docker Desktop and wait for "Engine running".
   (Needs internet only for this download and the first start.)
3. Install **Node.js LTS** (https://nodejs.org).
4. Copy the whole `CVP_Attendance_Mobile` folder to this computer (pen drive).
5. Open **PowerShell as Administrator**:
   ```powershell
   cd <folder>\CVP_Attendance_Mobile\server
   Set-ExecutionPolicy -Scope Process Bypass
   .\setup-server.ps1
   ```
   It downloads the database the first time (10-20 minutes, internet needed once), loads the tables, asks for the
   Admin username / name / password, opens the port, sets up auto-start + a nightly backup, and prints the **connection code**.
   The code is also saved in `server\connection-code.txt`.

## B. Every desktop

1. Install `CVP Attendance Setup.exe` (or run `CVP Attendance Portable.exe`).
2. Login screen -> **Server settings** -> paste the connection code -> **Connect to this server**.
3. Sign in. Done. The app remembers the server.

## C. Phones

Phones need an APK built for the office server (plain http is allowed in this version): `eas build -p android --profile preview`.
Install it, then use **Server settings** on the login screen with the same connection code. The phone must be on the office Wi-Fi.

## D. Daily use

- The server starts by itself when you sign in to Windows on the server computer. Keep it on.
- `.\stop-server.ps1` stops it, `.\start-server.ps1` starts it. Data is kept.
- **Backup** runs every night at 11:00 PM into `server\backups`. Copy that folder to a pen drive / second disk now and then:
  `.\backup-db.ps1 -To "E:\CVP-backup"`.
- **Restore:** `.\restore-db.ps1 -File "...\cvp_db_xxxx.sql"`.

## E. Things to know

- Data on the office server is separate from the internet (Supabase cloud) data. Start fresh, or move the old data over first.
- The server has no internet "update" channel: after you change the app, make a new installer and copy it to the desktops.
- Keep the office Wi-Fi/LAN trusted. Only port 54321 is opened; the database ports are blocked by the firewall.
- If the server computer breaks, restore the last backup on a new server computer: run `setup-server.ps1`, then `restore-db.ps1`.
