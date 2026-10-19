// Logica van de functie auth-mail (Send Email Hook van Supabase Auth, build 137), zonder netwerk; getest in logic_test.ts.
// Waarom: Supabase Auth zelf (GoTrue) verstuurt via SMTP mails zonder Message-ID-kopregel; Gmail/Outlook stellen zulke mails
// uit of zetten ze in de spam (bevestigingsmail kwam pas na minuten of niet aan). Met de hook rendert deze functie dezelfde
// templates (supabase/templates, Go-templates) en verstuurt ze via _shared/mail.ts (nodemailer: Message-ID, Date,
// tekstversie), net als de welkomstmail.
import { TEMPLATES } from "./templates.ts";

// ---- Standard Webhooks (https://www.standardwebhooks.com): handtekening van Supabase Auth ----
const enc = new TextEncoder();
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
function unb64(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}
/** Geheim(en) in de vorm "v1,whsec_<base64>" (meerdere gescheiden door | of spatie). */
export function hookKeys(secret: string): Uint8Array<ArrayBuffer>[] {
  return secret.split(/[|\s]+/).map((s) => s.trim().replace(/^v1,/, "").replace(/^whsec_/, "")).filter(Boolean).map(unb64);
}
export async function sign(key: Uint8Array<ArrayBuffer>, id: string, ts: string, body: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64(new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(`${id}.${ts}.${body}`))));
}
function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
/** true als een van de v1-handtekeningen klopt en de tijd binnen 5 minuten ligt. */
export async function verifyHook(secret: string, headers: Headers, body: string, now = Date.now()): Promise<boolean> {
  const id = headers.get("webhook-id") ?? "", ts = headers.get("webhook-timestamp") ?? "", sig = headers.get("webhook-signature") ?? "";
  if (!id || !/^\d{1,12}$/.test(ts) || !sig || !secret) return false;
  if (Math.abs(now / 1000 - Number(ts)) > 300) return false;
  const given = sig.split(" ").map((p) => p.split(",")).filter(([v, s]) => v === "v1" && s).map(([, s]) => s);
  let keys: Uint8Array<ArrayBuffer>[];
  try { keys = hookKeys(secret); } catch { return false; }
  for (const k of keys) {
    const want = await sign(k, id, ts, body);
    if (given.some((g) => same(g, want))) return true;
  }
  return false;
}

// ---- Go-templates (het deel dat supabase/templates gebruikt) ----
type Ctx = Record<string, unknown>;
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&#34;").replace(/'/g, "&#39;");
/** Variabelen die alleen in links staan: url-coderen (zoals Go html/template in het query-deel van een href). */
const URL_VARS = new Set(["TokenHash", "RedirectTo", "Token"]);
function lookup(ctx: Ctx, path: string): unknown {
  let v: unknown = ctx;
  for (const p of path.replace(/^\./, "").split(".")) {
    if (v == null || typeof v !== "object") return undefined;
    v = (v as Record<string, unknown>)[p];
  }
  return v;
}
const truthy = (v: unknown) => !(v == null || v === false || v === "" || v === 0 || (Array.isArray(v) && !v.length));
/** Voorwaarde: .Pad | (eq .Pad "x") | and A B … | or A B … | not A */
function evalCond(src: string, ctx: Ctx): unknown {
  const toks = src.match(/\(|\)|"(?:[^"\\]|\\.)*"|[^\s()]+/g) ?? [];
  let i = 0;
  const term = (): unknown => {
    const t = toks[i++];
    if (t === undefined) throw new Error("template: lege voorwaarde");
    if (t === "(") { const v = call(); if (toks[i++] !== ")") throw new Error("template: ) ontbreekt"); return v; }
    if (t.startsWith('"')) return JSON.parse(t);
    if (t.startsWith(".")) return lookup(ctx, t);
    if (t === "true" || t === "false") return t === "true";
    i--; return call();
  };
  const call = (): unknown => {
    const f = toks[i];
    if (f === "and" || f === "or" || f === "eq" || f === "ne" || f === "not") {
      i++;
      const args: unknown[] = [];
      while (i < toks.length && toks[i] !== ")") args.push(term());
      if (f === "and") { let v: unknown = true; for (const a of args) { v = a; if (!truthy(a)) return a; } return v; }
      if (f === "or") { for (const a of args) if (truthy(a)) return a; return args[args.length - 1]; }
      if (f === "not") return !truthy(args[0]);
      if (f === "eq") return args.slice(1).some((a) => a === args[0]);
      return args[0] !== args[1];
    }
    return term();
  };
  const v = call();
  if (i !== toks.length) throw new Error(`template: onbekende voorwaarde ${src}`);
  return v;
}
/** Rendert {{ .Pad }}, {{ if … }}, {{ else }}, {{ else if … }} en {{ end }}; iets anders geeft een fout. */
export function renderGo(tpl: string, ctx: Ctx): string {
  const parts = tpl.split(/(\{\{-?\s*[\s\S]*?\s*-?\}\})/);
  let pos = 0;
  const block = (stopAt: Set<string>): { out: string; stop: string; arg: string } => {
    let out = "";
    while (pos < parts.length) {
      const p = parts[pos++];
      const m = /^\{\{-?\s*([\s\S]*?)\s*-?\}\}$/.exec(p);
      if (!m) { out += p; continue; }
      const a = m[1];
      if (a === "end" || a === "else" || a.startsWith("else if ")) {
        if (!stopAt.has(a.startsWith("else if ") ? "else if" : a)) throw new Error(`template: onverwachte ${a}`);
        return { out, stop: a.startsWith("else if ") ? "else if" : a, arg: a.startsWith("else if ") ? a.slice(8) : "" };
      }
      if (a.startsWith("if ")) { out += ifChain(a.slice(3)); continue; }
      if (/^\.[A-Za-z_][\w.]*$/.test(a)) {
        const v = lookup(ctx, a);
        const s = v == null ? "" : String(v);
        out += URL_VARS.has(a.slice(1)) ? encodeURIComponent(s) : esc(s);
        continue;
      }
      throw new Error(`template: niet ondersteund {{ ${a} }}`);
    }
    if (stopAt.size) throw new Error("template: end ontbreekt");
    return { out, stop: "", arg: "" };
  };
  const ifChain = (cond: string): string => {
    let taken = false, result = "";
    let c: string | null = cond;
    for (;;) {
      const on = !taken && (c === null || truthy(evalCond(c, ctx)));
      const r = block(new Set(["else", "else if", "end"]));
      if (on) { taken = true; result = r.out; }
      if (r.stop === "end") return result;
      c = r.stop === "else if" ? r.arg : null;
    }
  };
  return block(new Set()).out;
}

// ---- welke mail, naar wie ----
export type HookUser = { id?: string; email?: string; new_email?: string; user_metadata?: Record<string, unknown> | null };
export type EmailData = {
  token?: string; token_hash?: string; redirect_to?: string; email_action_type?: string; site_url?: string;
  token_new?: string; token_hash_new?: string; old_email?: string;
};
/** email_action_type -> template (supabase/templates). Onbekend = null (niet versturen). */
export const ACTION_TEMPLATE: Record<string, string> = {
  signup: "confirmation", invite: "invite", magiclink: "magic_link", email: "magic_link", recovery: "recovery",
  email_change: "email_change", email_change_new: "email_change", email_change_current: "email_change", reauthentication: "reauthentication",
};
export type Mail = { to: string; subject: string; html: string; text: string; template: string };

/** De mail(s) voor een hook-aanroep. Wijziging van e-mailadres met "Secure email change": twee mails; Supabase noemt de
 *  hashes andersom (token_hash_new hoort bij het huidige adres user.email, token_hash bij het nieuwe user.new_email). */
export function buildMails(user: HookUser, d: EmailData): Mail[] {
  const key = ACTION_TEMPLATE[d.email_action_type ?? ""];
  if (!key) return [];
  const t = TEMPLATES[key as keyof typeof TEMPLATES];
  if (!t) return [];
  const data = (user.user_metadata && typeof user.user_metadata === "object") ? user.user_metadata : {};
  const base: Ctx = {
    Email: user.email ?? "", NewEmail: user.new_email ?? "", Data: data, SiteURL: d.site_url ?? "", RedirectTo: d.redirect_to ?? "",
    Token: d.token ?? "", TokenHash: d.token_hash ?? "",
  };
  const one = (to: string, extra: Ctx = {}): Mail => {
    const ctx = { ...base, ...extra };
    const html = renderGo(t.content, ctx);
    return { to, subject: renderGo(t.subject, ctx), html, text: htmlToText(html), template: key };
  };
  if (key === "email_change") {
    const out: Mail[] = [];
    const secure = !!(d.token_hash_new && user.email && user.new_email);
    if (secure) out.push(one(user.email!, { TokenHash: d.token_hash_new, Token: d.token ?? "" }));
    const to = user.new_email || user.email;
    if (to) out.push(one(to, { TokenHash: d.token_hash ?? d.token_hash_new ?? "", Token: d.token_new || d.token || "" }));
    return out;
  }
  return user.email ? [one(user.email)] : [];
}

/** Eenvoudige tekstversie van de HTML (multipart/alternative: beter voor spamfilters en tekstlezers). */
export function htmlToText(html: string): string {
  let s = html.replace(/<(style|script|head)[\s\S]*?<\/\1>/gi, "");
  s = s.replace(/<a\s[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi, (_m, href, label) => {
    const l = label.replace(/<[^>]+>/g, "").trim();
    return l && !l.startsWith("http") ? `${l} (${href})` : href;
  });
  s = s.replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|tr|h[1-6]|table|li)>/gi, "\n").replace(/<[^>]+>/g, "");
  s = s.replace(/&nbsp;/g, " ").replace(/&#34;|&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
  return s.split("\n").map((l) => l.replace(/[ \t]+/g, " ").trim()).join("\n").replace(/\n{3,}/g, "\n\n").trim();
}
