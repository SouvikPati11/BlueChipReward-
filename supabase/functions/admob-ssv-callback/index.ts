// AdMob Server-Side Verification (SSV) callback.
//
// Configure this function's public URL as the SSV callback in AdMob. AdMob
// appends signed query params; we verify the RSA-SHA256 signature against
// Google's published verifier keys, then credit the user exactly once.
//
// The rewarded ad must be shown with custom_data = the user's UUID.
//
// Deploy:  supabase functions deploy admob-ssv-callback --no-verify-jwt
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto-injected by Supabase)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const VERIFIER_KEYS_URL =
  "https://gstatic.com/admob/reward/verifier-keys.json";

interface VerifierKey {
  keyId: number;
  pem: string;
  base64: string;
}

let keyCache: { fetchedAt: number; keys: VerifierKey[] } | null = null;

async function getKeys(): Promise<VerifierKey[]> {
  const now = Date.now();
  if (keyCache && now - keyCache.fetchedAt < 6 * 60 * 60 * 1000) {
    return keyCache.keys;
  }
  const res = await fetch(VERIFIER_KEYS_URL);
  const json = await res.json();
  keyCache = { fetchedAt: now, keys: json.keys as VerifierKey[] };
  return keyCache.keys;
}

function pemToDer(pem: string): Uint8Array {
  const b64 = pem
    .replace(/-----BEGIN PUBLIC KEY-----/, "")
    .replace(/-----END PUBLIC KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(b64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/").padEnd(
    Math.ceil(s.length / 4) * 4,
    "=",
  );
  const raw = atob(b64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

Deno.serve(async (req: Request) => {
  try {
    const url = new URL(req.url);
    const params = url.searchParams;

    const signature = params.get("signature");
    const keyId = params.get("key_id");
    if (!signature || !keyId) {
      return new Response("missing signature", { status: 400 });
    }

    // The signed content is the query string up to (but excluding) "&signature=".
    const full = url.search.startsWith("?") ? url.search.slice(1) : url.search;
    const idx = full.indexOf("&signature=");
    if (idx === -1) return new Response("bad request", { status: 400 });
    const signedContent = full.slice(0, idx);

    const keys = await getKeys();
    const key = keys.find((k) => String(k.keyId) === String(keyId));
    if (!key) return new Response("unknown key", { status: 400 });

    const cryptoKey = await crypto.subtle.importKey(
      "spki",
      pemToDer(key.pem),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );

    // AdMob uses ECDSA P-256 over the raw query content.
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      cryptoKey,
      b64urlToBytes(signature),
      new TextEncoder().encode(signedContent),
    );
    if (!ok) return new Response("invalid signature", { status: 403 });

    const userId = params.get("custom_data");
    const rewardAmount = Number(params.get("reward_amount") ?? "0");
    if (!userId) return new Response("missing custom_data", { status: 400 });

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Amount is governed server-side; use the configured value, not the query.
    const { data: setting } = await supabase
      .from("app_settings").select("value").eq("key", "ads_reward").single();
    const configured = Number(setting?.value ?? rewardAmount);

    const { error } = await supabase.rpc("credit_verified_ad", {
      p_user: userId,
      p_amount: configured,
      p_signature: signature,
    });
    if (error) return new Response(error.message, { status: 500 });

    return new Response("ok", { status: 200 });
  } catch (e) {
    return new Response(`error: ${e}`, { status: 500 });
  }
});
