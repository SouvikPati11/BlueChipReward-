# BlueChip Rewards

A production-oriented Android earning & rewards platform. Users earn **BCP
(BlueChip Points)** through Daily Rewards, Mining, Scratch Cards, Rewarded Ads,
a Daily Quiz, Tasks and Referrals. Every point flows through one
server-authoritative ledger; withdrawals are reviewed manually by an admin.

- **App:** Flutter (Riverpod, go_router) — `app/`
- **Backend:** Supabase (PostgreSQL + RLS + SECURITY DEFINER RPCs + an Edge
  Function for AdMob SSV) — `supabase/`
- **Ads:** Google AdMob rewarded ads
- **CI:** GitHub Actions (`.github/workflows/`)

## Security model (the important part)

The client is **never** the source of truth for points or money.

- All balance changes go through `SECURITY DEFINER` functions that lock the
  wallet row and append to an **immutable ledger** (`wallet_transactions`).
- Row Level Security lets a user read only their own rows; **no** table-level
  write grants exist, so points can only move via the vetted RPCs.
- Reward amounts, limits and availability live in `app_settings` and are
  decided server-side — the client only sends intent.
- Admin is a server role (`user_roles`) enforced by `is_admin()` in every admin
  RPC and RLS policy. There is no hardcoded admin and no client admin flag.
- Quiz answer keys never leave the server; scratch/ad/mining/referral rewards
  are all computed server-side with idempotency and anti-abuse guards.

## Setup

> **📱 On a phone with no computer?** Follow **[SETUP.md](SETUP.md)** — a
> step-by-step checklist that configures Supabase, Google Sign-In, AdMob, and
> builds an installable APK entirely from github.com and supabase.com. The
> notes below are the equivalent flow for a computer with the CLIs installed.

### 1. Supabase
1. Create a project at supabase.com.
2. Push the schema & functions:
   ```bash
   cd supabase
   supabase link --project-ref <your-ref>
   supabase db push
   supabase functions deploy admob-ssv-callback --no-verify-jwt
   ```
   (or let the `Supabase Deploy` GitHub Action do it — see secrets below).
3. In **Auth → Providers**, enable **Email** and **Google**.
4. Sign up once in the app, then run `supabase/ADMIN_SETUP.sql` (edit the email)
   to make yourself an admin.

### 2. App config
Set these in `app/assets/.env` (or via `--dart-define` / CI secrets). The
Supabase anon key is public by design (protected by RLS); **never** put the
service-role key in the app.
```
SUPABASE_URL=...
SUPABASE_ANON_KEY=...
GOOGLE_WEB_CLIENT_ID=...          # OAuth web client id for native Google sign-in
ADMOB_REWARDED_AD_UNIT=...        # defaults to Google's test unit
```

### 3. Run / build
```bash
cd app
flutter pub get
flutter create --platforms=android --org com.bluechip --project-name bluechip_rewards .
python3 tool/patch_android.py    # adds INTERNET perm + AdMob app id + minSdk
flutter run                      # or: flutter build appbundle --release
```

## CI secrets
`Flutter CI` builds on every push. For a real (non-test) build, add repo secrets:
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `GOOGLE_WEB_CLIENT_ID`,
`ADMOB_REWARDED_AD_UNIT`, `ADMOB_APP_ID`.
`Supabase Deploy` needs: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`,
`SUPABASE_DB_PASSWORD`.

## Architecture
```
app/lib/
  core/        config, theme, router, supabase client, errors, shared widgets
  models/      immutable data models
  data/        repositories (all Supabase access)
  providers/   Riverpod providers
  features/    auth, home, earn/*, wallet, withdrawal, referral, profile, admin
supabase/
  migrations/  schema, functions, RLS, seed
  functions/   admob-ssv-callback edge function
```
Adding a new earning method: add a settings key + an RPC + a repository method +
a screen. The ledger, wallet and referral systems need no changes.
