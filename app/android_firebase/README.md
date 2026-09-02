# Firebase / FCM configuration for Android

`google-services.json` in this folder is a **structurally valid placeholder** — it
lets the Android build succeed and the Firebase SDK initialise, but it points at
no real Firebase project, so push tokens cannot be obtained until you supply a
real config. It contains **no secrets** (a client config never does).

## Activating real push notifications

1. In the [Firebase console](https://console.firebase.google.com/), create a
   project and add an **Android app** with package name
   `com.bluechip.bluechip_rewards`. (Add your release signing SHA-1 too.)
2. Download that app's `google-services.json`.
3. Base64-encode it and store it as the GitHub Actions secret
   **`GOOGLE_SERVICES_JSON_BASE64`**:
   ```
   base64 -w0 google-services.json
   ```
   CI (`tool/patch_android.py`) writes it over this placeholder at build time.
   Locally, place your real `google-services.json` here to override the
   placeholder before running `flutter build`.
4. Create a **service account** (Project settings → Service accounts → Generate
   new private key) and store the whole JSON as the **Supabase secret**
   `FCM_SERVICE_ACCOUNT` (used by the `push` edge function to call FCM HTTP v1).
   Never commit this file — it is a real credential.

The client code, the gradle wiring, the token lifecycle, and the `push` edge
function are all already in place; supplying the two credentials above is the
only step that turns real push delivery on.
