// Public, non-secret configuration only. NEXT_PUBLIC_* values are inlined at build time, so
// nothing here may ever be a credential. Access tokens live in memory/sessionStorage (see auth.ts).

export const DEFAULT_DEV_API_BASE_URL = "http://127.0.0.1:8000";

export interface DashboardEnvironment {
  /** API base URL, or null when this deployment has no backend configured. */
  apiBaseUrl: string | null;
  googleClientId: string | null;
  /** POST /v1/auth/dev is offered only when both the page and the API are on loopback. */
  devAuthAvailable: boolean;
  /** True when at least one real sign-in method can be offered. */
  canSignIn: boolean;
}

export function isLoopbackHost(hostname: string): boolean {
  const h = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  return h === "localhost" || h.endsWith(".localhost") || h === "::1" || /^127(\.\d{1,3}){3}$/.test(h);
}

function hostOf(url: string): string | null {
  try {
    return new URL(url).hostname;
  } catch {
    return null;
  }
}

export function resolveEnvironment(
  pageHostname: string,
  env: { apiBaseUrl?: string; googleClientId?: string } = {
    apiBaseUrl: process.env.NEXT_PUBLIC_API_BASE_URL,
    googleClientId: process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID,
  },
): DashboardEnvironment {
  const pageIsLoopback = isLoopbackHost(pageHostname);
  const configured = env.apiBaseUrl?.trim();
  const apiBaseUrl = (configured || (pageIsLoopback ? DEFAULT_DEV_API_BASE_URL : "")).replace(/\/+$/, "") || null;
  const apiHost = apiBaseUrl ? hostOf(apiBaseUrl) : null;
  const googleClientId = env.googleClientId?.trim() || null;
  const devAuthAvailable = Boolean(apiBaseUrl && pageIsLoopback && apiHost && isLoopbackHost(apiHost));
  return {
    apiBaseUrl,
    googleClientId,
    devAuthAvailable,
    canSignIn: Boolean(apiBaseUrl && (googleClientId || devAuthAvailable)),
  };
}

/** Bounded polling budgets, documented in web/README.md. */
export const POLL = {
  jobIntervalMs: 2500,
  jobMaxAttempts: 144, // ~6 minutes of visible-page polling per analysis view
  reviewIntervalMs: 5000,
  reviewMaxAttempts: 144, // ~12 minutes per completed-session view; user can explicitly resume
  pairingIntervalMs: 3000,
  requestTimeoutMs: 15000,
} as const;
