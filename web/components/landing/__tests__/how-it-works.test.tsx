// @vitest-environment jsdom
import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { HowItWorks } from "../how-it-works";

afterEach(cleanup);

describe("how it works", () => {
  it("describes each story step and its network limitations", () => {
    render(<HowItWorks />);
    expect(screen.getAllByRole("heading", { level: 3 }).map((h) => h.textContent)).toEqual([
      "Choose an application", "Record a workflow", "Review and upload", "Explore the story",
    ]);
    expect(screen.getAllByText("Network:")).toHaveLength(4);
    expect(screen.getByText(/timing-based associations/)).toBeTruthy();
    expect(screen.getByRole("link", { name: /spec sheet/ }).getAttribute("href")).toBe("#spec");
  });
});
