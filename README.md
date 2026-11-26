# CVP Attendance: Mobile App (Android + iOS)

**C. V. PATIL & ASSOCIATES**: employee attendance with a shared cloud database and live admin dashboard.

```
CVP_Attendance_Mobile/
├── supabase/
│   ├── cvp_attendance_schema.sql       ← run once in Supabase SQL Editor (the full database)
│   └── functions/admin-users/index.ts  ← server function: create logins, reset passwords, deactivate
├── app/                                ← the mobile app (Expo / React Native, one code for Android + iOS)
└── tools/migrate_sqlite_to_supabase.py ← optional: copy data from the old Streamlit SQLite file
```

## How it works

```
Employee phone (Android)  ──check_in()──►  Supabase (Mumbai)  ──Realtime──►  Admin phone (iPhone)
 taps "Check In" 9:30                       • server time (IST), not phone time   row appears in ~1 sec:
                                            • blocks double check-in              "Rahul Patil  09:30  Checked In"
                                            • marks Late vs shift start
                                            • saves + writes audit log
```

All features of the Streamlit app are included:

- **Employee:** Dashboard, Check In / Check Out, Site Selfie, Attendance (timesheet, calendar, CSV), Leave (balances, apply, cancel), Regularization, Holiday Calendar, Team, Profile and password change.
- **HR / Admin:** Live Dashboard (real-time), Approvals (leave and correction), Employees (add, edit role/department/shift/site access, reset password, activate/deactivate), Company Reports (summary and day-wise CSV), Selfie Attendance review, Holidays Setup and Audit Trail.

---

## STEP 1: Create the Supabase project (10 min)

1. Go to <https://supabase.com>, sign up, then click **New project**.
   - Name: `cvp-attendance`
   - Region: **South Asia (Mumbai)**
   - Choose a strong database password and save it.
2. **Authentication → Sign In / Providers → Email**:
   - Turn **OFF** "Allow new users to sign up". Only the admin creates accounts.
   - Turn **OFF** "Confirm email".
3. **Project Settings → API**: copy the **Project URL** and the **anon public** key. You need them in Step 4.
   Never put the `service_role` key in the app.

## STEP 2: Create the database (2 min)

1. Supabase Dashboard → **SQL Editor** → **New query**.
2. Open `supabase/cvp_attendance_schema.sql`, copy everything, paste it, and click **Run**.
   The result should show "Success". The file is safe to run again.

This creates the tables, the security rules (employees only see their own data), the check-in/leave/approval functions, the live updates, the private `selfies` photo storage and the default leave types (Casual 12, Sick 12, Annual 24, Comp-Off, Loss of Pay).

## STEP 3: Create the first Admin and deploy the account function (10 min)

### 3a. First Admin login
Dashboard → **Authentication → Users → Add user → Create new user**
- Email: `admin@cvp-attendance.app` (any e-mail format works; it is never mailed)
- Password: a strong password (12+ characters)
- Tick **Auto Confirm User**

**The first account ever created automatically becomes Admin.** Its username is the part before `@` (here `admin`).
Sign in on the app's **Admin Login** tab with `admin` and that password.

### 3b. Deploy the `admin-users` function
The app needs this function to add employees, reset passwords and deactivate accounts. It keeps the secret key on the server.

**Option A: from the dashboard (no installation)**
Dashboard → **Edge Functions → Deploy a new function → Via Editor**. Name it exactly `admin-users`, paste the contents of `supabase/functions/admin-users/index.ts`, then click **Deploy**.

**Option B: from the command line** (inside the `CVP_Attendance_Mobile` folder)
```bash
npx supabase login
npx supabase functions deploy admin-users --project-ref YOUR_PROJECT_REF
```
`YOUR_PROJECT_REF` is the `xxxx` in `https://xxxx.supabase.co`.

Optional: generated login e-mails use the form `username@cvp-attendance.app`. To use your company domain instead, add the secret `LOGIN_EMAIL_DOMAIN` (for example `yourcompany.com`) under Edge Functions → Secrets. Employees always log in with their **username**.

## STEP 4: Run the app on your phone (15 min)

Install **Node.js 20 or newer** (<https://nodejs.org>, LTS version), then open a terminal (VS Code → Terminal):

```bash
cd CVP_Attendance_Mobile/app
npm install
copy .env.example .env        # Windows   (Mac/Linux: cp .env.example .env)
```

Edit `.env` and paste your values from Step 1:
```
EXPO_PUBLIC_SUPABASE_URL=https://xxxx.supabase.co
EXPO_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOi...
```

Then start the app:
```bash
npx expo start
```
Install **Expo Go** from the Play Store or App Store and scan the QR code. Your phone and PC must be on the same Wi-Fi; if they aren't, run `npx expo start --tunnel`.

## STEP 4b: Run the same app on a desktop / laptop (browser)

The same code runs in Chrome / Edge on any computer. On a wide window (900 px or more) it switches to the
**desktop layout**: a fixed left menu (all pages, live clock, sync status, sign out), wider pages and KPI cards in one row.
On a phone, or a narrow window, it shows the normal bottom tabs. Resizing the window keeps you on the same page.

**Try it on your PC** (inside `CVP_Attendance_Mobile/app`, after Step 4):
```bash
npx expo start --web        # opens http://localhost:8081 in your browser
```
(Or run `npx expo start` and press **w**. Press **a** / scan the QR to open the phone version at the same time.)

**Put it online for the whole office** (one link everyone opens on their desktop):
```bash
npx expo export -p web      # builds the website into the "dist" folder
npx serve dist -s -l 8080   # optional: test the built site at http://localhost:8080
```
Then upload the `dist` folder to any static host, for example:
- **Netlify (easiest):** open <https://app.netlify.com/drop> and drag the `dist` folder onto the page. You get a link like `https://cvp-attendance.netlify.app`.
- **Netlify from the terminal:** `npx netlify-cli deploy --dir dist --prod`
- **Vercel:** `npx vercel dist --prod`

Re-run `npx expo export -p web` and upload again whenever you change the code or the `.env` values (the Supabase URL and key are baked into the website at build time).

### Phone + desktop stay in sync
Phone and desktop both talk to the same Supabase database, so a check-in, leave request, approval, holiday or employee change made on one shows on the other within about a second, with no refresh. On top of the live connection, every screen reloads automatically when:
- the browser tab or phone app comes back to the front, and
- the internet comes back after a drop (Wi-Fi change, laptop waking from sleep).

The left menu shows **Live sync on** while the connection is open. If you ran the SQL file before this update, run it once more (it is safe to re-run) so **Work Sites** changes also sync live.

## STEP 5: Test real-time sync (phone + phone, or phone + desktop)

1. **Phone A** (admin): Admin Login → **Employees → Add Employee** (for example username `emp014`, password `Welcome@2026x`).
2. **Phone A** (or the desktop browser): open the **Live** tab / **Live Dashboard** and leave it open.
3. **Phone B**: Employee Login → `emp014` → tap **Check In**.
4. Within about a second, Phone A shows a green banner **"Rahul Patil checked in at 09:30 AM"**, and the list and counts update without a refresh.

Also try:
- Checking in twice. It is blocked.
- Applying for leave on Phone B. Phone A's Approvals tab updates live.
- Approving it. Phone B's balance updates.

## STEP 6: Build the installable apps

```bash
npm install -g eas-cli
eas login                    # free Expo account
eas build:configure          # once: links the project to your Expo account
```

| Goal | Command | Result |
|---|---|---|
| Android test APK (send on WhatsApp/e-mail) | `eas build -p android --profile preview` | `.apk` download link |
| Google Play Store | `eas build -p android --profile production` then `eas submit -p android` | `.aab` uploaded to Play Console |
| iPhone (TestFlight / App Store) | `eas build -p ios --profile production` then `eas submit -p ios` | needs Apple Developer account ($99/yr) |

The cloud build means you don't need a Mac or Android Studio.

**Important:** your `.env` file is NOT uploaded to the cloud builder. Before the first build, save the two values in EAS (once):
```bash
eas env:create --name EXPO_PUBLIC_SUPABASE_URL --value https://xxxx.supabase.co --environment preview --environment production --visibility plaintext
eas env:create --name EXPO_PUBLIC_SUPABASE_ANON_KEY --value YOUR-ANON-KEY --environment preview --environment production --visibility plaintext
```
(Or add them on expo.dev → your project → Environment variables.) If the built app says "App not configured", this step was missed.

App IDs are set in `app/app.json`: `com.cvpatil.attendance`. Change them before the first store upload if you want; they cannot change later.

## STEP 7 (optional): Move old data from the Streamlit app

```bash
cd CVP_Attendance_Mobile/tools
set SUPABASE_URL=https://xxxx.supabase.co
set SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
python migrate_sqlite_to_supabase.py --db path\to\cvp_attendance.sqlite3 --dry-run
python migrate_sqlite_to_supabase.py --db path\to\cvp_attendance.sqlite3
```

Old passwords cannot be copied, because they are stored as one-way hashes. The script gives every user a temporary password and saves it to `migrated_passwords.csv`. Share each password privately, then delete the file.

---

## Business rules (same as the Streamlit app)

| Rule | Where enforced |
|---|---|
| Time comes from the server in IST, so the phone clock can't be faked | `check_in()` / `check_out()` |
| One check-in and one check-out per day | unique (user, date) + function checks |
| Late = check-in minute after the employee's shift start | `check_in()` |
| Day status: Upcoming → Holiday → Leave → Present / Checked In → Rest Day (Sat/Sun) → Absent | `_month_attendance()` |
| Leave counts working days only (weekly offs and holidays excluded), with the sandwich rule (an off day between two leave days counts as leave unless a public holiday is in between), no overlaps, one calendar year, balance checked (except Loss of Pay) | `apply_leave()`, re-checked on approval |
| Regularization approval overwrites that day's in/out | `review_regularization()` |
| Site selfie only for "Site Employee" accounts; photo + site name required | `check_in()` + storage policy |
| Only an Admin can create or change Admin accounts; you cannot change your own role or deactivate yourself | `admin_update_profile()` + `admin-users` |
| Every action is audited | `audit_log` |

## Changing things later

- **Company name, address, password length:** `app/src/config.ts`
- **Colours:** `app/src/theme.ts`
- **Leave quotas:** Supabase → Table Editor → `leave_types`
- **App icon:** replace `app/assets/icon.png` (1024×1024). The current icon is enlarged from the small logo, so a high-resolution logo will look sharper.
- **Weekend rule (Sat + Sun):** `extract(isodow …) >= 6` in the SQL file

## Troubleshooting

| Problem | Fix |
|---|---|
| "App not configured" on login | `.env` is missing or wrong. Restart with `npx expo start -c` |
| "Invalid username or password" | The account is inactive or the username is wrong. Usernames are lower-case |
| Add Employee says "Failed to send a request to the Edge Function" | Step 3b not done, or the function name isn't exactly `admin-users` |
| Live dashboard shows CONNECTING | Check the internet connection. In Supabase → Database → Publications, `supabase_realtime` must include `attendance` (the SQL does this) |
| Selfie upload fails | The employee must have **Site Employee** turned on (Employees → tap name) |

## Desktop app and automatic updates

**Desktop app (Windows / Mac):** open the hosted website (see "Put it online" above) in Edge or Chrome and click the
**Install** icon in the address bar ("Install CVP Attendance"). It becomes a normal desktop app with its own window and
Start-menu icon. It always loads the newest files, so there is nothing to re-install.

**One-time setup**
1. Hosting: `cd app`, then `npx netlify-cli login` and `npx netlify-cli link` (or drag the `dist` folder to https://app.netlify.com/drop once).
2. Phones: build the app once with EAS (`eas build -p android --profile preview`). From then on JS changes go to phones over the air.
3. Supabase: run the latest `supabase/cvp_attendance_schema.sql` (section 22 adds the update switch).

**Every time you change the code**
```powershell
cd C:\Users\cvpce\Desktop\ui1\CVP_Attendance_Mobile
.\release.ps1 -Message "what changed"
```
This builds and uploads the web / desktop app and sends the phone update. Then open the app as Admin, go to
**More -> App Updates -> Publish Update**. Every phone and every installed desktop app signs out, loads the new
version and shows the login page; the employees sign in again and see the update.

Changes that add a new phone permission or a new native package need a new `eas build` (a new APK); everything else goes over the air.

## Windows installer (desktop app)

`desktop/release/CVP Attendance Setup 1.0.0.exe` is a normal Windows installer (a copy is on your Desktop).
- **Share it:** copy that one `.exe` file to a pen drive, double-click it on the other computer and click Install.
  It adds a **CVP Attendance** icon to the Desktop and Start menu. Staff open it like any program: no VS Code, no terminal.
- **Live data:** the app talks to Supabase directly, so check-ins, leaves and approvals appear live on every desktop.
- **Always the desktop layout:** the window opens maximized and never smaller than 1000 px wide.
- **After you change the code:** run `.\build-desktop.ps1` to make a new installer and copy it to the other computers again,
  OR put your Netlify address in `desktop/app-config.json` (`"url": "https://your-site.netlify.app"`) before building:
  those desktops then always load the newest version from the internet, and the Admin's **Publish Update** button makes them sign in again.

---
## Note: some folders are packed (GitHub website upload limit)
The GitHub website only accepts fewer than 100 files per upload, so two folders are stored as single files:

- `app/src.tar.gz` - the app code (`app/src`). Netlify unpacks it automatically during the build (see `netlify.toml`).
- `supabase/sql_files.tar.gz` - the SQL scripts (`supabase/*.sql` and sub-folders). Not needed for the build.

To unpack on a PC: open PowerShell in that folder and run `tar -xzf src.tar.gz` (or `tar -xzf sql_files.tar.gz`).
To pack again after editing (in the `app` folder): `tar -czf src.tar.gz src`
