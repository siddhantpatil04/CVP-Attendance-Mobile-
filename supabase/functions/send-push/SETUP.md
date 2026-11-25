# Phone notifications - one-time setup (do these in order)

## 1. Firebase (Android push)
1. Open https://console.firebase.google.com -> **Add project** -> name it `CVP Attendance` -> Create.
2. In the project: **Project settings (gear icon) -> General -> Your apps -> Add app -> Android**.
3. Android package name: `com.cvpatil.attendance` -> Register app.
4. Download **google-services.json** and put it in the `app/` folder (next to `app.json`). `app.json` already points to `./google-services.json`.
5. **Project settings -> Service accounts -> Generate new private key** -> a `.json` file is downloaded (keep it private, never share or commit it).

## 2. Upload the FCM V1 key to Expo
In a terminal, inside `app/`:
```
eas credentials
```
Choose **Android -> the build profile (preview) -> Google Service Account -> Manage your Google Service Account Key for Push Notifications (FCM V1) -> Upload a new service account key**, and select the file from step 1.5.

## 3. iPhones (only if iPhones are used)
`eas credentials` -> **iOS** -> **Push Notifications: Manage your Apple Push Notifications service key** -> create / upload an APNs key (needs an Apple Developer account).

## 4. Supabase
1. Run `supabase/notifications.sql` in the SQL Editor (after a backup).
2. Deploy the function:
   ```
   supabase functions deploy send-push --no-verify-jwt
   ```
3. Set the secrets (any long random text for the first one):
   ```
   supabase secrets set PUSH_WEBHOOK_SECRET=put-a-long-random-text-here
   supabase secrets set EXPO_ACCESS_TOKEN=your-expo-token      (optional: expo.dev -> Account settings -> Access tokens)
   ```
4. Create the Database Webhook: **Supabase Dashboard -> Database -> Webhooks -> Create a new hook**
   - Name: `send-push`   Table: `notifications`   Events: **Insert** only
   - Type: **Supabase Edge Functions** (or HTTP Request to `https://<project-ref>.supabase.co/functions/v1/send-push`), method POST
   - HTTP header: `x-webhook-secret` = the same text as `PUSH_WEBHOOK_SECRET`
   - Create.

## 5. Build the new APK (version 1.1.0)
```
cd app
npm install
eas build -p android --profile preview
```
Share the APK. Every employee installs it once and logs in (allow notifications when asked). Old 1.0.0 APKs keep working; they simply get no push.
Later JavaScript changes: `eas update --branch preview`. Desktop: `build-desktop.ps1`.
