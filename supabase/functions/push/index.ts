// Custom-notification push delivery via Firebase Cloud Messaging (HTTP v1).
//
// Flow: the admin app calls admin_send_notification (writes the in-app feed +
// history), then invokes THIS function with the same title/body/target. Here we
// resolve the target users' registered FCM device tokens and deliver a
// data-only push so the Android client can display it (foreground, background
// and terminated) and deep-link on tap. Invalid/expired tokens are cleaned up.
//
// Security:
//   * Caller must be an authenticated admin (verified against user_roles).
//   * FCM credentials come from the FCM_SERVICE_ACCOUNT secret (the whole
//     service-account JSON). Nothing sensitive is ever hard-coded or logged.
//   * If FCM_SERVICE_ACCOUNT is absent, the function is a safe no-op
//     ({configured:false}); the in-app notification already succeeded.
//
// Deploy:  supabase functions deploy push
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto-injected),
//          FCM_SERVICE_ACCOUNT (paste the service-account JSON).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface ServiceAccount {
  client_email: string;
  private_key: string;
  token_uri?: string;
  project_id: string;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

// --- Service-account JWT → OAuth2 access token (RS256, Web Crypto) ----------

function pemToPkcs8(pem: string): Uint8Array {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(b64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

function b64url(bytes: Uint8Array | string): string {
  let str: string;
  if (typeof bytes === "string") {
    str = btoa(bytes);
  } else {
    let s = "";
    for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    str = btoa(s);
  }
  return str.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const tokenUri = sa.token_uri || "https://oauth2.googleapis.com/token";
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: tokenUri,
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${b64url(JSON.stringify(header))}.${
    b64url(JSON.stringify(claims))
  }`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(unsigned),
    ),
  );
  const assertion = `${unsigned}.${b64url(sig)}`;

  const res = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) {
    throw new Error(`oauth token exchange failed: ${res.status}`);
  }
  const body = await res.json();
  return body.access_token as string;
}

// --- One FCM v1 send. Returns 'ok' | 'invalid' | 'error'. --------------------

async function sendOne(
  projectId: string,
  accessToken: string,
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<"ok" | "invalid" | "error"> {
  const url =
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const message = {
    message: {
      token,
      // Data-only: the client builds/display the notification itself so it can
      // dedupe, theme it, and deep-link — identical in fg/bg/terminated.
      data: { ...data, title, body },
      android: { priority: "HIGH" },
    },
  };
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(message),
  });
  if (res.ok) return "ok";
  let errCode = "";
  try {
    const e = await res.json();
    errCode = e?.error?.status || e?.error?.details?.[0]?.errorCode || "";
  } catch (_) { /* ignore */ }
  // Tokens that will never be valid again → clean them up.
  if (
    res.status === 404 ||
    errCode === "UNREGISTERED" ||
    errCode === "NOT_FOUND" ||
    errCode === "INVALID_ARGUMENT"
  ) {
    return "invalid";
  }
  return "error";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  // 1. Authenticate + authorize the caller (must be an admin).
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "unauthorized" }, 401);
  const { data: userRes, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userRes?.user) return json({ error: "unauthorized" }, 401);
  const uid = userRes.user.id;
  const { data: roleRows } = await admin
    .from("user_roles")
    .select("role")
    .eq("user_id", uid)
    .eq("role", "admin");
  if (!roleRows || roleRows.length === 0) {
    return json({ error: "forbidden" }, 403);
  }

  // 2. Parse input.
  let input: {
    title?: string;
    body?: string;
    route?: string;
    target?: string;
    user_ids?: string[];
    id?: string;
  };
  try {
    input = await req.json();
  } catch (_) {
    return json({ error: "bad_json" }, 400);
  }
  const title = (input.title || "").trim();
  const body = (input.body || "").trim();
  if (!title) return json({ error: "title_required" }, 400);
  const target = input.target === "specific" ? "specific" : "all";

  // 3. If FCM is not configured, no-op cleanly (in-app already delivered).
  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!saRaw) {
    return json({
      ok: true,
      configured: false,
      sent: 0,
      failed: 0,
      cleaned: 0,
    });
  }
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(saRaw);
  } catch (_) {
    return json({ error: "fcm_service_account_invalid" }, 500);
  }

  // 4. Resolve target device tokens (service role bypasses RLS).
  let query = admin.from("device_tokens").select("user_id, token");
  if (target === "specific") {
    const ids = (input.user_ids || []).filter((x) => !!x);
    if (ids.length === 0) return json({ error: "no_recipients" }, 400);
    query = query.in("user_id", ids);
  }
  const { data: tokenRows, error: tokErr } = await query;
  if (tokErr) return json({ error: "token_query_failed" }, 500);
  const tokens = (tokenRows || []).map((r: { token: string }) => r.token);
  if (tokens.length === 0) {
    return json({ ok: true, configured: true, sent: 0, failed: 0, cleaned: 0 });
  }

  // 5. Send via FCM v1.
  let accessToken: string;
  try {
    accessToken = await getAccessToken(sa);
  } catch (e) {
    return json({ error: "fcm_auth_failed", detail: String(e) }, 502);
  }

  const data: Record<string, string> = {
    route: (input.route || "/notifications").toString(),
    id: (input.id || "").toString(),
    click_action: "FLUTTER_NOTIFICATION_CLICK",
  };

  let sent = 0, failed = 0;
  const invalid: string[] = [];
  // Bounded concurrency to stay well within limits.
  const batchSize = 100;
  for (let i = 0; i < tokens.length; i += batchSize) {
    const slice = tokens.slice(i, i + batchSize);
    const results = await Promise.all(
      slice.map((t) =>
        sendOne(sa.project_id, accessToken, t, title, body, data)
          .catch(() => "error" as const)
      ),
    );
    results.forEach((r, j) => {
      if (r === "ok") sent++;
      else {
        failed++;
        if (r === "invalid") invalid.push(slice[j]);
      }
    });
  }

  // 6. Clean up invalid/expired tokens.
  let cleaned = 0;
  if (invalid.length > 0) {
    const { error: delErr, count } = await admin
      .from("device_tokens")
      .delete({ count: "exact" })
      .in("token", invalid);
    if (!delErr) cleaned = count || invalid.length;
  }

  return json({ ok: true, configured: true, sent, failed, cleaned });
});
