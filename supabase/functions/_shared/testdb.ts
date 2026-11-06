// ALLEEN VOOR TESTS (build 167): een kleine nep-database in het geheugen met het deel van de supabase-js-API dat de
// *_store.ts-bestanden gebruiken (select/eq/neq/is/in/not/limit/maybeSingle/update/delete/insert/upsert en rpc).
// Unieke kolommen per tabel geven 23505, zoals Postgres.
type Row = Record<string, unknown>;
export type FakeDb = ReturnType<typeof fakeDb>;

export function fakeDb(unique: Record<string, string[]> = {}, rpcs: Record<string, (args: Record<string, unknown>) => unknown> = {}) {
  const t: Record<string, Row[]> = {};
  const tab = (n: string) => (t[n] ??= []);
  let seq = 1;
  const clash = (table: string, o: Row, skip?: Row) =>
    (unique[table] ?? []).some((k) => o[k] !== null && o[k] !== undefined && tab(table).some((r) => r !== skip && r[k] === o[k]));
  function q(table: string) {
    const f: ((r: Row) => boolean)[] = [];
    let op: "select" | "update" | "delete" = "select", patch: Row = {}, lim = 1e9;
    const rows = () => tab(table).filter((r) => f.every((fn) => fn(r)));
    const run = () => {
      if (op === "update") {
        for (const r of rows()) {
          const next = { ...r, ...Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== undefined)) };
          if (clash(table, next, r)) return { data: null, error: { code: "23505" } };
          Object.assign(r, next);
        }
        return { data: null, error: null };
      }
      if (op === "delete") { const del = new Set(rows()); t[table] = tab(table).filter((r) => !del.has(r)); return { data: null, error: null }; }
      return { data: rows().slice(0, lim).map((r) => ({ ...r })), error: null };
    };
    const b = {
      select: () => b, order: () => b,
      eq: (k: string, v: unknown) => { f.push((r) => r[k] === v); return b; },
      neq: (k: string, v: unknown) => { f.push((r) => r[k] !== v); return b; },
      is: (k: string, v: unknown) => { f.push((r) => (r[k] ?? null) === v); return b; },
      in: (k: string, v: unknown[]) => { f.push((r) => v.includes(r[k])); return b; },
      not: (k: string, _op: string, v: unknown) => { f.push((r) => (r[k] ?? null) !== v); return b; },
      limit: (n: number) => { lim = n; return b; },
      update: (p: Row) => { op = "update"; patch = p; return b; },
      delete: () => { op = "delete"; return b; },
      maybeSingle: () => Promise.resolve({ data: (run().data as Row[] | null)?.[0] ?? null, error: null }),
      then: (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) => Promise.resolve(run()).then(res, rej),
      insert: (o: Row) => {
        if (clash(table, o)) return Promise.resolve({ data: null, error: { code: "23505" } });
        tab(table).push({ id: seq++, ...Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) });
        return Promise.resolve({ data: null, error: null });
      },
      upsert: (o: Row, opts?: { onConflict?: string; ignoreDuplicates?: boolean }) => {
        const k = opts?.onConflict ?? "id", cur = tab(table).find((r) => r[k] === o[k]);
        const clean = Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
        if (cur) { if (!opts?.ignoreDuplicates) Object.assign(cur, clean); } else tab(table).push({ id: seq++, ...clean });
        return Promise.resolve({ data: null, error: null });
      },
    };
    return b;
  }
  return {
    t, from: q, tab,
    rpc: (name: string, args: Record<string, unknown>) =>
      Promise.resolve(rpcs[name] ? { data: rpcs[name](args), error: null } : { data: null, error: { code: "PGRST202" } }),
  };
}
