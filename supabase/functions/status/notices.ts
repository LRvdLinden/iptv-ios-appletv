// Bingr-status: meldingen (storingen en onderhoud), niveaus per onderdeel, dagbalken en de feed. Pure functies
// (geen database of netwerk), los te testen met `deno test`.
import type { DayPoint, State } from "./logic.ts";

export type Lang = "nl" | "en";
export type Kind = "incident" | "maintenance";
export type Impact = "none" | "minor" | "major" | "critical" | "maintenance";
export type IncidentStatus = "investigating" | "identified" | "monitoring" | "resolved";
export type MaintStatus = "scheduled" | "in_progress" | "completed" | "cancelled";
export type NoticeStatus = IncidentStatus | MaintStatus;
/** Niveau van een onderdeel en van het totaalbeeld (oplopend in ernst, onderhoud tussen werkt en verminderd). */
export type Level = "operational" | "maintenance" | "degraded" | "partial" | "major";
export type CompImpact = "degraded" | "partial" | "major" | "maintenance";

export const LEVELS: Level[] = ["operational", "maintenance", "degraded", "partial", "major"];
export const INCIDENT_STATUSES: IncidentStatus[] = ["investigating", "identified", "monitoring", "resolved"];
export const MAINT_STATUSES: MaintStatus[] = ["scheduled", "in_progress", "completed", "cancelled"];
export const IMPACTS: Impact[] = ["none", "minor", "major", "critical"];
export const COMP_IMPACTS: CompImpact[] = ["degraded", "partial", "major"];

export const worst = (a: Level, b: Level): Level => (LEVELS.indexOf(a) >= LEVELS.indexOf(b) ? a : b);

export interface NoticeUpdate { id?: number; status: NoticeStatus; body_nl: string; body_en: string; at: string; auto?: boolean }
export interface NoticeComponent { monitor_id: string; impact: CompImpact }
export interface Notice {
  id: number;
  kind: Kind;
  title_nl: string;
  title_en: string;
  impact: Impact;
  status: NoticeStatus;
  started_at: string;
  resolved_at: string | null;
  window_start: string | null;
  window_end: string | null;
  auto?: boolean;
  auto_resolve?: boolean;
  edited?: boolean;
  notify?: boolean;
  created_at?: string;
  updated_at?: string;
  components: NoticeComponent[];
  updates: NoticeUpdate[];
}

// ---- teksten (pagina, e-mail en feed gebruiken dezelfde woorden) ----
export const LABELS: Record<Lang, {
  level: Record<Level, string>; status: Record<NoticeStatus, string>; impact: Record<Impact, string>;
  comp: Record<CompImpact, string>; kind: Record<Kind, string>; banner: Record<Level, string>;
}> = {
  nl: {
    level: { operational: "Werkt", maintenance: "Onderhoud", degraded: "Verminderde prestaties", partial: "Gedeeltelijke storing", major: "Grote storing" },
    status: {
      investigating: "Wordt onderzocht", identified: "Oorzaak bekend", monitoring: "Wordt gevolgd", resolved: "Opgelost",
      scheduled: "Gepland", in_progress: "Bezig", completed: "Afgerond", cancelled: "Geannuleerd",
    },
    impact: { none: "Geen impact", minor: "Kleine impact", major: "Grote impact", critical: "Kritiek", maintenance: "Onderhoud" },
    comp: { degraded: "Verminderde prestaties", partial: "Gedeeltelijke storing", major: "Grote storing", maintenance: "Onderhoud" },
    kind: { incident: "Storing", maintenance: "Gepland onderhoud" },
    banner: {
      operational: "Alle systemen werken", maintenance: "Onderhoud bezig", degraded: "Verminderde prestaties",
      partial: "Gedeeltelijke storing", major: "Grote storing",
    },
  },
  en: {
    level: { operational: "Operational", maintenance: "Under maintenance", degraded: "Degraded performance", partial: "Partial outage", major: "Major outage" },
    status: {
      investigating: "Investigating", identified: "Identified", monitoring: "Monitoring", resolved: "Resolved",
      scheduled: "Scheduled", in_progress: "In progress", completed: "Completed", cancelled: "Cancelled",
    },
    impact: { none: "No impact", minor: "Minor", major: "Major", critical: "Critical", maintenance: "Maintenance" },
    comp: { degraded: "Degraded performance", partial: "Partial outage", major: "Major outage", maintenance: "Under maintenance" },
    kind: { incident: "Incident", maintenance: "Scheduled maintenance" },
    banner: {
      operational: "All systems operational", maintenance: "Maintenance in progress", degraded: "Degraded performance",
      partial: "Partial outage", major: "Major outage",
    },
  },
};

// ---- onderhoud: status volgt het tijdvak ----
/** Status van onderhoud op tijdstip `now`: gepland -> bezig (begin) -> afgerond (einde). Geannuleerd/afgerond blijft staan. */
export function maintStatus(n: Pick<Notice, "status" | "window_start" | "window_end">, now = Date.now()): MaintStatus {
  const s = n.status as MaintStatus;
  if (s === "cancelled" || s === "completed") return s;
  const a = n.window_start ? Date.parse(n.window_start) : NaN, b = n.window_end ? Date.parse(n.window_end) : NaN;
  if (Number.isFinite(b) && now >= b) return "completed";
  if (Number.isFinite(a) && now >= a) return "in_progress";
  return s === "in_progress" ? "in_progress" : "scheduled";
}

/** Effectieve status (onderhoud volgens het tijdvak, storingen zoals opgeslagen). */
export function effectiveStatus(n: Notice, now = Date.now()): NoticeStatus {
  return n.kind === "maintenance" ? maintStatus(n, now) : n.status;
}

/** Loopt de melding nog (storing niet opgelost, onderhoud bezig)? */
export function isActive(n: Notice, now = Date.now()): boolean {
  const s = effectiveStatus(n, now);
  return n.kind === "incident" ? s !== "resolved" : s === "in_progress";
}
export const isUpcoming = (n: Notice, now = Date.now()) => n.kind === "maintenance" && effectiveStatus(n, now) === "scheduled";
/** Afgesloten (opgelost of afgerond); geannuleerd onderhoud telt niet mee op de openbare pagina. */
export const isClosed = (n: Notice, now = Date.now()) => ["resolved", "completed"].includes(effectiveStatus(n, now));

/** Begin- en eindtijd van een melding voor tijdlijn, dagbalken en geschiedenis. */
export function span(n: Notice, now = Date.now()): { start: number; end: number } {
  if (n.kind === "maintenance") {
    const start = Date.parse(n.window_start || n.started_at);
    const st = maintStatus(n, now);
    const end = n.resolved_at ? Date.parse(n.resolved_at) : st === "completed" ? Date.parse(n.window_end || n.started_at) : now;
    return { start, end: Math.max(start, Math.min(end, now)) };
  }
  const start = Date.parse(n.started_at);
  return { start, end: n.resolved_at ? Date.parse(n.resolved_at) : now };
}

// ---- niveaus ----
const fromState = (s: State | null | undefined): Level => (s === "down" ? "major" : s === "degraded" ? "degraded" : "operational");
const fromComp = (i: CompImpact): Level => (i === "major" ? "major" : i === "partial" ? "partial" : i === "degraded" ? "degraded" : "maintenance");
const fromImpact = (i: Impact): Level => (i === "critical" ? "major" : i === "major" ? "partial" : i === "minor" ? "degraded" : "operational");

/**
 * Niveau per onderdeel: het slechtste van de monitor zelf en de lopende storingen. Tijdens onderhoud telt de monitor niet
 * (hij mag dan haperen) en staat het onderdeel op "onderhoud", tenzij een storing het erger maakt.
 */
export function componentLevels(monitors: { id: string; state: State | null }[], notices: Notice[], now = Date.now()): Map<string, Level> {
  const out = new Map<string, Level>();
  const maint = new Set<string>();
  const inc = new Map<string, Level>();
  for (const n of notices) {
    if (!isActive(n, now)) continue;
    for (const c of n.components) {
      if (n.kind === "maintenance") maint.add(c.monitor_id);
      else inc.set(c.monitor_id, worst(inc.get(c.monitor_id) ?? "operational", fromComp(c.impact)));
    }
  }
  for (const m of monitors) {
    let l: Level = maint.has(m.id) ? "maintenance" : fromState(m.state);
    const i = inc.get(m.id);
    if (i) l = worst(l, i);
    out.set(m.id, l);
  }
  return out;
}

export interface OverallLevel { level: Level; major: string[]; partial: string[]; degraded: string[]; maintenance: string[] }
/** Totaalbeeld: slechtste onderdeel, of de impact van een lopende storing zonder onderdelen (kritiek = grote storing). */
export function overallLevel(levels: Map<string, Level>, notices: Notice[], now = Date.now()): OverallLevel {
  const by = (l: Level) => [...levels].filter(([, v]) => v === l).map(([k]) => k);
  let level: Level = "operational";
  for (const v of levels.values()) level = worst(level, v);
  for (const n of notices) if (n.kind === "incident" && isActive(n, now)) level = worst(level, fromImpact(n.impact));
  return { level, major: by("major"), partial: by("partial"), degraded: by("degraded"), maintenance: by("maintenance") };
}

// ---- dagbalken ----
const amsFmt = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Amsterdam", year: "numeric", month: "2-digit", day: "2-digit" });
/** Kalenderdag in Nederlandse tijd (YYYY-MM-DD). */
export const amsDay = (t: number) => amsFmt.format(new Date(t));

/**
 * Minuten per Nederlandse kalenderdag tussen start en eind. Middernacht in Amsterdam valt altijd op een heel UTC-uur
 * (ook bij zomer-/wintertijd), dus knippen op hele uren is exact.
 */
export function minutesByDay(start: number, end: number): Map<string, number> {
  const out = new Map<string, number>();
  if (!(end > start)) return out;
  let t = start;
  while (t < end) {
    const next = Math.min(end, Math.floor(t / 3600e3) * 3600e3 + 3600e3);
    const d = amsDay(t);
    out.set(d, (out.get(d) ?? 0) + (next - t) / 60000);
    t = next;
  }
  return out;
}

export type BarState = DayPoint["s"] | "partial" | "maint";
export interface Bar { d: string; u: number | null; s: BarState; dm: number; i: number[] }

const SEV: BarState[] = ["none", "up", "maint", "degraded", "partial", "down"];
const worse = (a: BarState, b: BarState): BarState => (SEV.indexOf(a) >= SEV.indexOf(b) ? a : b);

/**
 * Dagbalken van één onderdeel verrijkt met storingsminuten (dm, uit de automatische storingen) en de meldingen die die dag
 * het onderdeel raakten (i). De kleur wordt het slechtste van de metingen en de impact van de meldingen.
 */
export function annotateDays(
  days: DayPoint[], monitorId: string, outages: { m: string; started_at: string; ended_at: string | null }[], notices: Notice[], now = Date.now(),
): Bar[] {
  const dm = new Map<string, number>();
  for (const o of outages) {
    if (o.m !== monitorId) continue;
    for (const [d, v] of minutesByDay(Date.parse(o.started_at), o.ended_at ? Date.parse(o.ended_at) : now)) dm.set(d, (dm.get(d) ?? 0) + v);
  }
  const hits = new Map<string, { ids: number[]; s: BarState }>();
  for (const n of notices) {
    const c = n.components.find((x) => x.monitor_id === monitorId);
    if (!c || n.status === "cancelled") continue;
    if (n.kind === "maintenance" && effectiveStatus(n, now) === "scheduled") continue;
    const { start, end } = span(n, now);
    const s: BarState = n.kind === "maintenance" ? "maint" : c.impact === "major" ? "down" : c.impact === "partial" ? "partial" : "degraded";
    for (const d of minutesByDay(start, Math.max(end, start + 1)).keys()) {
      const h = hits.get(d) ?? { ids: [], s: "none" as BarState };
      if (!h.ids.includes(n.id)) h.ids.push(n.id);
      h.s = worse(h.s, s);
      hits.set(d, h);
    }
  }
  return days.map((p) => {
    const h = hits.get(p.d);
    let s: BarState = p.s;
    if (h) s = s === "none" && h.s === "maint" ? "maint" : worse(s, h.s);
    return { d: p.d, u: p.u, s, dm: Math.round(dm.get(p.d) ?? 0), i: h?.ids ?? [] };
  });
}

// ---- openbare weergave van een melding ----
export interface PublicNotice {
  id: number; kind: Kind; title: { nl: string; en: string }; impact: Impact; status: NoticeStatus;
  started_at: string; resolved_at: string | null; window_start: string | null; window_end: string | null;
  components: { id: string; impact: CompImpact }[];
  updates: { status: NoticeStatus; body: { nl: string; en: string }; at: string }[];
}
/** Alleen openbare onderdelen; tijdlijn nieuwste eerst; onderhoud met de effectieve status. */
export function publicNotice(n: Notice, visible: Set<string>, now = Date.now()): PublicNotice {
  return {
    id: n.id, kind: n.kind, title: { nl: n.title_nl, en: n.title_en || n.title_nl }, impact: n.impact, status: effectiveStatus(n, now),
    started_at: n.started_at, resolved_at: n.resolved_at, window_start: n.window_start, window_end: n.window_end,
    components: n.components.filter((c) => visible.has(c.monitor_id)).map((c) => ({ id: c.monitor_id, impact: c.impact })),
    updates: [...n.updates].sort((a, b) => Date.parse(b.at) - Date.parse(a.at))
      .map((u) => ({ status: u.status, body: { nl: u.body_nl, en: u.body_en || u.body_nl }, at: u.at })),
  };
}

// ---- automatische meldingen ----
/** Titel van een automatische storing: "Storing bij A", "Storing bij A en B", "Storing bij A, B en 2 andere". */
export function autoTitle(names: string[], lang: Lang): string {
  const and = lang === "nl" ? "en" : "and";
  const pre = lang === "nl" ? "Storing bij " : "Outage affecting ";
  if (names.length <= 1) return pre + (names[0] ?? (lang === "nl" ? "een onderdeel" : "a component"));
  if (names.length <= 3) return `${pre}${names.slice(0, -1).join(", ")} ${and} ${names[names.length - 1]}`;
  return `${pre}${names.slice(0, 2).join(", ")} ${and} ${names.length - 2} ${lang === "nl" ? "andere" : "others"}`;
}
export const autoOpenText = (nl: string, en: string) => ({
  body_nl: `Onze monitoring ziet dat ${nl} niet goed werkt. We zoeken uit wat er aan de hand is.`,
  body_en: `Our monitoring shows that ${en} isn't working properly. We're looking into it.`,
});
export const autoResolveText = (nl: string, en: string) => ({
  body_nl: `${nl} werkt weer normaal. We houden het in de gaten.`,
  body_en: `${en} is working normally again. We'll keep an eye on it.`,
});
export const maintText = (s: "in_progress" | "completed") => s === "in_progress"
  ? { body_nl: "Het onderhoud is begonnen.", body_en: "The maintenance has started." }
  : { body_nl: "Het onderhoud is afgerond. Alles werkt weer normaal.", body_en: "The maintenance has been completed. Everything is working normally." };

// ---- feed (Atom en RSS) ----
/** XML-tekst veilig maken (ook ongeldige stuurtekens weg; XML 1.0 staat die niet toe). */
export function xmlEsc(s: unknown): string {
  return String(s ?? "")
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, "")
    .replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[c]!));
}
const htmlEsc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function fmtTime(iso: string, lang: Lang) {
  return new Date(iso).toLocaleString(lang === "nl" ? "nl-NL" : "en-GB", {
    timeZone: "Europe/Amsterdam", day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", timeZoneName: "short",
  });
}

/** HTML-inhoud van een feed-item: tijdlijn (nieuwste eerst) en getroffen onderdelen. */
export function noticeHtml(n: PublicNotice, lang: Lang, names: Map<string, { nl: string; en: string }>): string {
  const L = LABELS[lang];
  const comps = n.components.map((c) => names.get(c.id)?.[lang]).filter(Boolean);
  const win = n.kind === "maintenance" && n.window_start && n.window_end
    ? `<p><b>${lang === "nl" ? "Gepland" : "Scheduled"}:</b> ${htmlEsc(fmtTime(n.window_start, lang))} – ${htmlEsc(fmtTime(n.window_end, lang))}</p>` : "";
  return `${win}${n.updates.map((u) => `<p><b>${htmlEsc(L.status[u.status] ?? u.status)}</b> – ${htmlEsc(u.body[lang])}<br><small>${htmlEsc(fmtTime(u.at, lang))}</small></p>`).join("")}${
    comps.length ? `<p>${lang === "nl" ? "Getroffen onderdelen" : "Affected components"}: ${htmlEsc(comps.join(", "))}</p>` : ""}`;
}

export interface FeedOpts { lang: Lang; site: string; self: string; updated: string; names: Map<string, { nl: string; en: string }> }
const lastAt = (n: PublicNotice) => n.updates.reduce((m, u) => (u.at > m ? u.at : m), n.resolved_at ?? n.started_at);
const noticeUrl = (site: string, id: number) => `${site}/status/incident/?id=${id}`;

export function atomFeed(items: PublicNotice[], o: FeedOpts): string {
  const L = LABELS[o.lang];
  const title = o.lang === "nl" ? "Bingr-status: storingen en onderhoud" : "Bingr status: incidents and maintenance";
  const entries = items.map((n) => `  <entry>
    <id>tag:bingr.online,2026:status-${n.id}</id>
    <title>${xmlEsc(`${n.title[o.lang]} (${L.status[n.status] ?? n.status})`)}</title>
    <link rel="alternate" type="text/html" href="${xmlEsc(noticeUrl(o.site, n.id))}"/>
    <published>${xmlEsc(new Date(n.window_start && n.kind === "maintenance" ? n.window_start : n.started_at).toISOString())}</published>
    <updated>${xmlEsc(new Date(lastAt(n)).toISOString())}</updated>
    <category term="${xmlEsc(n.kind)}" label="${xmlEsc(L.kind[n.kind])}"/>
    <content type="html">${xmlEsc(noticeHtml(n, o.lang, o.names))}</content>
  </entry>`).join("\n");
  return `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="${o.lang}">
  <id>tag:bingr.online,2026:status-${o.lang}</id>
  <title>${xmlEsc(title)}</title>
  <link rel="alternate" type="text/html" href="${xmlEsc(`${o.site}/status/`)}"/>
  <link rel="self" type="application/atom+xml" href="${xmlEsc(o.self)}"/>
  <updated>${xmlEsc(new Date(o.updated).toISOString())}</updated>
  <author><name>Bingr</name><uri>${xmlEsc(o.site)}</uri></author>
  <icon>${xmlEsc(`${o.site}/apple-touch-icon.png`)}</icon>
${entries}
</feed>
`;
}

export function rssFeed(items: PublicNotice[], o: FeedOpts): string {
  const L = LABELS[o.lang];
  const title = o.lang === "nl" ? "Bingr-status: storingen en onderhoud" : "Bingr status: incidents and maintenance";
  const rfc = (iso: string) => new Date(iso).toUTCString();
  const entries = items.map((n) => `    <item>
      <title>${xmlEsc(`${n.title[o.lang]} (${L.status[n.status] ?? n.status})`)}</title>
      <link>${xmlEsc(noticeUrl(o.site, n.id))}</link>
      <guid isPermaLink="false">bingr-status-${n.id}-${xmlEsc(new Date(lastAt(n)).getTime())}</guid>
      <pubDate>${xmlEsc(rfc(lastAt(n)))}</pubDate>
      <category>${xmlEsc(L.kind[n.kind])}</category>
      <description>${xmlEsc(noticeHtml(n, o.lang, o.names))}</description>
    </item>`).join("\n");
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>${xmlEsc(title)}</title>
    <link>${xmlEsc(`${o.site}/status/`)}</link>
    <atom:link href="${xmlEsc(o.self)}" rel="self" type="application/rss+xml"/>
    <description>${xmlEsc(o.lang === "nl" ? "Storingen en gepland onderhoud van Bingr" : "Incidents and scheduled maintenance for Bingr")}</description>
    <language>${o.lang === "nl" ? "nl-nl" : "en-gb"}</language>
    <lastBuildDate>${xmlEsc(rfc(o.updated))}</lastBuildDate>
${entries}
  </channel>
</rss>
`;
}

// ---- abonneren ----
export function validEmail(e: unknown): string | null {
  const s = String(e ?? "").trim().toLowerCase();
  if (s.length < 6 || s.length > 254) return null;
  if (!/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(s)) return null;
  if (s.includes("..") || /\.$/.test(s.split("@")[1])) return null;
  return s;
}
export const validToken = (t: unknown) => typeof t === "string" && /^[A-Za-z0-9_-]{32,64}$/.test(t);
