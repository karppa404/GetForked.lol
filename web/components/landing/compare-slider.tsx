"use client";

import { useRef, useState, type KeyboardEvent, type PointerEvent } from "react";

type Img = { src: string; alt: string };

const clamp = (n: number) => Math.min(100, Math.max(0, n));

/**
 * Before/after image comparison. Both images share one box; the before image is clipped to the left of the handle.
 * Drag (mouse, pen or touch), click anywhere to jump, or focus the handle and use the arrow keys.
 */
export function CompareSlider({ before, after, width, height, initial = 50 }: { before: Img & { label: string }; after: Img & { label: string }; width: number; height: number; initial?: number }) {
  const [pos, setPos] = useState(initial);
  const box = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);

  const fromPointer = (clientX: number) => {
    const r = box.current?.getBoundingClientRect();
    if (r && r.width > 0) setPos(clamp(((clientX - r.left) / r.width) * 100));
  };

  const onPointerDown = (e: PointerEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;
    e.preventDefault(); // no text selection or native image drag
    dragging.current = true;
    e.currentTarget.setPointerCapture?.(e.pointerId);
    fromPointer(e.clientX);
  };
  const onPointerMove = (e: PointerEvent<HTMLDivElement>) => { if (dragging.current) fromPointer(e.clientX); };
  const stop = () => { dragging.current = false; };

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const step = e.shiftKey ? 10 : 2;
    const next: Record<string, number> = { ArrowLeft: pos - step, ArrowDown: pos - step, ArrowRight: pos + step, ArrowUp: pos + step, PageDown: pos - 10, PageUp: pos + 10, Home: 0, End: 100 };
    if (!(e.key in next)) return;
    e.preventDefault();
    setPos(clamp(next[e.key]));
  };

  const shown = Math.round(pos);
  return (
    <>
      <p className="lp-compare-labels" aria-hidden="true"><span>{before.label}</span><span>{after.label}</span></p>
      <div
        ref={box}
        className="lp-compare"
        style={{ ["--pos" as string]: `${pos}%`, aspectRatio: `${width} / ${height}` }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={stop}
        onPointerCancel={stop}
        onLostPointerCapture={stop}
      >
        {/* eslint-disable-next-line @next/next/no-img-element -- static local screenshot, no optimizer needed */}
        <img className="lp-compare-after" src={after.src} alt={after.alt} width={width} height={height} draggable={false} loading="lazy" decoding="async" />
        {/* eslint-disable-next-line @next/next/no-img-element -- static local screenshot, no optimizer needed */}
        <img className="lp-compare-before" src={before.src} alt={before.alt} width={width} height={height} draggable={false} loading="lazy" decoding="async" />
        <div
          className="lp-compare-handle"
          role="slider"
          tabIndex={0}
          aria-label="Before and after divider"
          aria-orientation="horizontal"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={shown}
          aria-valuetext={`${shown}% before, ${100 - shown}% after`}
          onKeyDown={onKeyDown}
        >
          <span className="lp-compare-knob" aria-hidden="true">
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M6.5 5 2.5 9l4 4M11.5 5l4 4-4 4" /></svg>
          </span>
        </div>
      </div>
    </>
  );
}
