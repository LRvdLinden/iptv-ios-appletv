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
const enc = new TextEncoder();
const dec = new TextDecoder();

class Bytes {
  buf = new Uint8Array(0);
  done = false;
  constructor(private reader: ReadableStreamDefaultReader<Uint8Array>) {}
  async more(): Promise<boolean> {
    if (this.done) return false;
    const { done, value } = await this.reader.read();
    if (done || !value) { this.done = true; return false; }
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
  async line(max = 8192): Promise<string | null> {
    for (;;) {
      const i = this.indexOf([13, 10]);
      if (i >= 0) { const l = dec.decode(this.take(i)); this.take(2); return l; }
      if (this.buf.length > max) throw new Error("line_too_long");
      if (!(await this.more())) return null;
    }
  }
  cancel() { try { this.reader.cancel().catch(() => {}); } catch { /* al dicht */ } }
}

const clean = (v: string) => v.replace(/[\r\n\0]/g, "");

/** Kop van het antwoord: "HTTP/1.1 200 OK" + kopregels. 1xx (100 Continue) wordt overgeslagen. */
async function readHead(b: Bytes): Promise<{ status: number; headers: Headers }> {
  for (let round = 0; round < 5; round++) {
    let end = -1;
    while ((end = b.indexOf([13, 10, 13, 10])) < 0) {
      if (b.buf.length > MAX_HEAD) throw new Error("head_too_large");
      if (!(await b.more())) throw new Error("no_response");
    }
    const head = dec.decode(b.take(end)); b.take(4);
    const lines = head.split("\r\n");
    const m = /^HTTP\/1\.[01] (\d{3})(?: .*)?$/.exec(lines[0] ?? "");
    if (!m) throw new Error("bad_status_line");
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
    if (status < 200 || status > 599) throw new Error("bad_status");
    return { status, headers };
  }
  throw new Error("too_many_informational");
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
          c.enqueue(part.slice());
          if (left === 0) {
            while (b.buf.length < 2) if (!(await b.more())) throw new Error("chunk_eof");
            b.take(2); // CRLF na het stuk
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
          c.enqueue(part.slice());
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
        c.enqueue(b.take(b.buf.length).slice());
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
    const tcp = await Promise.race([
      Deno.connect({ hostname, port, transport: "tcp" }),
      new Promise<never>((_, rej) => { timer = setTimeout(() => rej(new Error("connect_timeout")), timeout); }),
    ]).finally(() => clearTimeout(timer));
    conn = tcp;
    if (o.signal.aborted) throw new DOMException("aborted", "AbortError");
    if (url.protocol === "https:") {
      let t2: ReturnType<typeof setTimeout> | undefined;
      conn = await Promise.race([
        Deno.startTls(tcp, { hostname: url.hostname, alpnProtocols: ["http/1.1"], ...(o.caCerts ? { caCerts: o.caCerts } : {}) }),
        new Promise<never>((_, rej) => { t2 = setTimeout(() => rej(new Error("tls_timeout")), timeout); }),
      ]).finally(() => clearTimeout(t2));
    }
    const lines = [`GET ${url.pathname || "/"}${url.search} HTTP/1.1`, `Host: ${url.host}`];
    for (const [k, v] of Object.entries(o.headers)) {
      const lk = k.toLowerCase();
      if (lk === "host" || lk === "connection" || lk === "content-length" || lk === "transfer-encoding") continue;
      if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(k)) continue;
      lines.push(`${k}: ${clean(v)}`);
    }
    lines.push("Connection: close", "", "");
    const w = conn.writable.getWriter();
    await w.write(enc.encode(lines.join("\r\n")));
    w.releaseLock();
    const b = new Bytes(conn.readable.getReader());
    const { status, headers } = await readHead(b);
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
