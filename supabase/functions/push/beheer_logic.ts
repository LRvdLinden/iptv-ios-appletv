// Bingr push: meldingen naar de beheer-app Bingr Beheer (docs/PUSH.md, "Beheer-app"). Pure logica, zonder database of
// netwerk, zodat alles met `deno test` te controleren is (beheer_test.ts). Teksten in het Nederlands (de beheer-app is NL).
import { timeIn } from "./logic.ts";

export type Kind = "ticket" | "reply" | "build" | "status" | "purchase" | "mailing";
export type Pref = "tickets" | "replies" | "builds" | "status" | "purchases" | "mailings";
export const PREF_OF: Record<Kind, Pref> = {
  ticket: "tickets", reply: "replies", build: "builds", status: "status", purchase: "purchases", mailing: "mailings",
};
export type BeheerNotice = { kind: Kind; title: string; body: string; url: string };

/** Hoogstens zoveel losse meldingen per soort per ronde; daarboven één samenvatting. */
export const MAX_PER_KIND = 3;
export const TEXT_MAX = 120;
export const MANIFEST_EVERY_MS = 5 * 60_000;

/** Tekst op één regel, hoogstens `max` tekens (met … als er is afgekapt). */
export function clip(v: unknown, max = TEXT_MAX): string {
  const s = String(v ?? "").replace(/\s+/g, " ").trim();
  if (s.length <= max) return s;
  return s.slice(0, max - 1).replace(/\s+\S*$/, (m) => (m.length < 20 ? "" : m)).trimEnd() + "…";
}

const SUPPORT = (n: number | null) => (n == null ? "bingrbeheer://support" : `bingrbeheer://support/${n}`);
export const DOWNLOADS = "bingrbeheer://downloads";
export const STATUS = "bingrbeheer://status";

/** APNs-payload van de beheer-app: {aps:{alert:{title, body}, sound, "thread-id": kind}, kind, url}. */
export function beheerPayload(n: BeheerNotice) {
  return { aps: { alert: { title: n.title, body: n.body }, sound: "default", "thread-id": n.kind }, kind: n.kind, url: n.url };
}
/** Wil dit apparaat deze soort? Ontbreekt de voorkeur, dan aan. */
export function wants(prefs: unknown, kind: Kind): boolean {
  const p = prefs && typeof prefs === "object" && !Array.isArray(prefs) ? prefs as Record<string, unknown> : {};
  return p[PREF_OF[kind]] !== false;
}

const list = (ns: number[], max = 6) => ns.slice(0, max).map((n) => `#${n}`).join(", ") + (ns.length > max ? ", …" : "");

// ---------- tickets ----------
export type TicketRow = { number: number; subject: string | null };
export function ticketNotices(rows: TicketRow[]): BeheerNotice[] {
  const t = [...rows].sort((a, b) => a.number - b.number);
  if (t.length > MAX_PER_KIND) {
    return [{ kind: "ticket", title: `${t.length} nieuwe tickets`, body: list(t.map((r) => r.number)), url: SUPPORT(null) }];
  }
  return t.map((r) => ({ kind: "ticket", title: `Nieuw ticket #${r.number}`, body: clip(r.subject) || "(geen onderwerp)", url: SUPPORT(r.number) }));
}

// ---------- klantberichten ----------
// first = het eerste klantbericht van het ticket: dat ís het ticket (gemeld als "Nieuw ticket"), dus geen apart antwoord.
export type ReplyRow = { id: number; number: number; body: string | null; first: boolean };
export function replyNotices(rows: ReplyRow[]): BeheerNotice[] {
  const r = rows.filter((m) => !m.first).sort((a, b) => a.id - b.id);
  if (r.length > MAX_PER_KIND) {
    const nums = [...new Set(r.map((m) => m.number))];
    return [{
      kind: "reply", title: `${r.length} nieuwe antwoorden`, body: `Op ${list(nums)}`,
      url: SUPPORT(nums.length === 1 ? nums[0] : null),
    }];
  }
  return r.map((m) => ({ kind: "reply", title: `Nieuw antwoord op #${m.number}`, body: clip(m.body) || "(leeg bericht)", url: SUPPORT(m.number) }));
}

// ---------- aankopen (build 133, Stripe) ----------
// Alleen aantal en bedrag: nooit e-mailadres, naam of account-id.
export const OVERVIEW = "bingrbeheer://overview";
export type PurchaseRow = { paid_at: string; amount: number; currency: string };
const euro = (cents: number, cur: string) =>
  cur.toLowerCase() === "eur" ? `€ ${(cents / 100).toFixed(2).replace(".", ",")}` : `${(cents / 100).toFixed(2).replace(".", ",")} ${cur.toUpperCase()}`;
export function purchaseNotices(rows: PurchaseRow[]): BeheerNotice[] {
  if (!rows.length) return [];
  if (rows.length > MAX_PER_KIND) {
    const eur = rows.filter((r) => r.currency.toLowerCase() === "eur").reduce((a, r) => a + r.amount, 0);
    return [{ kind: "purchase", title: `${rows.length} nieuwe Lifetime-aankopen`, body: `Samen ${euro(eur, "eur")}`, url: OVERVIEW }];
  }
  return rows.map((r) => ({ kind: "purchase", title: "Nieuwe Lifetime-aankoop", body: euro(r.amount, r.currency), url: OVERVIEW }));
}
/** Nieuw watermerk: de laatste paid_at van de opgehaalde rijen, anders het oude. */
export function purchaseMark(rows: PurchaseRow[], prev: string): string {
  return rows.reduce((m, r) => (Date.parse(r.paid_at) > Date.parse(m) ? r.paid_at : m), prev);
}

// ---------- eigen mailing (beheer, tab Nieuwsbrief) ----------
// Een mailing is klaar (status done): "Mailing verstuurd (x ontvangers)". Alleen aantallen en het NL-onderwerp (door de
// beheerder geschreven), nooit adressen.
export const NEWSLETTER = "bingrbeheer://newsletter";
export type MailingRow = { id: number; recipients: number; sent: number; failed: number; subject?: string | null };
const nf = (n: number) => Math.max(0, Math.floor(Number(n) || 0)).toLocaleString("nl-NL");
export function mailingNotices(rows: MailingRow[]): BeheerNotice[] {
  if (rows.length > MAX_PER_KIND) {
    const sent = rows.reduce((a, r) => a + (Number(r.sent) || 0), 0);
    return [{ kind: "mailing", title: `${rows.length} mailings verstuurd`, body: `Samen ${nf(sent)} verstuurd`, url: NEWSLETTER }];
  }
  return rows.map((r) => {
    const n = Math.max(0, Number(r.recipients) || 0);
    const parts = [`${nf(r.sent)} verstuurd`, ...(Number(r.failed) > 0 ? [`${nf(r.failed)} mislukt`] : [])].join(", ");
    const subj = clip(r.subject ?? "", 80);
    return { kind: "mailing" as const, title: `Mailing verstuurd (${nf(n)} ${n === 1 ? "ontvanger" : "ontvangers"})`, body: subj ? `${subj} · ${parts}` : parts, url: NEWSLETTER };
  });
}

// ---------- builds ----------
export const BUILD_NAMES: Record<string, string> = { android: "Android", tizen: "Samsung TV", apple: "Apple", beheer: "Beheer-app" };
export type Builds = Record<string, number>;
/** Builds uit manifest.json ({platforms:{android:{build}, …}}): alleen geldige nummers. */
export function manifestBuilds(m: unknown): Builds {
  const p = (m as { platforms?: Record<string, { build?: unknown }> })?.platforms ?? {};
  const out: Builds = {};
  for (const k of Object.keys(BUILD_NAMES)) {
    const b = Number(p?.[k]?.build);
    if (Number.isInteger(b) && b > 0) out[k] = b;
  }
  return out;
}
/** Nieuwe builds ten opzichte van het watermerk. Een platform zonder watermerk wordt stil vastgelegd (eerste keer). */
export function buildNotices(current: Builds, mark: Builds): { notices: BeheerNotice[]; mark: Builds } {
  const next: Builds = { ...mark };
  const fresh: { p: string; b: number }[] = [];
  for (const [p, b] of Object.entries(current)) {
    const was = Number(mark[p]);
    if (!Number.isFinite(was)) { next[p] = b; continue; }
    if (b > was) { fresh.push({ p, b }); next[p] = b; }
  }
  const notices: BeheerNotice[] = fresh.length > MAX_PER_KIND
    ? [{ kind: "build", title: `${fresh.length} nieuwe builds staan klaar`, body: "In Downloads op beheer.bingr.online", url: DOWNLOADS }]
    : fresh.map(({ p, b }) => ({ kind: "build", title: `${BUILD_NAMES[p] ?? p}-build ${b} staat klaar`, body: "In Downloads op beheer.bingr.online", url: DOWNLOADS }));
  return { notices, mark: next };
}

// ---------- statusmonitors ----------
// Staat per monitor = is er een open storing (status_incidents zonder ended_at)? De functie status opent die pas na 2 fouten
// op rij en sluit hem na 2 goede controles (FAILS_TO_OPEN / OKS_TO_CLOSE), dus flapperen geeft geen meldingen.
export type MonState = { s: "up" | "down"; since?: string | null };
export type Monitors = Record<string, MonState>;
export type MonitorNow = { id: string; name: string; down: boolean; since?: string | null };

/** "minder dan een minuut", "12 min", "2 u 5 min", "3 d 4 u". */
export function fmtDuration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return "minder dan een minuut";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60), rm = m % 60;
  if (h < 24) return rm ? `${h} u ${rm} min` : `${h} u`;
  const d = Math.floor(h / 24), rh = h % 24;
  return rh ? `${d} d ${rh} u` : `${d} d`;
}

/** Overgangen ten opzichte van het watermerk. Een monitor zonder watermerk wordt stil vastgelegd; verdwenen monitors gaan weg. */
export function statusNotices(now: MonitorNow[], mark: Monitors, nowMs: number, tz = "Europe/Amsterdam"): { notices: BeheerNotice[]; mark: Monitors } {
  const next: Monitors = {};
  const changes: BeheerNotice[] = [];
  let downs = 0, ups = 0;
  for (const m of now) {
    const was = mark[m.id];
    const s: "up" | "down" = m.down ? "down" : "up";
    if (!was) { next[m.id] = { s, since: m.down ? m.since ?? new Date(nowMs).toISOString() : null }; continue; }
    if (was.s === s) { next[m.id] = was; continue; }
    if (s === "down") {
      const since = m.since ?? new Date(nowMs).toISOString();
      next[m.id] = { s, since };
      downs++;
      changes.push({ kind: "status", title: `Storing: ${clip(m.name, 60)}`, body: `Sinds ${timeIn(Date.parse(since), tz)}`, url: STATUS });
    } else {
      next[m.id] = { s, since: null };
      ups++;
      const t = was.since ? Date.parse(was.since) : NaN;
      const body = Number.isFinite(t) ? `Na ${fmtDuration((nowMs - t) / 1000)} weer bereikbaar` : "Weer bereikbaar";
      changes.push({ kind: "status", title: `Weer online: ${clip(m.name, 60)}`, body, url: STATUS });
    }
  }
  if (changes.length > MAX_PER_KIND) {
    const parts = [downs ? `${downs} ${downs === 1 ? "storing" : "storingen"}` : "", ups ? `${ups} weer online` : ""].filter(Boolean);
    return { notices: [{ kind: "status", title: `${changes.length} statuswijzigingen`, body: parts.join(", "), url: STATUS }], mark: next };
  }
  return { notices: changes, mark: next };
}

// ---------- watermerken ----------
export type State = {
  last_ticket_number: number | null; last_message_id: number | null; builds: Builds | null; monitors: Monitors | null;
  builds_checked_at: string | null;
};
export type Current = {
  maxTicket: number; maxMessage: number; builds: Builds | null; monitors: MonitorNow[];
};
/**
 * Eerste keer (geen rij, of een veld leeg): op de huidige stand zetten zonder te melden. Geeft per soort terug of er al een
 * watermerk was (alleen dan mag die soort melden).
 */
export function initState(row: Partial<State> | null, cur: Current, nowMs: number): { state: State; armed: Record<Exclude<Kind, "purchase" | "mailing">, boolean> } {
  const r = row ?? {};
  const num = (v: unknown) => (v == null || v === "" || !Number.isFinite(Number(v)) ? null : Number(v));
  const obj = <T>(v: unknown) => (v && typeof v === "object" && !Array.isArray(v) ? v as T : null);
  const lt = num(r.last_ticket_number), lm = num(r.last_message_id);
  const b = obj<Builds>(r.builds), m = obj<Monitors>(r.monitors);
  const monitors: Monitors = {};
  if (!m) for (const x of cur.monitors) monitors[x.id] = { s: x.down ? "down" : "up", since: x.down ? x.since ?? new Date(nowMs).toISOString() : null };
  return {
    state: {
      last_ticket_number: lt ?? cur.maxTicket,
      last_message_id: lm ?? cur.maxMessage,
      builds: b ?? cur.builds, // null zolang het manifest niet op te halen is: dan volgende keer vastleggen
      monitors: m ?? monitors,
      builds_checked_at: r.builds_checked_at ?? null,
    },
    armed: { ticket: lt != null, reply: lm != null, build: b != null, status: m != null },
  };
}
/** Manifest opnieuw ophalen? Hoogstens elke 5 minuten. */
export function manifestDue(checkedAt: string | null | undefined, nowMs: number): boolean {
  const t = checkedAt ? Date.parse(checkedAt) : NaN;
  return !Number.isFinite(t) || nowMs - t >= MANIFEST_EVERY_MS - 15_000;
}
