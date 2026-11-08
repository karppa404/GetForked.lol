// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { CompareSlider } from "../compare-slider";

afterEach(cleanup);

// jsdom has no PointerEvent; without it fireEvent drops clientX and button.
if (!("PointerEvent" in window)) {
  class PointerEventPolyfill extends MouseEvent {
    pointerId: number;
    constructor(type: string, init: PointerEventInit = {}) { super(type, init); this.pointerId = init.pointerId ?? 0; }
  }
  Object.assign(window, { PointerEvent: PointerEventPolyfill });
}

const setup = () => {
  const view = render(
    <CompareSlider width={1200} height={760} before={{ src: "/b.webp", alt: "before", label: "Before" }} after={{ src: "/a.webp", alt: "after", label: "After" }} />,
  );
  const box = view.container.querySelector<HTMLDivElement>(".lp-compare")!;
  box.getBoundingClientRect = () => ({ left: 100, width: 400, top: 0, height: 253, right: 500, bottom: 253, x: 100, y: 0, toJSON() {} });
  return { slider: screen.getByRole("slider"), box };
};

describe("compare slider", () => {
  it("stacks both images at the same intrinsic size and starts in the middle", () => {
    const { slider, box } = setup();
    const imgs = box.querySelectorAll("img");
    expect([...imgs].map((i) => [i.getAttribute("width"), i.getAttribute("height")])).toEqual([["1200", "760"], ["1200", "760"]]);
    expect(slider.getAttribute("aria-valuenow")).toBe("50");
    expect(box.style.getPropertyValue("--pos")).toBe("50%");
  });

  it("moves with the arrow keys and clamps at Home and End", () => {
    const { slider } = setup();
    fireEvent.keyDown(slider, { key: "ArrowRight" });
    expect(slider.getAttribute("aria-valuenow")).toBe("52");
    fireEvent.keyDown(slider, { key: "ArrowLeft", shiftKey: true });
    expect(slider.getAttribute("aria-valuenow")).toBe("42");
    fireEvent.keyDown(slider, { key: "End" });
    fireEvent.keyDown(slider, { key: "ArrowRight" });
    expect(slider.getAttribute("aria-valuenow")).toBe("100");
    fireEvent.keyDown(slider, { key: "Home" });
    expect(slider.getAttribute("aria-valuenow")).toBe("0");
  });

  it("jumps to a click and follows a drag", () => {
    const { slider, box } = setup();
    fireEvent.pointerDown(box, { button: 0, clientX: 200, pointerId: 1 });
    expect(slider.getAttribute("aria-valuenow")).toBe("25");
    fireEvent.pointerMove(box, { clientX: 400, pointerId: 1 });
    expect(slider.getAttribute("aria-valuenow")).toBe("75");
    fireEvent.pointerUp(box, { pointerId: 1 });
    fireEvent.pointerMove(box, { clientX: 150, pointerId: 1 });
    expect(slider.getAttribute("aria-valuenow")).toBe("75");
  });
});
