// Versleuteling at rest van accountgegevens (account_state, account_sources): AES-256-GCM met BINGR_SOURCES_KEY
// (32 bytes, base64; eenmalig aangemaakt door de Backend-workflow). Formaat: base64(nonce(12) || ciphertext+tag).
// Precies hetzelfde als seal()/open_() in device-auth/index.ts (dat schrijft de gegevens); push leest er de herinneringen mee.
let keyPromise: Promise<CryptoKey> | null = null;
let keyFor = "";
function sourcesKey(raw64 = Deno.env.get("BINGR_SOURCES_KEY") ?? ""): Promise<CryptoKey> {
  if (!keyPromise || keyFor !== raw64) {
    keyFor = raw64;
    keyPromise = (async () => {
      const raw = Uint8Array.from(atob(raw64), (c) => c.charCodeAt(0));
      if (raw.length !== 32) throw new Error("sources_key_missing");
      return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
    })();
    keyPromise.catch(() => { keyPromise = null; });
  }
  return keyPromise;
}
export async function seal(obj: unknown, key64?: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await sourcesKey(key64), new TextEncoder().encode(JSON.stringify(obj))));
  const out = new Uint8Array(iv.length + ct.length); out.set(iv); out.set(ct, iv.length);
  let s = ""; for (let i = 0; i < out.length; i += 8192) s += String.fromCharCode(...out.subarray(i, i + 8192));
  return btoa(s);
}
// deno-lint-ignore no-explicit-any
export async function unseal(data: string, key64?: string): Promise<any> {
  const all = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: all.subarray(0, 12) }, await sourcesKey(key64), all.subarray(12));
  return JSON.parse(new TextDecoder().decode(pt));
}
