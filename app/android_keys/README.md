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

SHA-1: `03:8B:BE:49:DE:B1:FF:61:39:F5:8B:CB:81:AD:14:C2:BB:A9:23:64`

Register this SHA-1 (with package `com.bluechip.bluechip_rewards`) as an Android
OAuth 2.0 client in the Google Cloud project used by the Supabase Google
provider. The release build's SHA-1 must be registered separately.
