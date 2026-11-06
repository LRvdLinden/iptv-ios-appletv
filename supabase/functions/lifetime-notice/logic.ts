// Build 167, functie lifetime: kleine pure hulpjes (getest in lifetime_test.ts). Geheim vergelijken, taal, e-mailvorm en
// SMTP-fouten komen uit newsletter/logic.ts (geen afhankelijkheden), zodat alle mails dezelfde regels volgen.
export { langOf, sameSecret, smtpTemporary, validEmail as isEmail } from "../newsletter/logic.ts";

const DAY = 86_400_000;
/** De herinnering mag in de 7 dagen vóór cutover_at (en niet meer erna). */
export function remindWindow(cutoverAt: string, now: number): boolean {
  const cut = Date.parse(cutoverAt);
  return Number.isFinite(cut) && now >= cut - 7 * DAY && now < cut;
}
/** Grootte van één batch: geheel getal 1–200, anders de standaard. */
export const batchSize = (v: unknown, d: number) => (Number.isInteger(v) && (v as number) >= 1 && (v as number) <= 200 ? v as number : d);
