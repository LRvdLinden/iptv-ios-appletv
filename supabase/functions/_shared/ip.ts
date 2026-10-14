// build 95: IP-adres van de bezoeker voor limieten (support, status, device-auth, web-proxy).
// Volgorde: cf-connecting-ip, dan x-real-ip (beide zet de proxy zelf), anders de LAATSTE waarde van X-Forwarded-For.
// De eerste waarde van X-Forwarded-For kiest de bezoeker zelf (een eigen kopregel wordt vooraan gezet), dus daarmee kon
// iemand per verzoek een ander "IP" opgeven en elke limiet omzeilen; de laatste waarde voegt de eigen proxy toe.
export function clientIp(req: Request): string {
  const h = req.headers;
  const cf = (h.get("cf-connecting-ip") ?? "").trim();
  if (cf) return cf.slice(0, 64);
  const real = (h.get("x-real-ip") ?? "").trim();
  if (real) return real.slice(0, 64);
  const list = (h.get("x-forwarded-for") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  return (list[list.length - 1] || "?").slice(0, 64);
}
