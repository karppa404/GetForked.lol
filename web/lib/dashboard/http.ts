import { POLL } from "./config";

export type ApiErrorKind = "network" | "timeout" | "aborted" | "http" | "parse";

export class ApiError extends Error {
  readonly kind: ApiErrorKind;
  readonly status: number | null;

  constructor(kind: ApiErrorKind, message: string, status: number | null = null) {
    super(message);
    this.name = "ApiError";
    this.kind = kind;
    this.status = status;
  }

  get isUnauthorized() {
    return this.status === 401;
  }
}

export function isAbort(error: unknown): boolean {
  return error instanceof ApiError ? error.kind === "aborted" : error instanceof DOMException && error.name === "AbortError";
}

export interface ApiClientOptions {
  baseUrl: string;
  getToken?: () => string | null;
  onUnauthorized?: () => void;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export interface RequestOptions {
  body?: unknown;
  signal?: AbortSignal;
  /** Send without the bearer token (sign-in endpoints). */
  anonymous?: boolean;
  /** Return the raw Response for non-JSON bodies. */
  raw?: boolean;
}

function messageFromBody(body: unknown, status: number): string {
  if (body && typeof body === "object") {
    const b = body as Record<string, unknown>;
    if (typeof b.detail === "string") return b.detail;
    if (typeof b.message === "string") return b.message;
    if (b.error && typeof b.error === "object" && typeof (b.error as Record<string, unknown>).message === "string") {
      return (b.error as { message: string }).message;
    }
    if (typeof b.error === "string") return b.error;
  }
  return `Request failed (${status})`;
}

/**
 * Small fetch wrapper: bearer auth, JSON, a hard timeout, and caller cancellation.
 * No automatic retries — callers decide (polling loops are bounded separately).
 */
export function createApiClient(options: ApiClientOptions) {
  const baseUrl = options.baseUrl.replace(/\/+$/, "");
  const timeoutMs = options.timeoutMs ?? POLL.requestTimeoutMs;
  const doFetch = options.fetchImpl ?? ((...args: Parameters<typeof fetch>) => fetch(...args));

  async function request<T>(method: string, path: string, opts: RequestOptions = {}): Promise<T> {
    if (opts.signal?.aborted) throw new ApiError("aborted", "Request cancelled");
    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, timeoutMs);
    const onCallerAbort = () => controller.abort();
    opts.signal?.addEventListener("abort", onCallerAbort, { once: true });

    const headers: Record<string, string> = { Accept: "application/json" };
    if (opts.body !== undefined) headers["Content-Type"] = "application/json";
    const token = opts.anonymous ? null : options.getToken?.();
    if (token) headers.Authorization = `Bearer ${token}`;

    let response: Response;
    try {
      response = await doFetch(`${baseUrl}${path}`, {
        method,
        headers,
        body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
        signal: controller.signal,
        credentials: "omit",
        cache: "no-store",
      });
    } catch (error) {
      if (timedOut) throw new ApiError("timeout", `The API did not respond within ${Math.round(timeoutMs / 1000)}s`);
      if (opts.signal?.aborted) throw new ApiError("aborted", "Request cancelled");
      throw new ApiError("network", `Can't reach the Retrace API at ${baseUrl}`);
    } finally {
      clearTimeout(timer);
      opts.signal?.removeEventListener("abort", onCallerAbort);
    }

    if (opts.raw && response.ok) return response as unknown as T;

    const text = await response.text().catch(() => "");
    let body: unknown = null;
    if (text) {
      try {
        body = JSON.parse(text);
      } catch {
        if (response.ok) throw new ApiError("parse", "The API returned a response that isn't JSON", response.status);
      }
    }
    if (!response.ok) {
      if (response.status === 401 && !opts.anonymous) options.onUnauthorized?.();
      throw new ApiError("http", messageFromBody(body, response.status), response.status);
    }
    return body as T;
  }

  return {
    baseUrl,
    get: <T>(path: string, opts?: RequestOptions) => request<T>("GET", path, opts),
    post: <T>(path: string, body?: unknown, opts?: RequestOptions) => request<T>("POST", path, { ...opts, body: body ?? {} }),
    put: <T>(path: string, body?: unknown, opts?: RequestOptions) => request<T>("PUT", path, { ...opts, body: body ?? {} }),
    request,
  };
}

export type ApiClient = ReturnType<typeof createApiClient>;

export function describeError(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 403) return "You don't have access to this.";
    if (error.status === 404) return "Not found. It may have been removed, or the API doesn't support this yet.";
    return error.message;
  }
  if (error instanceof Error) return error.message;
  return "Something went wrong.";
}
