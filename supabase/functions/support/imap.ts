// Supporttickets per e-mail: een kleine, zelfstandige IMAP4rev1-client (RFC 3501) over TLS (poort 993), zonder npm-pakketten.
// Alleen wat de inbox-import nodig heeft: LOGIN, CAPABILITY, LIST, SELECT, UID SEARCH, UID FETCH (met literals {n}),
// UID STORE, UID MOVE (of UID COPY) en LOGOUT. Elke lees- en schrijfactie heeft een tijdslimiet; bij een fout of time-out
// gaat de verbinding dicht. Getest in inbox_test.ts tegen een nep-server (en lokaal tegen Dovecot).

export type ImapConn = {
  read(p: Uint8Array): Promise<number | null>;
  write(p: Uint8Array): Promise<number>;
  close(): void;
};
/** Eén waarde uit een IMAP-antwoord: atoom/tekst, NIL (null), lijst of literal (bytes). */
export type Tok = string | null | Tok[] | Uint8Array;
export type Untagged = { text: string; toks: Tok[] };
export type Done = { status: "OK" | "NO" | "BAD"; text: string; untagged: Untagged[] };
export type FetchItem = { seq: number; uid: number; size: number | null; flags: string[]; body: Uint8Array | null; partial: boolean };

export class ImapError extends Error {
  constructor(msg: string, public kind: "timeout" | "closed" | "protocol" | "no" | "bad" | "auth" | "toolarge" = "protocol") { super(msg); }
}

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8");

/** Een IMAP-string als argument: atoom-veilig, anders "…" met escapes; met CR/LF of 8-bit tekens als literal. */
export function imapArg(s: string): string | Uint8Array {
  if (/[\r\n\u0080-\uffff\u0000]/.test(s)) return enc.encode(s);
  return `"${s.replace(/(["\\])/g, "\\$1")}"`;
}

export class Imap {
  private buf = new Uint8Array(0);
  private tagN = 0;
  private closed = false;
  caps = new Set<string>();
  /** Max. grootte van één literal (bescherming tegen een enorme mail of een kwaadwillende server). */
  maxLiteral = 4 * 1024 * 1024;

  constructor(private conn: ImapConn, public timeoutMs = 20000) {}

  static async connect(o: { host: string; port?: number; tls?: boolean; caCerts?: string[]; timeoutMs?: number }): Promise<Imap> {
    const port = o.port ?? 993;
    const ms = o.timeoutMs ?? 20000;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const conn = await Promise.race([
      o.tls === false ? Deno.connect({ hostname: o.host, port }) : Deno.connectTls({ hostname: o.host, port, ...(o.caCerts ? { caCerts: o.caCerts } : {}) }),
      new Promise<never>((_, rej) => { timer = setTimeout(() => rej(new ImapError(`verbinden met ${o.host}:${port} duurde te lang`, "timeout")), ms); }),
    ]).finally(() => clearTimeout(timer));
    const c = new Imap(conn as unknown as ImapConn, ms);
    await c.greeting();
    return c;
  }

  private async timed<T>(p: Promise<T>, what: string): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([p, new Promise<never>((_, rej) => {
        timer = setTimeout(() => { this.close(); rej(new ImapError(`time-out (${what})`, "timeout")); }, this.timeoutMs);
      })]);
    } finally { clearTimeout(timer); }
  }

  private async fill(): Promise<void> {
    if (this.closed) throw new ImapError("verbinding gesloten", "closed");
    const chunk = new Uint8Array(64 * 1024);
    const n = await this.timed(this.conn.read(chunk), "lezen");
    if (n === null) { this.closed = true; throw new ImapError("server sloot de verbinding", "closed"); }
    const b = new Uint8Array(this.buf.length + n);
    b.set(this.buf); b.set(chunk.subarray(0, n), this.buf.length);
    this.buf = b;
  }
  private async readLine(): Promise<string> {
    for (;;) {
      const i = this.buf.indexOf(10);
      if (i >= 0) {
        const line = this.buf.subarray(0, i + 1);
        this.buf = this.buf.slice(i + 1);
        return dec.decode(line).replace(/\r?\n$/, "");
      }
      if (this.buf.length > 1024 * 1024) throw new ImapError("regel te lang", "protocol");
      await this.fill();
    }
  }
  private async readBytes(n: number): Promise<Uint8Array> {
    while (this.buf.length < n) await this.fill();
    const out = this.buf.slice(0, n);
    this.buf = this.buf.slice(n);
    return out;
  }
  /** Eén volledig antwoord (regel plus eventuele literals {n}), als tekst met de literals apart. */
  private async readResponse(): Promise<{ text: string; lits: Uint8Array[] }> {
    let text = "";
    const lits: Uint8Array[] = [];
    for (;;) {
      const line = await this.readLine();
      const m = /\{(\d+)\+?\}$/.exec(line);
      if (!m) return { text: text + line, lits };
      const n = Number(m[1]);
      if (n > this.maxLiteral) throw new ImapError(`literal van ${n} bytes is te groot`, "toolarge");
      lits.push(await this.readBytes(n));
      text += line.slice(0, m.index) + `\u0000${lits.length - 1}\u0000`;
    }
  }
  private async writeAll(b: Uint8Array) {
    let off = 0;
    while (off < b.length) off += await this.timed(this.conn.write(b.subarray(off)), "schrijven");
  }

  async greeting() {
    const r = await this.readResponse();
    if (/^\* BYE/i.test(r.text)) throw new ImapError(`server weigert: ${r.text.slice(0, 200)}`, "no");
    if (!/^\* (OK|PREAUTH)/i.test(r.text)) throw new ImapError(`onverwachte begroeting: ${r.text.slice(0, 200)}`);
    this.parseCaps(r.text);
  }
  private parseCaps(text: string) {
    const m = /\[CAPABILITY ([^\]]+)\]/i.exec(text) ?? /^\* CAPABILITY (.+)$/i.exec(text);
    if (m) this.caps = new Set(m[1].toUpperCase().split(/\s+/));
  }

  /** Commando versturen (argumenten: tekst of literal-bytes) en wachten op het getagde antwoord. */
  async command(parts: (string | Uint8Array)[], opts: { okOnly?: boolean } = {}): Promise<Done> {
    const tag = `B${++this.tagN}`;
    const untagged: Untagged[] = [];
    // literals: eerst "{n}" sturen en wachten op "+ " (synchronizing literal)
    const segs: (string | Uint8Array)[] = [];
    let cur = tag;
    for (const p of parts) {
      if (typeof p === "string") cur += " " + p;
      else { segs.push(cur + ` {${p.length}}\r\n`); segs.push(p); cur = ""; }
    }
    segs.push(cur + "\r\n");
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      await this.writeAll(typeof s === "string" ? enc.encode(s) : s);
      if (typeof s === "string" && s.endsWith("}\r\n") && i + 1 < segs.length && segs[i + 1] instanceof Uint8Array) {
        for (;;) {
          const r = await this.readResponse();
          if (r.text.startsWith("+")) break;
          if (r.text.startsWith(tag + " ")) throw new ImapError(`server weigerde: ${r.text.slice(tag.length + 1, 200)}`, "bad");
          untagged.push(this.untagged(r));
        }
      }
    }
    for (;;) {
      const r = await this.readResponse();
      if (r.text.startsWith(tag + " ")) {
        const m = /^(OK|NO|BAD)\b ?(.*)$/i.exec(r.text.slice(tag.length + 1));
        if (!m) throw new ImapError(`onverwacht antwoord: ${r.text.slice(0, 200)}`);
        const done: Done = { status: m[1].toUpperCase() as Done["status"], text: m[2], untagged };
        this.parseCaps(r.text);
        if (opts.okOnly !== false && done.status !== "OK") {
          throw new ImapError(`${parts[0]}: ${done.status} ${done.text.slice(0, 200)}`, done.status === "NO" ? "no" : "bad");
        }
        return done;
      }
      if (r.text.startsWith("+")) continue; // onverwachte voortzetting: negeren
      if (/^\* BYE/i.test(r.text) && !/^LOGOUT/i.test(String(parts[0]))) { this.closed = true; throw new ImapError(`server sloot de sessie: ${r.text.slice(0, 200)}`, "closed"); }
      const u = this.untagged(r);
      if (/^\* CAPABILITY /i.test(r.text)) this.parseCaps(r.text);
      untagged.push(u);
    }
  }
  private untagged(r: { text: string; lits: Uint8Array[] }): Untagged {
    return { text: r.text.replace(/\u0000(\d+)\u0000/g, "{literal}"), toks: tokenize(r.text.replace(/^\* /, ""), r.lits) };
  }

  async login(user: string, pass: string) {
    if (this.caps.has("LOGINDISABLED")) throw new ImapError("LOGIN is uitgeschakeld op deze server", "auth");
    try { await this.command(["LOGIN", imapArg(user), imapArg(pass)]); }
    catch (e) {
      if (e instanceof ImapError && (e.kind === "no" || e.kind === "bad")) throw new ImapError(`inloggen mislukt: ${e.message.replace(/^LOGIN: /, "")}`, "auth");
      throw e;
    }
    if (!this.caps.size || !this.caps.has("IMAP4REV1")) await this.command(["CAPABILITY"]);
  }

  async list(): Promise<{ name: string; delim: string | null; flags: string[] }[]> {
    const r = await this.command(["LIST", '""', '"*"']);
    return r.untagged.filter((u) => String(u.toks[0]).toUpperCase() === "LIST").map((u) => {
      const [, flags, delim, name] = u.toks;
      const n = name instanceof Uint8Array ? dec.decode(name) : String(name ?? "");
      return { name: n, delim: typeof delim === "string" ? delim : null, flags: Array.isArray(flags) ? flags.map(String) : [] };
    });
  }

  async select(box = "INBOX", readOnly = false): Promise<{ exists: number; uidvalidity: number | null; uidnext: number | null }> {
    const r = await this.command([readOnly ? "EXAMINE" : "SELECT", imapArg(box)]);
    let exists = 0, uidvalidity: number | null = null, uidnext: number | null = null;
    for (const u of r.untagged) {
      const m = /^\* (\d+) EXISTS/i.exec(u.text); if (m) exists = Number(m[1]);
      const v = /\[UIDVALIDITY (\d+)\]/i.exec(u.text); if (v) uidvalidity = Number(v[1]);
      const n = /\[UIDNEXT (\d+)\]/i.exec(u.text); if (n) uidnext = Number(n[1]);
    }
    return { exists, uidvalidity, uidnext };
  }

  async uidSearch(criteria: string): Promise<number[]> {
    const r = await this.command(["UID SEARCH", criteria]);
    const out: number[] = [];
    for (const u of r.untagged) {
      const m = /^\* SEARCH\b(.*)$/i.exec(u.text);
      if (m) for (const x of m[1].trim().split(/\s+/)) if (/^\d+$/.test(x)) out.push(Number(x));
    }
    return [...new Set(out)].sort((a, b) => a - b);
  }

  /** UID FETCH; items bv. "(UID FLAGS RFC822.SIZE BODY.PEEK[]<0.2097152>)". */
  async uidFetch(uids: number[] | string, items: string): Promise<FetchItem[]> {
    const set = typeof uids === "string" ? uids : uids.join(",");
    if (!set) return [];
    const r = await this.command(["UID FETCH", set, items]);
    const out: FetchItem[] = [];
    for (const u of r.untagged) {
      if (!(typeof u.toks[1] === "string" && String(u.toks[1]).toUpperCase() === "FETCH") || !Array.isArray(u.toks[2])) continue;
      const seq = Number(u.toks[0]);
      const kv = u.toks[2];
      const it: FetchItem = { seq, uid: 0, size: null, flags: [], body: null, partial: false };
      for (let i = 0; i < kv.length; i++) {
        const k = typeof kv[i] === "string" ? (kv[i] as string).toUpperCase() : "";
        const v = kv[i + 1];
        if (k === "UID") { it.uid = Number(v); i++; }
        else if (k === "RFC822.SIZE") { it.size = Number(v); i++; }
        else if (k === "FLAGS") { it.flags = Array.isArray(v) ? v.map(String) : []; i++; }
        else if (/^(BODY|BINARY|RFC822)(\[[^\]]*\])?(<\d+>)?$/.test(k) || k === "RFC822") {
          it.body = v instanceof Uint8Array ? v : typeof v === "string" ? enc.encode(v) : null;
          it.partial = /<\d+>$/.test(k);
          i++;
        }
      }
      if (it.uid) out.push(it);
    }
    return out;
  }

  async uidStore(uids: number[], op: string) {
    if (uids.length) await this.command(["UID STORE", uids.join(","), op]);
  }
  /** Verplaatsen: met MOVE als de server dat kan, anders COPY (het origineel blijft staan, alleen gemarkeerd). */
  async uidMove(uids: number[], box: string): Promise<"moved" | "copied"> {
    if (!uids.length) return "moved";
    if (this.caps.has("MOVE")) { await this.command(["UID MOVE", uids.join(","), imapArg(box)]); return "moved"; }
    await this.command(["UID COPY", uids.join(","), imapArg(box)]);
    return "copied";
  }
  async logout() {
    if (this.closed) return;
    try { await this.command(["LOGOUT"], { okOnly: false }); } catch { /* maakt niet uit */ }
    this.close();
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    try { this.conn.close(); } catch { /* al dicht */ }
  }
}

/** IMAP-antwoorddata naar tokens: atomen, "strings", NIL, (lijsten), literals (via \0n\0-plaatshouders) en [secties]. */
export function tokenize(text: string, lits: Uint8Array[] = []): Tok[] {
  let i = 0;
  const parseList = (close: string | null): Tok[] => {
    const out: Tok[] = [];
    while (i < text.length) {
      const c = text[i];
      if (c === " " || c === "\t") { i++; continue; }
      if (close && c === close) { i++; return out; }
      if (c === "(") { i++; out.push(parseList(")")); continue; }
      if (c === ")") { i++; continue; } // onverwacht: overslaan
      if (c === '"') {
        let s = ""; i++;
        while (i < text.length && text[i] !== '"') { if (text[i] === "\\" && i + 1 < text.length) i++; s += text[i++]; }
        i++; out.push(s); continue;
      }
      if (c === "\u0000") {
        const j = text.indexOf("\u0000", i + 1);
        out.push(lits[Number(text.slice(i + 1, j))] ?? new Uint8Array());
        i = j + 1; continue;
      }
      // atoom, eventueel met [sectie] en <partial> (BODY[HEADER.FIELDS (FROM)]<0>)
      let s = "";
      while (i < text.length && !/[ ()\u0000"]/.test(text[i]) || (s.includes("[") && !s.includes("]") && i < text.length)) {
        s += text[i++];
      }
      if (!s) { i++; continue; }
      out.push(s.toUpperCase() === "NIL" ? null : s);
    }
    return out;
  };
  return parseList(null);
}
