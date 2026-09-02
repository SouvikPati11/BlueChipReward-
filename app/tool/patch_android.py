#!/usr/bin/env python3
"""Patch the Flutter-generated Android project for BlueChip Rewards.

Run AFTER `flutter create --platforms=android .`. Idempotent.

It applies the three things the generated scaffold does not give us:
  1. INTERNET permission in the *release* manifest (Flutter only adds it to
     the debug/profile manifests, which breaks Supabase in release builds).
  2. The AdMob application id meta-data (google_mobile_ads crashes without it).
  3. A minSdkVersion high enough for supabase_flutter + google_mobile_ads.

The AdMob app id can be overridden with the ADMOB_APP_ID env var; it defaults
to Google's public test app id, which is safe to ship until you swap it.
"""
import base64
import os
import re
import sys

HERE = os.path.dirname(__file__)
ANDROID = os.path.join(HERE, "..", "android")
MANIFEST = os.path.join(ANDROID, "app", "src", "main", "AndroidManifest.xml")
APP_GRADLE_GROOVY = os.path.join(ANDROID, "app", "build.gradle")
APP_GRADLE_KTS = os.path.join(ANDROID, "app", "build.gradle.kts")
SETTINGS_GRADLE_GROOVY = os.path.join(ANDROID, "settings.gradle")
SETTINGS_GRADLE_KTS = os.path.join(ANDROID, "settings.gradle.kts")
GOOGLE_SERVICES_DST = os.path.join(ANDROID, "app", "google-services.json")
GOOGLE_SERVICES_PLACEHOLDER = os.path.join(
    HERE, "..", "android_firebase", "google-services.json")

# Pin the Google Services Gradle plugin and the desugaring library. Both are
# compatible with the AGP that Flutter 3.32's scaffold generates.
GOOGLE_SERVICES_PLUGIN_VERSION = "4.4.2"
DESUGAR_LIB = "com.android.tools:desugar_jdk_libs:2.1.4"
# A default FCM notification channel id — the client creates a channel with the
# same id so background/terminated notifications land in it with the right
# importance.
FCM_CHANNEL_ID = "bluechip_default"

# Google's public test AdMob *app* id. A valid app id looks like
# "ca-app-pub-################~##########" (note the '~'). Passing an ad *unit*
# id (which uses '/') or any malformed value here makes the AdMob SDK crash the
# app natively at process start, so we validate and fall back to the test id.
TEST_APP_ID = "ca-app-pub-3940256099942544~3347511713"
_raw_app_id = os.environ.get("ADMOB_APP_ID", "").strip()
if re.fullmatch(r"ca-app-pub-\d{10,}~\d{6,}", _raw_app_id):
    ADMOB_APP_ID = _raw_app_id
    _APP_ID_SOURCE = "provided ADMOB_APP_ID"
else:
    ADMOB_APP_ID = TEST_APP_ID
    _APP_ID_SOURCE = "test app id (ADMOB_APP_ID unset or invalid)"
MIN_SDK = "23"


def patch_manifest():
    with open(MANIFEST, "r", encoding="utf-8") as f:
        xml = f.read()

    # 0. Launcher/app display name must read "BlueChip Rewards" (flutter create
    #    stamps the project name "bluechip_rewards").
    xml = re.sub(r'android:label="[^"]*"',
                 'android:label="BlueChip Rewards"', xml, count=1)

    # 0b. Round launcher icon (adaptive + legacy round mipmaps are supplied by
    #     the android_res overlay). Add android:roundIcon next to android:icon.
    if "android:roundIcon" not in xml:
        xml = re.sub(
            r'(android:icon="@mipmap/ic_launcher")',
            r'\1\n        android:roundIcon="@mipmap/ic_launcher_round"',
            xml, count=1)

    # 1. INTERNET permission (before <application>)
    if "android.permission.INTERNET" not in xml:
        xml = xml.replace(
            "<application",
            '<uses-permission android:name="android.permission.INTERNET"/>\n'
            "    <application",
            1,
        )

    # 1b. POST_NOTIFICATIONS (Android 13+) so FCM/local notifications can show.
    if "android.permission.POST_NOTIFICATIONS" not in xml:
        xml = xml.replace(
            "<application",
            '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n'
            "    <application",
            1,
        )

    # 1b2. RECEIVE_BOOT_COMPLETED so scheduled local reminders are restored
    #      after a device reboot (they already fire while the app is merely
    #      closed; this covers reboots too).
    if "android.permission.RECEIVE_BOOT_COMPLETED" not in xml:
        xml = xml.replace(
            "<application",
            '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>\n'
            "    <application",
            1,
        )

    # 1b3. flutter_local_notifications boot receiver to re-register the daily
    #      reminders after reboot.
    if "ScheduledNotificationBootReceiver" not in xml:
        boot = (
            '        <receiver\n'
            '            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver"\n'
            '            android:exported="false">\n'
            '            <intent-filter>\n'
            '                <action android:name="android.intent.action.BOOT_COMPLETED"/>\n'
            '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>\n'
            '                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>\n'
            '            </intent-filter>\n'
            '        </receiver>\n'
        )
        xml = re.sub(r"(<application\b[^>]*>)", r"\1\n" + boot, xml, count=1)

    # 1c. FCM default notification channel + icon so background/terminated
    #     messages render in a channel with a sensible importance and our icon.
    if "com.google.firebase.messaging.default_notification_channel_id" not in xml:
        fcm_meta = (
            '        <meta-data\n'
            '            android:name="com.google.firebase.messaging.default_notification_channel_id"\n'
            f'            android:value="{FCM_CHANNEL_ID}"/>\n'
            '        <meta-data\n'
            '            android:name="com.google.firebase.messaging.default_notification_icon"\n'
            '            android:resource="@drawable/ic_notification"/>\n'
        )
        xml = re.sub(r"(<application\b[^>]*>)", r"\1\n" + fcm_meta, xml, count=1)

    # 2. AdMob app id meta-data (inside <application>)
    if "com.google.android.gms.ads.APPLICATION_ID" not in xml:
        meta = (
            '        <meta-data\n'
            '            android:name="com.google.android.gms.ads.APPLICATION_ID"\n'
            f'            android:value="{ADMOB_APP_ID}"/>\n'
        )
        # insert right after the opening <application ...> tag
        xml = re.sub(r"(<application\b[^>]*>)", r"\1\n" + meta, xml, count=1)

    # Safety net: guarantee the AdMob app-id meta-data is present and valid.
    if "com.google.android.gms.ads.APPLICATION_ID" not in xml:
        raise SystemExit(
            "FATAL: failed to inject AdMob APPLICATION_ID into AndroidManifest; "
            "the app would crash at startup. Aborting the build."
        )

    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write(xml)
    print(f"patched AndroidManifest.xml (AdMob app id: {_APP_ID_SOURCE})")


def patch_gradle():
    path = APP_GRADLE_KTS if os.path.exists(APP_GRADLE_KTS) else APP_GRADLE_GROOVY
    if not os.path.exists(path):
        print("no app build.gradle found; skipping minSdk patch", file=sys.stderr)
        return
    with open(path, "r", encoding="utf-8") as f:
        g = f.read()

    # Replace flutter.minSdkVersion (or an existing numeric) with our floor.
    g = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion",
               f"minSdk = {MIN_SDK}", g)
    g = re.sub(r"minSdk(Version)?\s+flutter\.minSdkVersion",
               f"minSdkVersion {MIN_SDK}", g)

    with open(path, "w", encoding="utf-8") as f:
        f.write(g)
    print(f"patched {os.path.basename(path)} (minSdk={MIN_SDK})")


def install_google_services_json():
    """Write android/app/google-services.json.

    Preference order:
      1. GOOGLE_SERVICES_JSON_B64 env (base64 of a real config) — set from a
         CI secret so real push works without committing the file.
      2. The committed structurally-valid placeholder (build succeeds; the app
         runs; push tokens are simply unavailable until a real config is used).
    """
    b64 = os.environ.get("GOOGLE_SERVICES_JSON_B64", "").strip()
    data = None
    source = ""
    if b64:
        try:
            data = base64.b64decode(b64)
            source = "GOOGLE_SERVICES_JSON_B64 secret"
        except Exception as e:  # noqa: BLE001
            print(f"WARNING: GOOGLE_SERVICES_JSON_B64 not valid base64 ({e}); "
                  "falling back to placeholder", file=sys.stderr)
    if data is None:
        if not os.path.exists(GOOGLE_SERVICES_PLACEHOLDER):
            print("no google-services.json placeholder found; skipping Firebase",
                  file=sys.stderr)
            return False
        with open(GOOGLE_SERVICES_PLACEHOLDER, "rb") as f:
            data = f.read()
        source = "committed placeholder (push inactive until a real config is set)"
    os.makedirs(os.path.dirname(GOOGLE_SERVICES_DST), exist_ok=True)
    with open(GOOGLE_SERVICES_DST, "wb") as f:
        f.write(data)
    print(f"wrote android/app/google-services.json ({source})")
    return True


def patch_settings_gradle_for_google_services():
    """Register the Google Services Gradle plugin in the settings plugins block."""
    path = SETTINGS_GRADLE_KTS if os.path.exists(SETTINGS_GRADLE_KTS) \
        else SETTINGS_GRADLE_GROOVY
    if not os.path.exists(path):
        print("no settings.gradle(.kts) found; skipping google-services plugin",
              file=sys.stderr)
        return
    with open(path, "r", encoding="utf-8") as f:
        s = f.read()
    if "com.google.gms.google-services" in s:
        return
    is_kts = path.endswith(".kts")
    if is_kts:
        line = (f'    id("com.google.gms.google-services") version '
                f'"{GOOGLE_SERVICES_PLUGIN_VERSION}" apply false\n')
    else:
        line = (f'    id "com.google.gms.google-services" version '
                f'"{GOOGLE_SERVICES_PLUGIN_VERSION}" apply false\n')
    # Insert as the last entry of the top-level `plugins { ... }` block.
    m = re.search(r"plugins\s*\{", s)
    if not m:
        print("settings plugins block not found; skipping google-services plugin",
              file=sys.stderr)
        return
    # find the matching closing brace of this plugins block
    start = m.end()
    depth = 1
    i = start
    while i < len(s) and depth > 0:
        if s[i] == "{":
            depth += 1
        elif s[i] == "}":
            depth -= 1
        i += 1
    close = i - 1  # index of the closing brace
    s = s[:close] + line + s[close:]
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)
    print(f"patched {os.path.basename(path)} (google-services plugin registered)")


def patch_app_gradle_for_firebase():
    """Apply the google-services plugin and enable core-library desugaring in
    the app module (flutter_local_notifications needs java.time desugaring)."""
    path = APP_GRADLE_KTS if os.path.exists(APP_GRADLE_KTS) else APP_GRADLE_GROOVY
    if not os.path.exists(path):
        print("no app build.gradle found; skipping Firebase app-module patch",
              file=sys.stderr)
        return
    with open(path, "r", encoding="utf-8") as f:
        g = f.read()
    is_kts = path.endswith(".kts")

    # 1. Apply the google-services plugin (add to the app plugins { } block).
    if "com.google.gms.google-services" not in g:
        apply_line = ('    id("com.google.gms.google-services")\n' if is_kts
                      else '    id "com.google.gms.google-services"\n')
        m = re.search(r"plugins\s*\{", g)
        if m:
            g = g[:m.end()] + "\n" + apply_line + g[m.end():]

    # 2. Enable core library desugaring in compileOptions.
    desugar_flag = ("isCoreLibraryDesugaringEnabled = true" if is_kts
                    else "coreLibraryDesugaringEnabled true")
    if "CoreLibraryDesugaringEnabled" not in g:
        m = re.search(r"compileOptions\s*\{", g)
        if m:
            g = g[:m.end()] + f"\n        {desugar_flag}\n" + g[m.end():]
        else:
            # Append a compileOptions block inside android { }.
            am = re.search(r"android\s*\{", g)
            if am:
                block = ("\n    compileOptions {\n"
                         "        " + desugar_flag + "\n    }\n")
                g = g[:am.end()] + block + g[am.end():]

    # 3. Add the desugaring dependency.
    if "desugar_jdk_libs" not in g:
        dep_line = (f'    coreLibraryDesugaring("{DESUGAR_LIB}")\n' if is_kts
                    else f'    coreLibraryDesugaring "{DESUGAR_LIB}"\n')
        # Prefer an existing top-level dependencies { } block; else append one.
        dm = None
        for mm in re.finditer(r"dependencies\s*\{", g):
            dm = mm  # take the last dependencies block (app-level)
        if dm:
            g = g[:dm.end()] + "\n" + dep_line + g[dm.end():]
        else:
            g = g.rstrip() + "\n\ndependencies {\n" + dep_line + "}\n"

    with open(path, "w", encoding="utf-8") as f:
        f.write(g)
    print(f"patched {os.path.basename(path)} "
          "(google-services applied, core-library desugaring enabled)")


def install_icons():
    """Overlay the generated launcher icons (android_res/) onto the Android
    project's res/, replacing Flutter's default icon."""
    import shutil
    src = os.path.join(os.path.dirname(__file__), "..", "android_res")
    dst = os.path.join(ANDROID, "app", "src", "main", "res")
    if not os.path.isdir(src):
        print("no android_res/ overlay found; keeping default icons", file=sys.stderr)
        return
    for root, _dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        target_dir = os.path.join(dst, rel)
        os.makedirs(target_dir, exist_ok=True)
        for name in files:
            shutil.copy2(os.path.join(root, name), os.path.join(target_dir, name))
    print("installed BlueChip Rewards launcher icons")


if __name__ == "__main__":
    patch_manifest()
    patch_gradle()
    if install_google_services_json():
        patch_settings_gradle_for_google_services()
        patch_app_gradle_for_firebase()
    install_icons()
    print("Android project patched for BlueChip Rewards.")
