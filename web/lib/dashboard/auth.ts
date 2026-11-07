// Only the explicit "sample data" choice is remembered (per tab). Access tokens are never
// persisted: every page load signs in again through the loopback-only POST /v1/auth/dev.
const MODE_KEY = "retrace.dashboard-mode";
export function rememberPreviewChoice(on: boolean) {
  try {
    if (on) sessionStorage.setItem(MODE_KEY, "preview");
    else sessionStorage.removeItem(MODE_KEY);
  } catch {}
}
export function previewChosen(): boolean {
  try {
    return sessionStorage.getItem(MODE_KEY) === "preview";
  } catch {
    return false;
  }
}
