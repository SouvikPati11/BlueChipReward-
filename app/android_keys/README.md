# Debug keystore (NOT secret)

`debug.keystore` is a **stable debug signing certificate** used for the Flutter
`--debug` build. Committing it is intentional and safe:

- It signs **debug/test builds only** — never the Play Store release, which is
  signed separately from `ANDROID_KEYSTORE_BASE64` (and Play App Signing).
- It uses the well-known debug password `android` (alias `androiddebugkey`),
  exactly like Android's default `~/.android/debug.keystore`.

Why it exists: CI's auto-generated debug keystore is unique per run, so its
SHA-1 can never be registered for Google Sign-In → `ApiException: 10`
(DEVELOPER_ERROR). A fixed keystore gives the debug build one permanent SHA-1
that can be registered once.

## Fingerprints (a cert fingerprint is public, not a secret)

```
Package name : com.bluechip.bluechip_rewards
SHA-1        : 03:8B:BE:49:DE:B1:FF:61:39:F5:8B:CB:81:AD:14:C2:BB:A9:23:64
SHA-256      : A5:14:50:1A:78:22:B2:75:B8:23:F0:F5:A8:D0:14:D3:84:96:7B:32:AD:F0:11:08:5F:9A:93:9C:94:37:94:94
```

Regenerate them anytime with:

```
keytool -list -v -keystore app/android_keys/debug.keystore \
  -storepass android -alias androiddebugkey
```

## Making Google Sign-In work on the DEBUG build

Google authorizes the app by matching its **(package name, signing SHA-1)** pair
against an **Android OAuth client** in the *same Google Cloud project* that owns
`GOOGLE_WEB_CLIENT_ID` (the Web client passed as `serverClientId`). The debug and
release builds share the package name but have different signatures, so **each
signature needs its own Android OAuth client** in that project:

- Release build → `B4:54:…` (already registered — leave it unchanged).
- Debug build → `03:8B:…` (the fingerprint above — register this).

### One-time registration (Google Cloud Console)

1. Open <https://console.cloud.google.com/apis/credentials> and select the
   **same project** that contains the Web client id used by
   `GOOGLE_WEB_CLIENT_ID` / the Supabase Google provider.
2. **Create Credentials → OAuth client ID**.
3. Application type: **Android**.
4. Name: e.g. `BlueChip Rewards Android (debug)`.
5. Package name: `com.bluechip.bluechip_rewards`.
6. SHA-1 certificate fingerprint:
   `03:8B:BE:49:DE:B1:FF:61:39:F5:8B:CB:81:AD:14:C2:BB:A9:23:64`
7. **Create**. No app change is needed — you do not copy this Android client id
   anywhere; Play Services matches it server-side.

Do **not** edit or delete the existing release Android client (`B4:54`) or the
Web client. Nothing about release signing changes.

Propagation can take a few minutes. After it is live, a debug APK built from
this repo (unchanged, same `03:8B` signature) will complete Google Sign-In.
