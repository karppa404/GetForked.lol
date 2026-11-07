import type { AuthSession } from "./types";

// Access tokens are kept in memory and mirrored to sessionStorage (cleared when the tab closes).
// Never localStorage, never cookies set by this app, never baked into the build.
const KEY_PREFIX = "retrace.auth.v1:";
let memory: { key: string; session: AuthSession } | null = null;

const keyFor = (apiBaseUrl: string) => `${KEY_PREFIX}${apiBaseUrl}`;

export function loadAuth(apiBaseUrl: string): AuthSession | null {
  const key = keyFor(apiBaseUrl);
  if (memory?.key === key) return memory.session;
  try {
    const raw = sessionStorage.getItem(key);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as AuthSession;
    if (typeof parsed?.access_token !== "string" || !parsed.access_token) return null;
    memory = { key, session: { access_token: parsed.access_token, user: parsed.user ?? {} } };
    return memory.session;
  } catch {
    return null;
  }
}

export function saveAuth(apiBaseUrl: string, session: AuthSession) {
  const key = keyFor(apiBaseUrl);
  memory = { key, session };
  try {
    sessionStorage.setItem(key, JSON.stringify(session));
  } catch {
    // In-memory only (private mode / blocked storage).
  }
}

export function clearAuth(apiBaseUrl: string) {
  memory = null;
  try {
    sessionStorage.removeItem(keyFor(apiBaseUrl));
  } catch {}
}

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
