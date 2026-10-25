// Spoedfix 25-10-2026: doorstromen van een antwoord zonder te bufferen, met een grens. Getest in stream_test.ts.
// Elk stuk gaat meteen door (een lijst van tientallen MB komt nooit in zijn geheel in het geheugen van de functie);
// boven `max` bytes: `onOver()` (de proxy breekt dan de aanvraag naar de server af) en de stroom eindigt met een fout,
// zodat de browser een afgebroken antwoord ziet in plaats van een half bestand als "klaar".
export function capStream(max: number, onBytes: (n: number) => void, onOver: () => void, onDone: () => void): TransformStream<Uint8Array, Uint8Array> {
  let seen = 0;
  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, c) {
      seen += chunk.byteLength;
      onBytes(chunk.byteLength);
      if (seen > max) { onOver(); onDone(); c.error(new Error("too_large")); return; }
      c.enqueue(chunk);
    },
    flush() { onDone(); },
  });
}
