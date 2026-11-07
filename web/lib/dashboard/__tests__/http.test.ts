import { describe, expect, it, vi } from "vitest";
import { createBackendWorkspace, normalizeSessionDetail } from "../backend";
import { resolveEnvironment } from "../config";
import { ApiError, createApiClient } from "../http";
import { parseRoute } from "../hooks";
import { validBoardUrl } from "@/components/dashboard/session-parts";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

describe("api client", () => {
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
    await expect(client.post("/v1/auth/google", { credential: "c" }, { anonymous: true })).rejects.toBeInstanceOf(ApiError);
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

  it("encodes path ids and posts pairing approvals with the claim id", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({}));
    const ws = createBackendWorkspace(createApiClient({ baseUrl: "http://x", fetchImpl }));
    await ws.approveClaim("p/1", "claim-9");
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("http://x/v1/pairings/p%2F1/approve");
    expect(JSON.parse(init.body as string)).toEqual({ claim_id: "claim-9" });
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
      task: "Do it",
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
  it("defaults to the loopback API only on localhost and gates dev auth to loopback", () => {
    expect(resolveEnvironment("localhost", {})).toMatchObject({ apiBaseUrl: "http://127.0.0.1:8000", devAuthAvailable: true, canSignIn: true });
    expect(resolveEnvironment("retrace.vercel.app", {})).toMatchObject({ apiBaseUrl: null, canSignIn: false, devAuthAvailable: false });
    expect(resolveEnvironment("retrace.vercel.app", { apiBaseUrl: "https://api.example.com" })).toMatchObject({ canSignIn: false, devAuthAvailable: false });
    expect(resolveEnvironment("retrace.vercel.app", { apiBaseUrl: "https://api.example.com", googleClientId: "id" })).toMatchObject({ canSignIn: true });
    expect(resolveEnvironment("localhost", { apiBaseUrl: "https://api.example.com" }).devAuthAvailable).toBe(false);
  });
});
