// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { COPY_TEXT, FILES, SpecSheet } from "../spec-sheet";
import { SAMPLE_FILES } from "../spec-sample.data";

afterEach(cleanup);

describe("spec sheet", () => {
  it("ships the real exporter's files, with valid JSON contracts", () => {
    for (const f of FILES) expect(SAMPLE_FILES[f.path], f.path).toBeTruthy();
    for (const p of ["contracts/openapi.json", "contracts/arazzo.json", "reference/rebuild-profile.json"]) expect(() => JSON.parse(SAMPLE_FILES[p])).not.toThrow();
    expect(JSON.parse(SAMPLE_FILES["reference/rebuild-profile.json"]).latest.profile.coverage.status).toBe("partial");
  });

  it("switches files with clicks and arrow keys", () => {
    render(<SpecSheet />);
    const tabs = screen.getAllByRole("tab");
    expect(tabs).toHaveLength(FILES.length);
    expect(tabs[0].getAttribute("aria-selected")).toBe("true");
    expect(screen.getByRole("tabpanel").textContent).toContain("# Feature Specification: Ledgerline Inventory 3.1 clone");

    fireEvent.click(tabs[3]);
    expect(tabs[3].getAttribute("aria-selected")).toBe("true");
    expect(screen.getByRole("tabpanel").textContent).toContain('"openapi": "3.1.0"');

    fireEvent.keyDown(tabs[3], { key: "ArrowDown" });
    expect(tabs[4].getAttribute("aria-selected")).toBe("true");
    expect(document.activeElement).toBe(tabs[4]);
    fireEvent.keyDown(tabs[4], { key: "End" });
    fireEvent.keyDown(tabs[5], { key: "ArrowRight" });
    expect(tabs[0].getAttribute("aria-selected")).toBe("true");
    expect(tabs[0].tabIndex).toBe(0);
    expect(tabs[1].tabIndex).toBe(-1);
  });

  it("copies every sample file for an AI agent and says so", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    render(<SpecSheet />);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Copy for AI" })));
    expect(writeText).toHaveBeenCalledWith(COPY_TEXT);
    for (const f of FILES) expect(COPY_TEXT).toContain(`## ${f.path}`);
    expect(screen.getByRole("button", { name: "Copied" })).toBeTruthy();
    expect(screen.getByRole("status").textContent).toContain("Copied 6 sample files");
  });
});
