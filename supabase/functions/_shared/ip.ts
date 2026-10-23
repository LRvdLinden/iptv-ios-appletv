// build 95: IP-adres van de bezoeker voor limieten (support, status, device-auth, web-proxy, title-meta).
// Security L7: alleen wat de eigen infrastructuur zet. cf-connecting-ip zet Cloudflare vóór Supabase altijd zelf (een
// meegestuurde waarde wordt overschreven); ontbreekt hij, dan de LAATSTE waarde van X-Forwarded-For (die voegt de laatste
// proxy toe; de eerste waarden kiest de bezoeker zelf). x-real-ip niet meer: die kan een bezoeker zelf meesturen als er
// geen proxy is die hem overschrijft. Alleen een geldig IPv4/IPv6-adres telt, anders "?".
const IP_RE = /^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-f:.]{2,45})$/i;
export const validIp = (s: string) => s.length <= 45 && IP_RE.test(s) && (s.includes(":") || s.split(".").every((p) => Number(p) <= 255));
export function clientIp(req: Request): string {
  const h = req.headers;
  const cf = (h.get("cf-connecting-ip") ?? "").trim();
  if (cf && validIp(cf)) return cf;
  const list = (h.get("x-forwarded-for") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const last = list[list.length - 1] ?? "";
  return validIp(last) ? last : "?";
}
