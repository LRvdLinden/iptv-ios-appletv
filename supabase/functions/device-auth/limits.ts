// Build 171 (#31): de lijsten in 403 device_limit en stream_limit verrijken (docs/ACCOUNT.md "Build 171"). Pure logica, getest
// in limits_test.ts. Alleen velden erbij, nooit eruit of hernoemd: oudere apps lezen de lijsten zoals voorheen.

export type DeviceRow = {
  device_id: string; name?: string | null; platform?: string | null; created_at?: string | null; last_seen_at?: string | null;
  signed_in_at?: string | null; current?: boolean;
};
export type StreamRow = {
  device_id: string; profile_id?: string | null; profile_name?: string | null; title?: string | null; kind?: string | null;
  started_at?: string | null; last_ping?: string | null; device_name?: string | null; platform?: string | null; signed_in_at?: string | null;
};

/** Apparaten met last_seen (= last_seen_at) en de lopende stream (profiel, titel, soort) als die er is. Volgorde blijft. */
export function limitDevices(devices: DeviceRow[], streams: StreamRow[]) {
  const by = new Map(streams.map((s) => [s.device_id, s]));
  return devices.map((d) => {
    const s = by.get(d.device_id);
    return {
      ...d,
      last_seen: d.last_seen_at ?? d.signed_in_at ?? d.created_at ?? null,
      current: d.current === true,
      watching: !!s,
      profile_id: s?.profile_id ?? null,
      profile_name: s?.profile_name ?? null,
      title: s?.title ?? null,
      kind: s?.kind ?? null,
    };
  });
}

/** Het apparaat dat het langst niet gebruikt is (niet dit apparaat en niet aan het kijken): voorstel om af te melden. */
export function suggestRemove(devices: ReturnType<typeof limitDevices>): { device_id: string; last_seen: string | null } | null {
  const t = (v: string | null) => { const n = Date.parse(v ?? ""); return Number.isFinite(n) ? n : 0; };
  const pick = devices.filter((d) => !d.current && !d.watching).sort((a, b) => t(a.last_seen) - t(b.last_seen))[0];
  return pick ? { device_id: pick.device_id, last_seen: pick.last_seen } : null;
}

/** Streams met last_seen (laatste ping, anders het apparaat) en current (de stream van dit apparaat). Volgorde blijft. */
export function limitStreams(streams: StreamRow[], devices: { device_id: string; last_seen_at?: string | null }[], current?: string) {
  const seen = new Map(devices.map((d) => [d.device_id, d.last_seen_at ?? null]));
  return streams.map((s) => ({
    ...s,
    last_seen: s.last_ping ?? seen.get(s.device_id) ?? null,
    device_last_seen: seen.get(s.device_id) ?? null,
    current: !!current && s.device_id === current,
  }));
}
