# BlueChip Rewards — Setup Checklist (phone-only, no computer needed)

Everything below can be done from a phone using **github.com** and
**supabase.com** in a browser. You never need to install Flutter, Android
Studio, or any command-line tool. GitHub Actions builds the app for you.

Work top to bottom. Each phase works on its own — you get a running app after
Phase 3 and can add Google Sign-In, ads, and Play publishing later.

---

## What you'll create accounts for
- **GitHub** (already have it — this repo)
- **Supabase** — the backend/database — https://supabase.com (free tier is fine)
- **Google Cloud / AdMob** — only when you want Google Sign-In and real ads

---

## The single list of GitHub secrets
Add these at **repo → Settings → Secrets and variables → Actions → New
repository secret**. Add only the ones for the phases you've reached.

| Secret | Needed for | Where it comes from |
|---|---|---|
| `SUPABASE_URL` | app + builds | Supabase → Project Settings → API → Project URL |
| `SUPABASE_ANON_KEY` | app + builds | Supabase → Project Settings → API → `anon` `public` key |
| `GOOGLE_WEB_CLIENT_ID` | Google Sign-In | Google Cloud → Credentials → Web OAuth client ID |
| `ADMOB_APP_ID` | real ads | AdMob → App settings → App ID (`ca-app-pub-…~…`) |
| `ADMOB_REWARDED_AD_UNIT` | real ads | AdMob → Ad unit → Rewarded unit ID (`ca-app-pub-…/…`) |
| `ANDROID_KEYSTORE_BASE64` | Google Sign-In + Play | "Generate Signing Keystore" workflow |
| `ANDROID_KEYSTORE_PASSWORD` | Google Sign-In + Play | same workflow |
| `ANDROID_KEY_ALIAS` | Google Sign-In + Play | same workflow |
| `ANDROID_KEY_PASSWORD` | Google Sign-In + Play | same workflow |

> ⚠️ The **anon key is public by design** and safe to ship in the app (Row Level
> Security protects your data). **Never** put the Supabase **service-role** key
> anywhere in this repo or in the app — it is only used inside Supabase.

---

## Phase 1 — Create the database (Supabase)

1. Create a project at **supabase.com** → wait for it to finish provisioning.
2. Open **SQL Editor** → **New query**.
3. In this repo, open **`supabase/schema_all.sql`**, tap **Copy raw file**,
   paste it into the SQL Editor, and press **Run**. That's the entire backend —
   tables, security rules, reward logic, and starter data. (It's safe to re-run.)
4. Go to **Project Settings → API** and copy **Project URL** and the **`anon`
   `public`** key into the GitHub secrets `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
5. Go to **Authentication → Providers** and enable **Email**. (Leave "Confirm
   email" on for verification, or off to let users log in immediately.)

## Phase 2 — Build & install the app

1. On GitHub, open the **Actions** tab → **Release Build** → **Run workflow**
   (keep the default tag, or change it). Wait ~10 minutes.
2. Open the **Releases** section of the repo → open the new release → download
   the **`.apk`** onto your phone.
3. Tap the downloaded file → allow **"install unknown apps"** if prompted →
   install → open the app.
4. Register with email and password. You now have a working rewards app 🎉
   (Daily reward, mining, scratch, quiz, tasks, wallet, withdrawals all work.)

> Prefer the fast path? The **Flutter CI** workflow also uploads a debug APK as
> a build artifact on every push — but the **Release Build** APK is easier to
> download and install from a phone.

## Phase 3 — Make yourself the admin

1. In the app, make sure you've signed up at least once.
2. Supabase → **SQL Editor** → open **`supabase/ADMIN_SETUP.sql`**, paste it,
   change the email to yours, and **Run**.
3. Reopen the app → **Profile → Admin panel** appears. From **Config** you can
   change every reward value, limit, and payment method **without rebuilding the
   app**.

---

## Phase 4 — Google Sign-In (optional)

Google Sign-In needs a stable signing key so Google recognises your app.

> ⚠️ The keystore-generator prints your signing key into the workflow log so you
> can copy it from a phone. **Do this only on a private repository** and delete
> the run right after you save the secrets. (Make the repo private at
> repo → Settings → General → Danger Zone if it isn't already.)

1. GitHub → **Actions → Generate Signing Keystore → Run workflow**. When it
   finishes, open the run **Summary**: it lists the four `ANDROID_*` secret
   values and your **SHA-1 / SHA-256** fingerprints. Copy the four values into
   GitHub secrets (the long `ANDROID_KEYSTORE_BASE64` is printed in the job log).
   **Delete that workflow run afterwards.**
2. In **Google Cloud Console** (console.cloud.google.com):
   - Create/select a project → **APIs & Services → Credentials**.
   - **Create Credentials → OAuth client ID → Android**: package name
     `com.bluechip.bluechip_rewards`, and paste the **SHA-1** from step 1.
   - **Create Credentials → OAuth client ID → Web application**. Copy its
     **Client ID** into the `GOOGLE_WEB_CLIENT_ID` secret.
   - Configure the **OAuth consent screen** if asked.
3. In **Supabase → Authentication → Providers → Google**: enable it and paste
   the **Web** client ID and secret.
4. Run **Release Build** again and reinstall the APK. Google Sign-In now works.

## Phase 5 — Real ads with AdMob (optional)

1. At **admob.google.com**, create an app and a **Rewarded** ad unit.
2. Put the **App ID** in `ADMOB_APP_ID` and the **rewarded unit ID** in
   `ADMOB_REWARDED_AD_UNIT` (GitHub secrets).
3. Run **Release Build** again. (Until you do this, the app safely uses Google's
   public **test** ad IDs.)
4. *(Optional hardening)* Deploy the `admob-ssv-callback` Supabase Edge Function
   and set its URL as the AdMob **server-side verification** callback.

## Phase 6 — Publish to Google Play (optional)

1. Complete Phase 4 (you need the keystore secrets).
2. Run **Release Build** → download the **`.aab`** from the Release.
3. In the **Google Play Console**, create your app and upload the `.aab`.
   (Enrolling in **Play App Signing** is recommended; keep your keystore safe.)

---

## Configure without rebuilding
Almost everything about earning is data, not code. From the in-app **Admin →
Config** tab (or Supabase → Table editor → `app_settings`) you can change: daily
reward amounts and streak bonus, mining rate and session length, scratch-card
odds and daily cap, ad reward and limits, referral reward, minimum withdrawal,
and more — changes apply instantly, no new build needed. Payment methods live in
the `payment_methods` table; tasks and quizzes in `tasks` / `quizzes`.

## Optional: deploy the backend with the CLI instead of copy-paste
If you later use a computer, the **Supabase Deploy** workflow can push
`supabase/migrations` and the edge function automatically. Add secrets
`SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, and `SUPABASE_DB_PASSWORD`; it
runs on changes to `supabase/**` on `main`, or manually from the Actions tab.

## Security summary
- No secret keys are committed. `assets/.env` holds only placeholders and the
  **public** anon key at build time (injected from secrets).
- The service-role key never leaves Supabase.
- Keystores, `key.properties`, and `google-services.json` are git-ignored.
- All points/money logic runs on the server behind Row Level Security; the app
  can never change a balance directly.
