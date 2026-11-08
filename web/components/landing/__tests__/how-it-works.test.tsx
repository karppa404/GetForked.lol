// @vitest-environment jsdom
import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { HowItWorks } from "../how-it-works";

afterEach(cleanup);

describe("how it works", () => {
  it("walks one scan through scan, confirm and breakdown, then hands off to the spec sheet", () => {
    const { container } = render(<HowItWorks />);
    expect(container.querySelector("section#how")).not.toBeNull();
    expect(screen.getAllByRole("heading", { level: 3 }).map((h) => h.textContent)).toEqual([
      "Enter a URL, then step away",
      "Check the frames, then upload",
      "Get the breakdown",
    ]);
    expect(screen.getByRole("link", { name: /spec sheet/ }).getAttribute("href")).toBe("#spec");
  });

  it("describes both screenshots and uses no slider", () => {
    render(<HowItWorks />);
    const imgs = screen.getAllByRole("img").filter((el) => el.tagName === "IMG");
    expect(imgs).toHaveLength(2);
    for (const img of imgs) expect(img.getAttribute("alt")?.length).toBeGreaterThan(40);
    expect(screen.queryByRole("slider")).toBeNull();
  });

  it("keeps endpoint paths generic", () => {
    const { container } = render(<HowItWorks />);
    const paths = [...container.querySelectorAll("code")].map((c) => c.textContent ?? "");
    expect(paths.length).toBeGreaterThan(0);
    for (const p of paths) expect(p).toMatch(/^\/[a-z]+\/…$/);
  });
});
