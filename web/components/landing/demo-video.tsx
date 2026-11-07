"use client";

import { useEffect, useRef, useState } from "react";
import { DEMO_POSTER, DEMO_VIDEO } from "./demo-assets";

/** Poster first. The <video> element (and its download) exists only after the user presses Play. */
export function DemoVideo({ available }: { available: boolean }) {
  const [playing, setPlaying] = useState(false);
  const video = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    if (!playing) return;
    video.current?.focus();
    video.current?.play().catch(() => {}); // autoplay refused: native controls remain
  }, [playing]);

  if (!available) {
    return (
      <div className="lp-video lp-video--missing">
        <p>The demo video isn’t in this build yet.</p>
        <p className="lp-dim">Expected at <code>web/public{DEMO_VIDEO}</code></p>
      </div>
    );
  }

  return (
    <div className="lp-video">
      {playing ? (
        <video ref={video} src={DEMO_VIDEO} poster={DEMO_POSTER} controls playsInline preload="none" aria-label="Retrace product demo">
          <track src="/demo/captions.vtt" kind="captions" srcLang="en" label="English" default />
          Your browser does not support video playback. <a href={DEMO_VIDEO}>Download the demo</a>.
        </video>
      ) : (
        <>
          {/* eslint-disable-next-line @next/next/no-img-element -- static local poster, no optimizer needed */}
          <img src={DEMO_POSTER} alt="" width={1920} height={1080} loading="lazy" decoding="async" />
          <button type="button" className="lp-play" onClick={() => setPlaying(true)}>
            <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3.5 2.2v9.6a.6.6 0 0 0 .9.5l7.6-4.8a.6.6 0 0 0 0-1L4.4 1.7a.6.6 0 0 0-.9.5z" fill="currentColor" /></svg>
            Play demo
          </button>
        </>
      )}
    </div>
  );
}
