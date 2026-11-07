// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { DemoVideo } from "../demo-video";

afterEach(cleanup);

describe("demo video", () => {
  it("shows only the poster until Play, then mounts the local video with controls", () => {
    HTMLMediaElement.prototype.play = () => Promise.resolve();
    const { container } = render(<DemoVideo available />);
    expect(container.querySelector("video")).toBeNull();
    expect(container.querySelector("img")?.getAttribute("src")).toBe("/demo/poster.webp");
    fireEvent.click(screen.getByRole("button", { name: "Play demo" }));
    const video = container.querySelector("video")!;
    expect(video.getAttribute("src")).toBe("/demo/retrace-demo.mp4");
    expect(video.getAttribute("preload")).toBe("none");
    expect(video.hasAttribute("controls")).toBe(true);
    expect(video.hasAttribute("playsinline")).toBe(true);
    expect(video.querySelector('track[kind="captions"]')?.getAttribute("src")).toBe("/demo/captions.vtt");
  });

  it("says plainly when the video file is missing", () => {
    render(<DemoVideo available={false} />);
    expect(screen.getByText(/isn’t in this build yet/)).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Play demo" })).toBeNull();
  });
});
