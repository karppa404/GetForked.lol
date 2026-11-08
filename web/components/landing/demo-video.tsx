"use client";

import { track } from "@vercel/analytics";
import { useEffect, useRef, useState } from "react";
import { DEMO_POSTER, DEMO_VIDEO } from "./demo-assets";

type State = "poster" | "loading" | "ready";

/** Poster first. The <video> element (and its download) exists only after the user presses Play. */
export function DemoVideo({ available }: { available: boolean }) {
  const [state, setState] = useState<State>("poster");
  const video = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    if (state !== "loading") return;
    video.current?.focus();
    video.current?.play().catch(() => setState("ready")); // autoplay refused: native controls remain
  }, [state]);

  if (!available) {
    return (
      <div className="lp-video lp-video--missing">
        <p>The demo video isn’t in this build yet.</p>
        <p className="lp-dim">Expected at <code>web/public{DEMO_VIDEO}</code></p>
      </div>
    );
  }

  const ready = () => setState("ready");

  return (
    <div className="lp-video" aria-busy={state === "loading"}>
      {state === "poster" ? (
        <>
          {/* eslint-disable-next-line @next/next/no-img-element -- static local poster, no optimizer needed */}
          <img src={DEMO_POSTER} alt="" width={1920} height={1080} decoding="async" />
          <button type="button" className="lp-play" onClick={() => { track("Play Demo"); setState("loading"); }}>
            <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3.5 2.2v9.6a.6.6 0 0 0 .9.5l7.6-4.8a.6.6 0 0 0 0-1L4.4 1.7a.6.6 0 0 0-.9.5z" fill="currentColor" /></svg>
            Play demo
          </button>
        </>
      ) : (
        <>
          <video ref={video} src={DEMO_VIDEO} poster={DEMO_POSTER} controls playsInline preload="none" aria-label="Retrace product demo" onPlaying={ready} onCanPlay={ready} onError={ready}>
            <track src="/demo/captions.vtt" kind="captions" srcLang="en" label="English" default />
            Your browser does not support video playback. <a href={DEMO_VIDEO}>Download the demo</a>.
          </video>
          {state === "loading" && (
            <div className="lp-video-loading" role="status">
              <span className="lp-spinner" aria-hidden="true" />
              Loading video…
            </div>
          )}
        </>
      )}
    </div>
  );
}
