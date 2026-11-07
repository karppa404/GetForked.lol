// Public, non-secret configuration only. NEXT_PUBLIC_* values are inlined at build time, so
// nothing here may ever be a credential. Access tokens live only in memory (see dashboard-app.tsx).

export const DEFAULT_DEV_API_BASE_URL = "http://127.0.0.1:8000";

export interface DashboardEnvironment {
  /** Loopback API base URL, or null when Retrace can't run here (it is localhost-only). */
  apiBaseUrl: string | null;
  /** Why apiBaseUrl is null. */
  problem: "page_not_local" | "api_not_local" | null;
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

/** Retrace is localhost-only: both this page and the API must be on loopback. */
export function resolveEnvironment(pageHostname: string, configured: string | undefined = process.env.NEXT_PUBLIC_API_BASE_URL): DashboardEnvironment {
  if (!isLoopbackHost(pageHostname)) return { apiBaseUrl: null, problem: "page_not_local" };
  const apiBaseUrl = (configured?.trim() || DEFAULT_DEV_API_BASE_URL).replace(/\/+$/, "");
  const apiHost = hostOf(apiBaseUrl);
  if (!apiHost || !isLoopbackHost(apiHost)) return { apiBaseUrl: null, problem: "api_not_local" };
  return { apiBaseUrl, problem: null };
}

/** Bounded polling budgets, documented in web/README.md. */
export const POLL = {
  jobIntervalMs: 2500,
  jobMaxAttempts: 144, // ~6 minutes of visible-page polling per analysis view
  reviewIntervalMs: 5000,
  reviewMaxAttempts: 144, // ~12 minutes per completed-session view; user can explicitly resume
  requestTimeoutMs: 15000,
} as const;
