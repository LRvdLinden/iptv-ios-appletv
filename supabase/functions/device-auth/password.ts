// H1: uitkomst van de wachtwoordcontrole bij delete_account (zonder externe imports, zodat hij los te testen is).
// GoTrue geeft bij een fout wachtwoord 400 {code:"invalid_credentials"}; bij te veel pogingen 429; 5xx of geen
// antwoord = de auth-server is tijdelijk niet bereikbaar (dan niets verwijderen en ook niet "fout wachtwoord" zeggen).
export type PasswordCheck = "ok" | "wrong" | "rate_limited" | "unavailable";

export function passwordCheckResult(error: { status?: number; code?: string } | null | undefined): PasswordCheck {
  if (!error) return "wrong"; // geen sessie en geen fout: nooit als goed rekenen
  const status = typeof error.status === "number" ? error.status : 0;
  if (status === 429 || error.code === "over_request_rate_limit") return "rate_limited";
  if (status >= 400 && status < 500) return "wrong"; // invalid_credentials, email_not_confirmed, ongeldige sleutel e.d.
  return "unavailable";
}
