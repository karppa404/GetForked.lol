import { describe, expect, it, vi } from "vitest";
import { createBackendWorkspace, normalizeSessionDetail, signInForDevelopment } from "../backend";
import { resolveEnvironment } from "../config";
import { ApiError, createApiClient } from "../http";
import { parseRoute } from "../hooks";
import { validBoardUrl } from "@/components/dashboard/session-parts";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

describe("api client", () => {
  it("uses the backend's rerun, correction-delete, and corrected graph export contracts", async () => {
    const fetchImpl = vi.fn(async (_url: Parameters<typeof fetch>[0], init?: RequestInit) => init?.method === "DELETE" ? new Response(null, { status: 204 }) : jsonResponse({ job_id: "j", status: "queued" }));
    const ws = createBackendWorkspace(createApiClient({ baseUrl: "https://api.example.com", fetchImpl }));
    await ws.analyze("s");
    await ws.analyze("s", undefined, true);
    await ws.clearCorrection("s", "screen:e", "old");
    await ws.getGraphExport("s");
    expect(JSON.parse(fetchImpl.mock.calls[0][1]!.body as string)).toEqual({ rerun: false });
    expect(JSON.parse(fetchImpl.mock.calls[1][1]!.body as string)).toEqual({ rerun: true });
    expect(fetchImpl.mock.calls[2][1]?.method).toBe("DELETE");
    expect(fetchImpl.mock.calls[3][0]).toBe("https://api.example.com/v1/sessions/s/graph?download=1");
  });
  it("keeps the timeout active while reading response bodies", async () => {
    const client = createApiClient({
      baseUrl: "https://api.example.com", timeoutMs: 20,
      fetchImpl: async (_url, init) => ({
        ok: true,
        text: () => new Promise<string>((_resolve, reject) => init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))),
      }) as Response,
    });
    await expect(client.get("/slow-body")).rejects.toMatchObject({ kind: "timeout" });
  });

  it("does not send bearer credentials to an external screenshot URL", async () => {
    const fetchImpl = vi.fn();
    const workspace = createBackendWorkspace(createApiClient({ baseUrl: "https://api.example.com", getToken: () => "private-token", fetchImpl }));
    await expect(workspace.frameImage!("s", "https://api.example.com.evil.test/image.png")).resolves.toBe("https://api.example.com.evil.test/image.png");
    expect(fetchImpl).not.toHaveBeenCalled();
    await expect(workspace.frameImage!("s", "http://other.example.com/image.png")).rejects.toMatchObject({ kind: "parse" });
  });
  it("sends bearer auth and JSON, and never credentials cookies", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse([{ id: "p1", name: "One" }]));
    const client = createApiClient({ baseUrl: "http://127.0.0.1:8000/", getToken: () => "tok", fetchImpl });
    const projects = await createBackendWorkspace(client).listProjects();
    expect(projects).toEqual([{ id: "p1", name: "One", created_at: undefined, session_count: undefined }]);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("http://127.0.0.1:8000/v1/projects");
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer tok");
    expect(init.credentials).toBe("omit");
  });

  it("surfaces HTTP errors with the API's detail and calls onUnauthorized on 401", async () => {
    const onUnauthorized = vi.fn();
    const client = createApiClient({ baseUrl: "http://x", getToken: () => "t", onUnauthorized, fetchImpl: async () => jsonResponse({ detail: "Token expired" }, 401) });
    await expect(client.get("/v1/projects")).rejects.toMatchObject({ kind: "http", status: 401, message: "Token expired" });
    expect(onUnauthorized).toHaveBeenCalledOnce();
  });

  it("does not attach tokens or trigger sign-out for anonymous sign-in calls", async () => {
    const onUnauthorized = vi.fn();
    const fetchImpl = vi.fn(async () => jsonResponse({ detail: "bad credential" }, 401));
    const client = createApiClient({ baseUrl: "http://x", getToken: () => "t", onUnauthorized, fetchImpl });
    await expect(client.post("/v1/auth/dev", {}, { anonymous: true })).rejects.toBeInstanceOf(ApiError);
    const init = (fetchImpl.mock.calls[0] as unknown as [string, RequestInit])[1];
    expect((init.headers as Record<string, string>).Authorization).toBeUndefined();
    expect(onUnauthorized).not.toHaveBeenCalled();
  });

  it("times out hung requests and distinguishes caller cancellation", async () => {
    const hang = (_: unknown, init?: RequestInit) =>
      new Promise<Response>((_, reject) => init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError"))));
    const client = createApiClient({ baseUrl: "http://x", timeoutMs: 20, fetchImpl: hang as typeof fetch });
    await expect(client.get("/slow")).rejects.toMatchObject({ kind: "timeout" });

    const slowClient = createApiClient({ baseUrl: "http://x", timeoutMs: 5_000, fetchImpl: hang as typeof fetch });
    const controller = new AbortController();
    const p = slowClient.get("/slow", { signal: controller.signal });
    controller.abort();
    await expect(p).rejects.toMatchObject({ kind: "aborted" });
  });

  it("reports unreachable APIs as network errors", async () => {
    const client = createApiClient({ baseUrl: "http://127.0.0.1:8000", fetchImpl: async () => { throw new TypeError("Failed to fetch"); } });
    await expect(client.get("/v1/projects")).rejects.toMatchObject({ kind: "network" });
  });

  it("reports board URL saving as unsupported when the endpoint does not exist", async () => {
    const client = createApiClient({ baseUrl: "http://x", fetchImpl: async () => jsonResponse({ detail: "Not Found" }, 404) });
    await expect(createBackendWorkspace(client).saveBoardUrl("s1", "https://www.figma.com/board/abc")).resolves.toEqual({ status: "unsupported" });
  });

  it("encodes path ids in request paths", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ element_id: "n/1", label: "x" }));
    const ws = createBackendWorkspace(createApiClient({ baseUrl: "http://x", fetchImpl }));
    await ws.correctLabel("s/1", "n/1", "x");
    const [url] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("http://x/v1/sessions/s%2F1/corrections/n%2F1");
  });
  it("signs in locally through POST /v1/auth/dev without a bearer token", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ access_token: "t", user: { email: "dev@localhost" } }));
    const auth = await signInForDevelopment(createApiClient({ baseUrl: "http://127.0.0.1:8000", fetchImpl, getToken: () => "stale" }));
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("http://127.0.0.1:8000/v1/auth/dev");
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>).Authorization).toBeUndefined();
    expect(auth.access_token).toBe("t");
  });
});

describe("session normalization", () => {
  it("honors the recorder's nested capture status and settled frame reference", () => {
    const detail = normalizeSessionDetail({ manifest: { network_status: "none_observed", interactions: [{ id: "e", timestamp_ms: 1, kind: "click", delayed_frame_id: "f" }] } });
    expect(detail.network_status).toBe("none_observed");
    expect(detail.interactions[0].delayed_frame_id).toBe("f");
  });
  it("fills safe defaults and reads nested analysis", () => {
    const d = normalizeSessionDetail({
      id: "s",
      project_id: "p",
      app: { name: "App" },
      started_at: "2026-11-01T00:00:00Z",
      duration_ms: 1000,
      status: "analyzed",
      analysis: { job: { job_id: "j", status: "running", stages: [{ name: "workflow", status: "done" }] }, graph: { nodes: [], edges: [], network_status: "none_observed" } },
      corrections: { "node-1": "Renamed" },
    });
    expect(d.interactions).toEqual([]);
    expect(d.job?.id).toBe("j");
    expect(d.network_status).toBe("none_observed");
    expect(d.corrections).toEqual([{ element_id: "node-1", label: "Renamed" }]);
    expect(d.board_url).toBeNull();
  });
});

describe("environment", () => {
  it("only opens HTTPS Figma links without embedded credentials", () => {
    expect(validBoardUrl("https://www.figma.com/board/abc")).toBe("https://www.figma.com/board/abc");
    for (const bad of ["not-a-url", "javascript:alert(1)", "http://figma.com/board/a", "https://figma.com.evil.test/board/a", "https://secret@figma.com/board/a"]) {
      expect(validBoardUrl(bad)).toBeNull();
    }
  });
  it("handles malformed route escapes without crashing the dashboard", () => {
    expect(parseRoute("#/projects/%E0%A4%A")).toEqual({ name: "projects" });
    expect(parseRoute("#/projects/demo%20app")).toEqual({ name: "project", projectId: "demo app" });
  });
  it("is localhost-only: page and API must both be loopback", () => {
    expect(resolveEnvironment("localhost", undefined)).toEqual({ apiBaseUrl: "http://127.0.0.1:8000", problem: null });
    expect(resolveEnvironment("127.0.0.1", "http://localhost:9000/")).toEqual({ apiBaseUrl: "http://localhost:9000", problem: null });
    expect(resolveEnvironment("retrace.example.com", undefined)).toEqual({ apiBaseUrl: null, problem: "page_not_local" });
    expect(resolveEnvironment("localhost", "https://api.example.com")).toEqual({ apiBaseUrl: null, problem: "api_not_local" });
  });
});
