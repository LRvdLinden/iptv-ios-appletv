// Security M2: HTTP/1.1-aanvraag naar een vooraf gecontroleerd IP-adres, voor http én https. fetch() lost de hostnaam zelf
// nog eens op (DNS-rebinding: eerst een publiek adres, bij de verbinding een intern adres). Hier gaat de TCP-verbinding naar
// precies het IP dat de proxy net heeft gecontroleerd; voor https daarna TLS op die verbinding met SNI en
// certificaatcontrole op de echte hostnaam (Deno.startTls). Alleen GET, Connection: close, geen keep-alive.
// Antwoord als gewone Response (gestreamd), met Content-Length, chunked of tot het einde van de verbinding;
// gzip/deflate wordt uitgepakt (we vragen identity, maar niet elke server luistert). Getest in pinned_test.ts.

export type PinnedOptions = {
  ip: string;
  headers: Record<string, string>;
  signal: AbortSignal;
  connectTimeoutMs?: number;
  /** alleen voor de tests (eigen CA); in productie de standaard-CA's van de runtime */
  caCerts?: string[];
};

const MAX_HEAD = 64 * 1024;

/**
 * Spoedfix 25-10-2026: foutsoort per stap, zodat de proxy (en de gebruiker) weet wat er misging in plaats van een kale
 * upstream_failed. Nooit een host, IP of URL in `kind` of in de melding.
 *   connect_refused · connect_reset · connect_timeout · connect_failed · tls_failed · tls_timeout · no_response · bad_response
 */
export type PinnedKind = "connect_refused" | "connect_reset" | "connect_timeout" | "connect_failed" | "tls_failed" | "tls_timeout" | "no_response" | "bad_response";
export class PinnedError extends Error {
  constructor(public kind: PinnedKind) { super(kind); this.name = "PinnedError"; }
}
/** Foutsoort van een fout van Deno.connect / Deno.startTls / lezen (pure functie, getest). */
export function pinnedKind(e: unknown, phase: "connect" | "tls" | "read"): PinnedKind {
  if (e instanceof PinnedError) return e.kind;
  const name = (e as { name?: string } | null)?.name ?? "";
  const msg = String((e as { message?: string } | null)?.message ?? e ?? "").toLowerCase();
  if (msg === "connect_timeout") return "connect_timeout";
  if (msg === "tls_timeout") return "tls_timeout";
  if (name === "ConnectionRefused" || /refused/.test(msg)) return "connect_refused";
  if (name === "ConnectionReset" || name === "BrokenPipe" || /reset|broken pipe/.test(msg)) return phase === "tls" ? "tls_failed" : phase === "read" ? "no_response" : "connect_reset";
  if (phase === "tls" || /certificate|tls|handshake|alert|unknownissuer|invalid ?peer/.test(msg)) return "tls_failed";
  if (phase === "connect") return /timed? ?out/.test(msg) ? "connect_timeout" : "connect_failed";
  if (/^(no_response|unexpected ?eof)/.test(msg) || name === "UnexpectedEof") return "no_response";
  return "bad_response";
}
const enc = new TextEncoder();
const dec = new TextDecoder();

class Bytes {
  buf: Uint8Array = new Uint8Array(0);
  done = false;
  constructor(private reader: ReadableStreamDefaultReader<Uint8Array>) {}
  async more(): Promise<boolean> {
    if (this.done) return false;
    const { done, value } = await this.reader.read();
    if (done || !value) { this.done = true; return false; }
    // spoedfix 25-10: lege buffer = het stuk zelf (geen kopie per stuk; scheelt CPU-tijd bij lijsten van tientallen MB)
    if (!this.buf.length) { this.buf = value; return true; }
    const n = new Uint8Array(this.buf.length + value.length);
    n.set(this.buf); n.set(value, this.buf.length);
    this.buf = n;
    return true;
  }
  take(n: number): Uint8Array {
    const out = this.buf.subarray(0, n);
    this.buf = this.buf.subarray(n);
    return out;
  }
  indexOf(seq: number[], from = 0): number {
    outer: for (let i = from; i <= this.buf.length - seq.length; i++) {
      for (let j = 0; j < seq.length; j++) if (this.buf[i + j] !== seq[j]) continue outer;
      return i;
    }
    return -1;
  }
  // regel tot LF; een CR ervoor valt weg (sommige IPTV-panels sturen alleen LF)
  async line(max = 8192): Promise<string | null> {
    for (;;) {
      const i = this.indexOf([10]);
      if (i >= 0) { const raw = this.take(i); this.take(1); return dec.decode(raw.length && raw[raw.length - 1] === 13 ? raw.subarray(0, raw.length - 1) : raw); }
      if (this.buf.length > max) throw new Error("line_too_long");
      if (!(await this.more())) return null;
    }
  }
  cancel() { try { this.reader.cancel().catch(() => {}); } catch { /* al dicht */ } }
}

const clean = (v: string) => v.replace(/[\r\n\0]/g, "");

/** Einde van de kop: CRLFCRLF of (tolerant) LFLF. → [index, lengte scheiding] of null. */
function headEnd(b: Bytes): [number, number] | null {
  const a = b.indexOf([13, 10, 13, 10]), l = b.indexOf([10, 10]);
  if (a < 0 && l < 0) return null;
  if (a >= 0 && (l < 0 || a <= l)) return [a, 4];
  return [l, 2];
}

/** Kop van het antwoord: "HTTP/1.1 200 OK" + kopregels. 1xx (100 Continue) wordt overgeslagen. Ook met alleen LF. */
async function readHead(b: Bytes): Promise<{ status: number; headers: Headers }> {
  for (let round = 0; round < 5; round++) {
    let end: [number, number] | null;
    while (!(end = headEnd(b))) {
      if (b.buf.length > MAX_HEAD) throw new PinnedError("bad_response");
      if (!(await b.more())) throw new PinnedError(b.buf.length ? "bad_response" : "no_response");
    }
    const head = dec.decode(b.take(end[0])); b.take(end[1]);
    const lines = head.split(/\r?\n/);
    // "HTTP/1.1 200 OK", "HTTP/1.0 200", "HTTP/1.1 200" (zonder reden), ook ICY (Shoutcast) en kleine letters
    const m = /^(?:HTTP\/1\.[01]|ICY) +(\d{3})(?:\s.*)?$/i.exec((lines[0] ?? "").trim());
    if (!m) throw new PinnedError("bad_response");
    const status = Number(m[1]);
    const headers = new Headers();
    for (const l of lines.slice(1)) {
      const i = l.indexOf(":");
      if (i <= 0) continue;
      const k = l.slice(0, i).trim(), v = l.slice(i + 1).trim();
      if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(k)) continue;
      try { headers.append(k, v); } catch { /* ongeldige waarde: overslaan */ }
    }
    if (status >= 100 && status < 200) continue;
    if (status < 200 || status > 599) throw new PinnedError("bad_response");
    return { status, headers };
  }
  throw new PinnedError("bad_response");
}

function bodyStream(b: Bytes, headers: Headers, close: () => void): ReadableStream<Uint8Array> {
  const te = (headers.get("transfer-encoding") ?? "").toLowerCase();
  const cl = headers.get("content-length");
  if (te.includes("chunked")) {
    let left = 0, finished = false;
    return new ReadableStream<Uint8Array>({
      async pull(c) {
        try {
          if (finished) { c.close(); close(); return; }
          if (left === 0) {
            const l = await b.line();
            if (l == null) throw new Error("chunk_eof");
            const size = parseInt(l.split(";")[0].trim(), 16);
            if (!Number.isFinite(size) || size < 0) throw new Error("bad_chunk");
            if (size === 0) {
              // trailers tot een lege regel
              for (let i = 0; i < 100; i++) { const t = await b.line(); if (t == null || t === "") break; }
              finished = true; c.close(); close(); return;
            }
            left = size;
          }
          if (!b.buf.length && !(await b.more())) throw new Error("chunk_eof");
          const part = b.take(Math.min(left, b.buf.length));
          left -= part.length;
          c.enqueue(part); // view: de buffer wordt nooit overschreven
          if (left === 0) {
            // regeleinde na het stuk (CRLF, of alleen LF)
            if ((await b.line(16)) !== "") throw new Error("bad_chunk");
          }
        } catch (e) { c.error(e); close(); }
      },
      cancel() { b.cancel(); close(); },
    });
  }
  if (cl != null && /^\d+$/.test(cl.trim())) {
    let left = Number(cl.trim());
    return new ReadableStream<Uint8Array>({
      async pull(c) {
        try {
          if (left <= 0) { c.close(); close(); return; }
          if (!b.buf.length && !(await b.more())) { c.error(new Error("body_eof")); close(); return; }
          const part = b.take(Math.min(left, b.buf.length));
          left -= part.length;
          c.enqueue(part); // view: de buffer wordt nooit overschreven
          if (left <= 0) { c.close(); close(); }
        } catch (e) { c.error(e); close(); }
      },
      cancel() { b.cancel(); close(); },
    });
  }
  // tot de server de verbinding sluit
  return new ReadableStream<Uint8Array>({
    async pull(c) {
      try {
        if (!b.buf.length && !(await b.more())) { c.close(); close(); return; }
        c.enqueue(b.take(b.buf.length));
      } catch (e) { c.error(e); close(); }
    },
    cancel() { b.cancel(); close(); },
  });
}

/** GET `url` via een verbinding met precies `ip` (http, of https met TLS op de echte hostnaam). */
export async function pinnedFetch(url: URL, o: PinnedOptions): Promise<Response> {
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("bad_protocol");
  if (o.signal.aborted) throw new DOMException("aborted", "AbortError");
  const port = url.port ? Number(url.port) : url.protocol === "https:" ? 443 : 80;
  const hostname = o.ip.replace(/^\[|\]$/g, "");
  let conn: Deno.Conn | Deno.TlsConn | null = null;
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    try { conn?.close(); } catch { /* al dicht */ }
  };
  const onAbort = () => close();
  o.signal.addEventListener("abort", onAbort, { once: true });
  try {
    const timeout = o.connectTimeoutMs ?? 10_000;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const pending = Deno.connect({ hostname, port, transport: "tcp" });
    let tcp: Deno.TcpConn;
    try {
      tcp = await Promise.race([
        pending,
        new Promise<never>((_, rej) => { timer = setTimeout(() => rej(new PinnedError("connect_timeout")), timeout); }),
      ]).finally(() => clearTimeout(timer));
    } catch (e) {
      // komt de verbinding na de time-out alsnog tot stand: meteen weer sluiten (geen lek, geen onafgehandelde fout)
      pending.then((c) => { try { c.close(); } catch { /* al dicht */ } }, () => {});
      if (o.signal.aborted) throw new DOMException("aborted", "AbortError");
      throw new PinnedError(pinnedKind(e, "connect"));
    }
    conn = tcp;
    if (o.signal.aborted) throw new DOMException("aborted", "AbortError");
    if (url.protocol === "https:") {
      let t2: ReturnType<typeof setTimeout> | undefined;
      try {
        // handshake meteen (anders komt een certificaatfout pas bij het eerste schrijven), binnen dezelfde time-out
        const tlsP = Deno.startTls(tcp, { hostname: url.hostname, alpnProtocols: ["http/1.1"], ...(o.caCerts ? { caCerts: o.caCerts } : {}) })
          .then(async (t) => {
            try { if (typeof t.handshake === "function") await t.handshake(); } catch (e) { try { t.close(); } catch { /* al dicht */ } throw e; }
            return t;
          });
        tlsP.catch(() => {}); // na een time-out geen onafgehandelde afwijzing
        conn = await Promise.race([
          tlsP,
          new Promise<never>((_, rej) => { t2 = setTimeout(() => rej(new PinnedError("tls_timeout")), timeout); }),
        ]).finally(() => clearTimeout(t2));
      } catch (e) {
        if (o.signal.aborted) throw new DOMException("aborted", "AbortError");
        throw new PinnedError(pinnedKind(e, "tls"));
      }
    }
    const lines = [`GET ${url.pathname || "/"}${url.search} HTTP/1.1`, `Host: ${url.host}`];
    for (const [k, v] of Object.entries(o.headers)) {
      const lk = k.toLowerCase();
      if (lk === "host" || lk === "connection" || lk === "content-length" || lk === "transfer-encoding") continue;
      if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(k)) continue;
      lines.push(`${k}: ${clean(v)}`);
    }
    lines.push("Connection: close", "", "");
    let b: Bytes, status: number, headers: Headers;
    try {
      const w = conn.writable.getWriter();
      await w.write(enc.encode(lines.join("\r\n")));
      w.releaseLock();
      b = new Bytes(conn.readable.getReader());
      ({ status, headers } = await readHead(b));
    } catch (e) {
      if (o.signal.aborted) throw new DOMException("aborted", "AbortError");
      // TLS-fouten (certificaat) komen bij rustls pas bij het eerste schrijven/lezen naar boven
      const k = pinnedKind(e, "read");
      throw new PinnedError(url.protocol === "https:" && k === "bad_response" && /certificate|tls|handshake|alert|issuer/i.test(String((e as Error)?.message)) ? "tls_failed" : k);
    }
    const noBody = status === 204 || status === 304;
    let body: ReadableStream<Uint8Array> | null = noBody ? null : bodyStream(b, headers, () => { o.signal.removeEventListener("abort", onAbort); close(); });
    if (noBody) { o.signal.removeEventListener("abort", onAbort); close(); }
    headers.delete("transfer-encoding");
    const ce = (headers.get("content-encoding") ?? "").toLowerCase().trim();
    if (body && (ce === "gzip" || ce === "x-gzip" || ce === "deflate")) {
      body = body.pipeThrough(new DecompressionStream(ce === "deflate" ? "deflate" : "gzip") as unknown as TransformStream<Uint8Array, Uint8Array>);
      headers.delete("content-encoding"); headers.delete("content-length");
    }
    return new Response(body, { status, headers });
  } catch (e) {
    o.signal.removeEventListener("abort", onAbort);
    close();
    if (o.signal.aborted) throw new DOMException("aborted", "AbortError");
    throw e;
  }
}
