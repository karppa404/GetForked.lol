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

describe("preview workspace (localhost, user chooses preview)", () => {
  it("walks projects → session → correction → export with demo-labeled storage", async () => {
    render(<DashboardApp />);
    fireEvent.click(await screen.findByRole("button", { name: "Explore the preview workspace" }));
    expect(await screen.findByText("Preview workspace.")).toBeTruthy();
    expect(screen.getByText(/nothing here was recorded or analyzed/)).toBeTruthy();

    const project = await screen.findByRole("link", { name: /Ledgerly invoicing/ });
    await go(project.getAttribute("href")!);
    const session = await screen.findByRole("link", { name: /Create and send an invoice/ });
    expect(screen.getAllByText("Network observed").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Network not captured").length).toBeGreaterThan(0);
    expect(screen.getByText("No requests observed")).toBeTruthy();
    await go(session.getAttribute("href")!);

    expect(await screen.findByRole("heading", { level: 1, name: "Create and send an invoice" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Outline" }));
    fireEvent.click(screen.getByRole("button", { name: "Rename Invoices" }));
    const input = screen.getByRole("textbox", { name: /Rename Screen/ });
    fireEvent.change(input, { target: { value: "Invoice list" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    // Optimistic "Edited" marker first, then the saved correction lands in demo storage.
    expect(screen.getAllByText("Edited").length).toBeGreaterThan(0);
    await waitFor(() => expect(localStorage.getItem(PREVIEW_STORAGE_KEY)).not.toBeNull());
    await waitFor(() => expect(screen.queryByRole("button", { name: "Saving…" })).toBeNull());
    const stored = JSON.parse(localStorage.getItem(PREVIEW_STORAGE_KEY)!);
    expect(stored.demo).toMatch(/sample data only/);
    expect(stored.corrections["5e55a001-0000-4000-8000-00000000a001"]["node-01"].label).toBe("Invoice list");

    // Selecting a node shows supporting evidence; the agent label stays visible.
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
    await screen.findByRole("heading", { level: 1, name: "Refund a partial payment" });
    fireEvent.click(screen.getByRole("tab", { name: /API & network/ }));
    expect(screen.getByText("No network activity observed")).toBeTruthy();
    cleanup();

    render(<DashboardApp />);
    await go("#/projects/prj-fieldnotes/sessions/5e55b001-0000-4000-8000-00000000b001");
    await screen.findByRole("heading", { level: 1, name: "Tag and archive a note" });
    fireEvent.click(screen.getByRole("tab", { name: /API & network/ }));
    expect(screen.getByRole("heading", { name: "Network not captured" })).toBeTruthy();
  });

  it("renders the React Flow canvas for an analyzed session without crashing", async () => {
    sessionStorage.setItem("retrace.dashboard-mode", "preview");
    const { container } = render(<DashboardApp />);
    await go("#/projects/prj-ledgerly/sessions/5e55a001-0000-4000-8000-00000000a001");
    await screen.findByRole("heading", { level: 1, name: "Create and send an invoice" });
    await waitFor(() => expect(container.querySelector(".react-flow")).toBeTruthy());
  });
});

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

describe("backend mode (localhost developer sign-in)", () => {
  it("signs in, then shows API errors without silently falling back to preview", async () => {
    const calls = api({
      "POST /v1/auth/dev": () => ({ body: { access_token: "tok-1", user: { email: "dev@localhost" } } }),
      "GET /v1/projects": () => ({ status: 500, body: { detail: "database unavailable" } }),
    });
    render(<DashboardApp />);
    fireEvent.click(await screen.findByRole("button", { name: /Developer sign-in/ }));
    expect(await screen.findByText("Couldn’t load projects")).toBeTruthy();
    expect(screen.getByText("database unavailable")).toBeTruthy();
    expect(screen.queryByText("Preview workspace.")).toBeNull();
    expect(screen.getByRole("button", { name: "Open the preview workspace instead" })).toBeTruthy();
    expect(calls.find((c) => c.path === "/v1/projects")?.auth).toBe("Bearer tok-1");
    expect(calls.find((c) => c.path === "/v1/auth/dev")?.auth).toBeUndefined();
    expect(JSON.parse(sessionStorage.getItem("retrace.auth.v1:http://127.0.0.1:8000")!).access_token).toBe("tok-1");
    expect(localStorage.length).toBe(0);
  });

  it("pairs a recorder only after the user approves the claimed device", async () => {
    sessionStorage.setItem("retrace.auth.v1:http://127.0.0.1:8000", JSON.stringify({ access_token: "tok", user: { name: "Dev" } }));
    let claims: unknown[] = [];
    const calls = api({
      "GET /v1/projects": () => ({ body: [{ id: "p1", name: "Real project" }] }),
      "GET /v1/projects/p1/sessions": () => ({ body: [] }),
      "POST /v1/pairings": () => ({ body: { pairing_id: "pair-1", code: "K7M4QX", expires_at: new Date(Date.now() + 600_000).toISOString() } }),
      "GET /v1/pairings/pair-1": () => ({ body: { pairing_id: "pair-1", expires_at: new Date(Date.now() + 600_000).toISOString(), claims } }),
      "POST /v1/pairings/pair-1/approve": () => ({ body: { status: "approved" } }),
    });
    render(<DashboardApp />);
    await go("#/projects/p1");
    expect(await screen.findByText("No sessions yet")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: /Generate room code/ }));
    expect(await screen.findByLabelText("Room code K 7 M 4 Q X")).toBeTruthy();
    expect(screen.queryByRole("button", { name: /Simulate/ })).toBeNull();

    claims = [{ claim_id: "c-9", device_name: "Abel’s MacBook", status: "pending" }];
    fireEvent.click(await screen.findByRole("button", { name: "Review" }, { timeout: 5000 }));
    expect(calls.some((c) => c.path.endsWith("/approve"))).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Approve" }));
    expect(await screen.findByText(/Connected — this Mac can now upload/)).toBeTruthy();
    expect(calls.find((c) => c.path.endsWith("/approve"))?.body).toEqual({ claim_id: "c-9" });
  }, 10_000);
});
