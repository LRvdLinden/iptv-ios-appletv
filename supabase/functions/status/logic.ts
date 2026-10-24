// Bingr-status: pure rekenregels (zonder database of netwerk), los te testen met `deno test`.

export type State = "up" | "degraded" | "down";
export type DayState = State | "none";

/** Uitkomst van één controle. skip = niet meetellen (bv. SMTP niet ingesteld of GitHub-limiet bereikt). */
export interface CheckResult {
  ok: boolean;
  degraded?: boolean;
  code?: number | null;
  ms?: number | null;
  error?: string | null;
  detail?: string | null;
  skip?: boolean;
  /** build 147: de controle heeft de storing zelf al bevestigd (bv. 2 mislukte builds op rij): meteen een storing */
  confirmed?: boolean;
}

export interface MonitorState {
  fail_streak: number;
  ok_streak: number;
  open: boolean; // er loopt een storing
}

export interface Evaluation {
  fail_streak: number;
  ok_streak: number;
  checkState: State; // wat in status_checks komt
  current: State; // toestand van de monitor na deze controle
  open: boolean; // storing openen
  close: boolean; // storing sluiten
}

/** Na hoeveel opeenvolgende fouten een storing begint, en na hoeveel goede controles hij voorbij is. */
export const FAILS_TO_OPEN = 2;
export const OKS_TO_CLOSE = 2;

/**
 * Eén controle verwerken. Een losse fout telt als "verminderd" (degraded); vanaf de tweede fout op rij is het een
 * storing (down) en gaat er een incident open. Een open storing sluit na twee goede controles op rij; tot die tijd
 * blijft de monitor op "down" staan, maar de goede controles zelf tellen als up.
 */
export function evaluate(prev: MonitorState, r: CheckResult): Evaluation {
  if (r.ok) {
    const ok_streak = prev.ok_streak + 1;
    const close = prev.open && ok_streak >= OKS_TO_CLOSE;
    const checkState: State = r.degraded ? "degraded" : "up";
    return { fail_streak: 0, ok_streak, checkState, current: prev.open && !close ? "down" : checkState, open: false, close };
  }
  const fail_streak = prev.fail_streak + 1;
  const open = !prev.open && (fail_streak >= FAILS_TO_OPEN || r.confirmed === true);
  const down = prev.open || open;
  return { fail_streak, ok_streak: 0, checkState: down ? "down" : "degraded", current: down ? "down" : "degraded", open, close: false };
}

/** Uptime in procenten: alleen bevestigde storingen (down) tellen als uit. Naar beneden afgerond op 2 decimalen. */
export function uptimePct(n: number, nDown: number): number | null {
  if (!n || n <= 0) return null;
  const v = ((n - Math.min(nDown, n)) / n) * 100;
  return Math.floor(v * 100 + 1e-9) / 100;
}

export interface DayRow { m: string; d: string; n: number; g: number; x: number; ms?: number | null }
export interface DayPoint { d: string; u: number | null; s: DayState; n: number }

/** Datum (YYYY-MM-DD) min `k` dagen. */
export function addDays(day: string, k: number): string {
  const t = Date.UTC(+day.slice(0, 4), +day.slice(5, 7) - 1, +day.slice(8, 10)) + k * 864e5;
  return new Date(t).toISOString().slice(0, 10);
}

/** Reeks van `days` dagen (oudste eerst, laatste = today) met uptime en slechtste toestand per dag. */
export function daySeries(rows: DayRow[], today: string, days = 90): DayPoint[] {
  const by = new Map(rows.map((r) => [r.d.slice(0, 10), r]));
  const out: DayPoint[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = addDays(today, -i);
    const r = by.get(d);
    if (!r || !r.n) { out.push({ d, u: null, s: "none", n: 0 }); continue; }
    out.push({ d, u: uptimePct(r.n, r.x), s: r.x > 0 ? "down" : r.g > 0 ? "degraded" : "up", n: r.n });
  }
  return out;
}

/** Uptime over de laatste `days` kalenderdagen (inclusief vandaag) uit de dagtotalen. */
export function windowUptime(rows: DayRow[], today: string, days: number): number | null {
  const from = addDays(today, -(days - 1));
  let n = 0, x = 0;
  for (const r of rows) {
    const d = r.d.slice(0, 10);
    if (d >= from && d <= today) { n += r.n; x += r.x; }
  }
  return uptimePct(n, x);
}

/** Moet deze monitor nu gecontroleerd worden? 45 s speling, zodat een cron-tik van 5 min een interval van 5 min haalt. */
export function isDue(lastCheckedAt: string | null | undefined, intervalMin: number, now = Date.now()): boolean {
  if (!lastCheckedAt) return true;
  const t = Date.parse(lastCheckedAt);
  if (!Number.isFinite(t)) return true;
  return now - t >= intervalMin * 60_000 - 45_000;
}

export interface Overall { state: State; down: string[]; degraded: string[] }

/** Totaalbeeld: één monitor down = storing; anders één verminderd = verminderde prestaties. */
export function overall(monitors: { id: string; state: State | null }[]): Overall {
  const down = monitors.filter((m) => m.state === "down").map((m) => m.id);
  const degraded = monitors.filter((m) => m.state === "degraded").map((m) => m.id);
  return { state: down.length ? "down" : degraded.length ? "degraded" : "up", down, degraded };
}

/** Duur in seconden (lopend: tot nu). */
export function durationS(start: string, end: string | null, now = Date.now()): number {
  return Math.max(0, Math.round(((end ? Date.parse(end) : now) - Date.parse(start)) / 1000));
}

/** Korte foutmelding voor de database en de e-mail. */
export function shortError(e: unknown): string {
  const s = e instanceof Error ? (e.name === "TimeoutError" || e.name === "AbortError" ? "timeout" : e.message) : String(e);
  return s.replace(/\s+/g, " ").trim().slice(0, 160) || "error";
}

// ---- build 147: GitHub-build-monitors (Apple, Android, Windows, webOS) ----
// Alleen de echte build- en aanleverjob(s) tellen (doel "repo|workflow|branch|job1,job2"), niet test- of rooktest-jobs
// en niet de conclusie van de hele run. Geannuleerde, overgeslagen en lopende runs tellen niet: dan geldt de laatste
// afgeronde run. Eén mislukte run = verminderd; een storing pas na 2 mislukte runs op rij, of als een mislukte build al
// langer dan 2 uur de laatste is.
export const GH_DOWN_AFTER_RUNS = 2;
export const GH_DOWN_AFTER_MS = 2 * 3600_000;
export interface GhJob { name?: string; status?: string; conclusion?: string | null }
export interface GhRun { id?: number; run_number?: number; head_sha?: string; status?: string; conclusion?: string | null; updated_at?: string; created_at?: string }
/** Uitkomst van één afgeronde run voor de monitor: true = goed, false = mislukt, null = telt niet. */
export type RunOutcome = boolean | null;

const NOT_COUNTED = ["cancelled", "skipped", "neutral", "stale"];
const FAILED = ["failure", "timed_out", "startup_failure", "action_required"];
// jobs die nooit tellen als er geen vaste jobnamen zijn opgegeven (of die niet in de run voorkomen)
export const TEST_JOB = /(test|smoke|rook|lint|screenshot|sdk\d+|e2e|check)/i;

/** Jobnamen uit het doel ("build" of "apk,tizen"); leeg = alle jobs behalve test-jobs. */
export function ghJobNames(target: string): string[] {
  return (target.split("|")[3] || "").split(",").map((s) => s.trim()).filter(Boolean);
}
/** Hoort deze job bij de namen? Ook matrix-jobs: "build (ios)" bij "build". */
const jobMatches = (job: string, names: string[]) => names.some((n) => job === n || job.startsWith(`${n} (`));

/** Wordt een run meegeteld, en zo ja: is de echte build goed? */
export function runOutcome(run: GhRun, jobs: GhJob[] | null, names: string[]): RunOutcome {
  if (run.status && run.status !== "completed") return null; // loopt nog
  if (NOT_COUNTED.includes(String(run.conclusion))) return null; // geannuleerd (vervangen door een nieuwere push) e.d.
  if (!jobs) return run.conclusion === "success" ? true : FAILED.includes(String(run.conclusion)) ? false : null;
  let rel = names.length ? jobs.filter((j) => jobMatches(String(j.name ?? ""), names)) : [];
  if (!rel.length) rel = jobs.filter((j) => !TEST_JOB.test(String(j.name ?? "")));
  // jobs die niet gedraaid hebben (overgeslagen, geannuleerd) tellen niet; geen enkele = de run telt niet
  const done = rel.filter((j) => (j.status ?? "completed") === "completed" && !NOT_COUNTED.includes(String(j.conclusion)));
  if (!done.length) return null;
  if (done.some((j) => FAILED.includes(String(j.conclusion)))) return false;
  return done.every((j) => j.conclusion === "success") ? true : null;
}

export interface GhCounted { run: GhRun; ok: boolean }
/** Uitkomst voor de monitor uit de meegetelde runs (nieuwste eerst). */
export function ghVerdict(counted: GhCounted[], now = Date.now()): CheckResult {
  const last = counted[0];
  if (!last) return { ok: true, skip: true, error: "nog geen afgeronde build" };
  const detail = `run ${last.run.run_number ?? "?"} (${String(last.run.head_sha ?? "").slice(0, 7)})`;
  if (last.ok) return { ok: true, detail };
  let fails = 0;
  for (const c of counted) { if (c.ok) break; fails++; }
  const at = Date.parse(last.run.updated_at ?? last.run.created_at ?? "");
  const old = Number.isFinite(at) && now - at > GH_DOWN_AFTER_MS;
  if (fails >= GH_DOWN_AFTER_RUNS) return { ok: false, confirmed: true, error: `build mislukt (${fails} runs op rij)`, detail };
  if (old) return { ok: false, confirmed: true, error: "build mislukt (al langer dan 2 uur de laatste)", detail };
  return { ok: true, degraded: true, error: "laatste build mislukt (1 run)", detail: `${detail}: mislukt` };
}
