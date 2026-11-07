// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { PREVIEW_STORAGE_KEY } from "@/lib/dashboard/preview";
import { DashboardApp } from "../dashboard-app";

class MemoryStorage implements Storage {
  private map = new Map<string, string>();
  get length() { return this.map.size; }
  clear() { this.map.clear(); }
  getItem(k: string) { return this.map.get(k) ?? null; }
  key(i: number) { return [...this.map.keys()][i] ?? null; }
  removeItem(k: string) { this.map.delete(k); }
  setItem(k: string, v: string) { this.map.set(k, String(v)); }
}

beforeAll(() => {
  // Node 26 ships an experimental global localStorage that shadows jsdom's; use in-memory storage.
  for (const name of ["localStorage", "sessionStorage"] as const) {
    const store = new MemoryStorage();
    Object.defineProperty(globalThis, name, { value: store, configurable: true });
    Object.defineProperty(window, name, { value: store, configurable: true });
  }
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} } as unknown as typeof ResizeObserver;
  window.matchMedia = ((q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {}, onchange: null, dispatchEvent: () => false })) as typeof window.matchMedia;
  Element.prototype.scrollIntoView = () => {};
  // Minimal DOMMatrix for React Flow's zoom pane in jsdom.
  (globalThis as unknown as { DOMMatrixReadOnly: unknown }).DOMMatrixReadOnly ??= class { m22 = 1; constructor() {} };
});

beforeEach(() => {
  window.location.hash = "#/";
  sessionStorage.clear();
  localStorage.clear();
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

async function go(hash: string) {
  window.location.hash = hash;
  window.dispatchEvent(new HashChangeEvent("hashchange"));
}

function api(routes: Record<string, (init: RequestInit) => { status?: number; body: unknown }>) {
  const calls: { method: string; path: string; body: unknown; auth?: string }[] = [];
  const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
    const path = new URL(url).pathname;
    const method = init.method ?? "GET";
    calls.push({ method, path, body: init.body ? JSON.parse(init.body as string) : undefined, auth: (init.headers as Record<string, string>).Authorization });
    const handler = routes[`${method} ${path}`];
    if (!handler) return new Response(JSON.stringify({ detail: "Not Found" }), { status: 404 });
    const r = handler(init);
    return new Response(JSON.stringify(r.body), { status: r.status ?? 200, headers: { "Content-Type": "application/json" } });
  });
  vi.stubGlobal("fetch", fetchMock);
  return calls;
}

const devLogin = () => ({ body: { access_token: "tok-1", user: { email: "dev@localhost" } } });
const SENT = "#/projects/prj-ledgerly/sessions/5e55a001-0000-4000-8000-00000000a001";

describe("local workspace (automatic loopback login)", () => {
  it("signs in automatically and opens the Local workspace project with its recordings", async () => {
    const calls = api({
      "POST /v1/auth/dev": devLogin,
      "GET /v1/projects": () => ({ body: { projects: [{ id: "p0", name: "Scratch" }, { id: "p1", name: "Local workspace" }] } }),
      "GET /v1/projects/p1/sessions": () => ({ body: { sessions: [{ id: "s1", project_id: "p1", app: { name: "Finder", bundle_id: "com.apple.finder" }, started_at: "2026-11-07T15:00:00Z", duration_ms: 42_000, status: "uploaded", network_status: "not_captured", task: "legacy text" }] } }),
    });
    render(<DashboardApp />);
    expect(await screen.findByRole("heading", { level: 1, name: "Local workspace" })).toBeTruthy();
    expect(await screen.findByText("Finder")).toBeTruthy();
    expect(screen.getByText("Not analyzed")).toBeTruthy();
    // No sign-in wall, room codes, pairing approval, or task wording.
    expect(screen.queryByRole("button", { name: /sign in|room code|approve/i })).toBeNull();
    expect(screen.queryByText(/legacy text|room code|demonstrat/i)).toBeNull();
    expect(screen.getByRole("link", { name: /Local workspace/, current: "page" })).toBeTruthy();

    expect(calls[0]).toMatchObject({ method: "POST", path: "/v1/auth/dev", auth: undefined });
    expect(calls.find((c) => c.path === "/v1/projects")?.auth).toBe("Bearer tok-1");
    // The token is never persisted.
    expect(sessionStorage.length).toBe(0);
    expect(localStorage.length).toBe(0);
  });

  it("shows an honest connection error when the API is stopped, with no silent sample fallback", async () => {
    let up = false;
    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      if (!up) throw new TypeError("Failed to fetch");
      const path = new URL(url).pathname;
      if (path === "/v1/auth/dev") return new Response(JSON.stringify(devLogin().body), { status: 200 });
      if (path === "/v1/projects") return new Response(JSON.stringify({ projects: [] }), { status: 200 });
      return new Response("{}", { status: 404 });
    }));
    render(<DashboardApp />);
    expect(await screen.findByRole("heading", { name: "Can’t connect to the local Retrace API" })).toBeTruthy();
    expect(screen.getByText(/Can't reach the Retrace API at http:\/\/127.0.0.1:8000/)).toBeTruthy();
    expect(screen.queryByText(/Sample data\./)).toBeNull();

    up = true;
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByRole("heading", { name: "Connect the recorder to get started" })).toBeTruthy();
  });

  it("reports API errors after login instead of falling back to sample data", async () => {
    api({ "POST /v1/auth/dev": devLogin, "GET /v1/projects": () => ({ status: 500, body: { detail: "database unavailable" } }) });
    render(<DashboardApp />);
    expect(await screen.findByText("Couldn’t load projects")).toBeTruthy();
    expect(screen.getByText("database unavailable")).toBeTruthy();
    expect(screen.queryByText(/Sample data\./)).toBeNull();
  });
});

describe("sample data (explicit, secondary)", () => {
  it("is only opened by choice, then walks recording → correction → export", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("Failed to fetch"); }));
    render(<DashboardApp />);
    fireEvent.click(await screen.findByRole("button", { name: "View sample data" }));
    expect(await screen.findByText("Sample data.")).toBeTruthy();
    expect(screen.getByText(/Nothing here was recorded or analyzed/)).toBeTruthy();

    expect(await screen.findAllByText("Ledgerly")).toHaveLength(3);
    expect(screen.getAllByText("Network observed").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Network not captured").length).toBeGreaterThan(0);
    expect(screen.getByText("No requests observed")).toBeTruthy();
    await go(SENT);

    expect(await screen.findByRole("heading", { level: 1, name: "Ledgerly" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Outline" }));
    fireEvent.click(await screen.findByRole("button", { name: "Rename Invoices" }));
    const input = screen.getByRole("textbox", { name: /Rename Screen/ });
    fireEvent.change(input, { target: { value: "Invoice list" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(screen.getAllByText("Edited").length).toBeGreaterThan(0);
    await waitFor(() => expect(localStorage.getItem(PREVIEW_STORAGE_KEY)).not.toBeNull());
    await waitFor(() => expect(screen.queryByRole("button", { name: "Saving…" })).toBeNull());
    const stored = JSON.parse(localStorage.getItem(PREVIEW_STORAGE_KEY)!);
    expect(stored.demo).toMatch(/sample data only/);
    expect(stored.corrections["5e55a001-0000-4000-8000-00000000a001"]["node-01"].label).toBe("Invoice list");

    fireEvent.click(screen.getByRole("button", { name: /Invoice list/, pressed: false }));
    const inspector = screen.getByRole("complementary", { name: "Inspector" });
    expect(within(inspector).getByText(/Supporting evidence/)).toBeTruthy();
    expect(within(inspector).getByText(/Agent label/).textContent).toContain("Invoices");
    expect(within(inspector).getByRole("button", { name: "Restore agent label" })).toBeTruthy();

    fireEvent.click(screen.getByRole("tab", { name: /API & network/ }));
    expect(await screen.findByText("GET /api/clients")).toBeTruthy();
    expect(screen.getAllByText(/Candidate/).length).toBeGreaterThan(0);

    const createObjectURL = vi.fn(() => "blob:x");
    URL.createObjectURL = createObjectURL;
    URL.revokeObjectURL = () => {};
    HTMLAnchorElement.prototype.click = () => {};
    fireEvent.click(screen.getByRole("button", { name: /Download graph JSON/ }));
    expect(await screen.findByText("Validated graph downloaded")).toBeTruthy();
    expect(createObjectURL).toHaveBeenCalledOnce();
  });

  it("distinguishes ‘no requests observed’ from ‘network not captured’", async () => {
    sessionStorage.setItem("retrace.dashboard-mode", "preview");
    render(<DashboardApp />);
    await go("#/projects/prj-ledgerly/sessions/5e55a002-0000-4000-8000-00000000a002");
    await screen.findByRole("heading", { level: 1, name: "Ledgerly" });
    fireEvent.click(screen.getByRole("tab", { name: /API & network/ }));
    expect(screen.getByText("No network activity observed")).toBeTruthy();
    cleanup();

    render(<DashboardApp />);
    await go("#/projects/prj-fieldnotes/sessions/5e55b001-0000-4000-8000-00000000b001");
    await screen.findByRole("heading", { level: 1, name: "Field Notes" });
    fireEvent.click(screen.getByRole("tab", { name: /API & network/ }));
    expect(screen.getByRole("heading", { name: "Network not captured" })).toBeTruthy();
  });

  it("loads the React Flow canvas on demand for an analyzed recording", async () => {
    sessionStorage.setItem("retrace.dashboard-mode", "preview");
    const { container } = render(<DashboardApp />);
    await go(SENT);
    await screen.findByRole("heading", { level: 1, name: "Ledgerly" });
    await waitFor(() => expect(container.querySelector(".react-flow")).toBeTruthy());
  });
});
