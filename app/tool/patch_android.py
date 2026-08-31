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
import os
import re
import sys

ANDROID = os.path.join(os.path.dirname(__file__), "..", "android")
MANIFEST = os.path.join(ANDROID, "app", "src", "main", "AndroidManifest.xml")
APP_GRADLE_GROOVY = os.path.join(ANDROID, "app", "build.gradle")
APP_GRADLE_KTS = os.path.join(ANDROID, "app", "build.gradle.kts")

ADMOB_APP_ID = os.environ.get(
    "ADMOB_APP_ID", "ca-app-pub-3940256099942544~3347511713"
)
MIN_SDK = "23"


def patch_manifest():
    with open(MANIFEST, "r", encoding="utf-8") as f:
        xml = f.read()

    # 1. INTERNET permission (before <application>)
    if "android.permission.INTERNET" not in xml:
        xml = xml.replace(
            "<application",
            '<uses-permission android:name="android.permission.INTERNET"/>\n'
            "    <application",
            1,
        )

    # 2. AdMob app id meta-data (inside <application>)
    if "com.google.android.gms.ads.APPLICATION_ID" not in xml:
        meta = (
            '        <meta-data\n'
            '            android:name="com.google.android.gms.ads.APPLICATION_ID"\n'
            f'            android:value="{ADMOB_APP_ID}"/>\n'
        )
        # insert right after the opening <application ...> tag
        xml = re.sub(r"(<application\b[^>]*>)", r"\1\n" + meta, xml, count=1)

    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write(xml)
    print("patched AndroidManifest.xml")


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


if __name__ == "__main__":
    patch_manifest()
    patch_gradle()
    print("Android project patched for BlueChip Rewards.")
