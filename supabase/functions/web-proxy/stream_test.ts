// deno test supabase/functions/web-proxy/stream_test.ts
// Spoedfix 25-10-2026: grote antwoorden (Xtream get_vod_streams, tientallen MB) stromen door zonder te bufferen; grens 200 MB.
import { capStream } from "./stream.ts";

function ok(v: unknown, msg: string) { if (!v) throw new Error(`niet waar: ${msg}`); }

Deno.test("stroom: elk stuk gaat meteen door (geen bufferen), bytes geteld", async () => {
  let push!: (b: Uint8Array | null) => void;
  const src = new ReadableStream<Uint8Array>({ start(c) { push = (b) => b ? c.enqueue(b) : c.close(); } });
  let counted = 0, done = 0;
  const out = src.pipeThrough(capStream(200 * 1024 * 1024, (n) => { counted += n; }, () => { throw new Error("niet over de grens"); }, () => { done++; }));
  const r = out.getReader();
  push(new Uint8Array(1024 * 1024));
  // het eerste stuk is te lezen terwijl de bron nog open is: dus niet gebufferd tot het einde
  const first = await r.read();
  ok(first.value?.byteLength === 1024 * 1024, "eerste stuk direct");
  push(new Uint8Array(5)); push(null);
  let n = first.value!.byteLength;
  for (;;) { const { done: d, value } = await r.read(); if (d) break; n += value.byteLength; }
  ok(n === 1024 * 1024 + 5 && counted === n, "alles doorgegeven en geteld");
  ok(done === 1, "timer opgeruimd");
});
Deno.test("stroom: boven de grens afbreken met too_large", async () => {
  let over = 0, done = 0;
  const src = new ReadableStream<Uint8Array>({ start(c) { for (let i = 0; i < 10; i++) c.enqueue(new Uint8Array(100)); c.close(); } });
  const r = src.pipeThrough(capStream(450, () => {}, () => { over++; }, () => { done++; })).getReader();
  let n = 0, err = "";
  try { for (;;) { const { done: d, value } = await r.read(); if (d) break; n += value.byteLength; } } catch (e) { err = (e as Error).message; }
  ok(err === "too_large" && n === 400 && over === 1 && done >= 1, `afgebroken na 400 bytes (${n}, ${err})`);
});
Deno.test("stroom: 60 MB in stukken van 64 KB (lijst van een grote server)", async () => {
  const CH = 64 * 1024, N = 960; // 60 MB
  let i = 0;
  const src = new ReadableStream<Uint8Array>({ pull(c) { if (i++ < N) c.enqueue(new Uint8Array(CH)); else c.close(); } });
  let n = 0;
  const r = src.pipeThrough(capStream(200 * 1024 * 1024, () => {}, () => {}, () => {})).getReader();
  for (;;) { const { done, value } = await r.read(); if (done) break; n += value.byteLength; }
  ok(n === CH * N, "60 MB door");
});
