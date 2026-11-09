import Link from "next/link";
import { CompareSlider } from "@/components/landing/compare-slider";
import { LEDGERLINE_SIZE } from "@/components/landing/ledgerline-targets";
import { LEDGERLINE_AFTER, LEDGERLINE_BEFORE, LEDGERLINE_BEFORE_ALT, ScanHero } from "@/components/landing/scan-hero";
import { HowItWorks } from "@/components/landing/how-it-works";
import { SpecSheet } from "@/components/landing/spec-sheet";
import { TrackedLink } from "@/components/landing/tracked-link";
import { BrandMark } from "@/components/brand-mark";
import "./landing.css";

const REPO = "https://github.com/karppa404/HackUTD-2026";
const RELEASES = `${REPO}/releases`;
// shortcut: pinned tag, because every release is a prerelease and /releases/latest/download 404s; bump on each release or publish one as non-prerelease.
const VERSION = "v0.1.0-alpha.4";
const DOWNLOAD = `${RELEASES}/download/${VERSION}/Retrace-macOS-arm64.zip`;
const SETUP = "https://github.com/karppa404/HackUTD-2026/blob/main/docs/LOCAL_DEMO.md";

function AppleGlyph() {
  return (
    <svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
      <path d="M11.18 8.5c-.02-1.6 1.31-2.38 1.37-2.42-.75-1.09-1.91-1.24-2.32-1.26-.99-.1-1.93.58-2.43.58-.5 0-1.27-.57-2.09-.55-1.08.02-2.07.63-2.62 1.59-1.12 1.94-.29 4.81.8 6.38.53.77 1.17 1.63 2 1.6.8-.03 1.1-.52 2.07-.52.97 0 1.24.52 2.09.5.86-.01 1.41-.78 1.94-1.55.61-.89.86-1.75.88-1.8-.02-.01-1.68-.65-1.69-2.55ZM9.6 3.8c.44-.54.74-1.28.66-2.03-.64.03-1.41.43-1.87.96-.41.47-.77 1.23-.67 1.96.71.05 1.44-.36 1.88-.89Z" />
    </svg>
  );
}

export default function Home() {
  return (
    <div className="lp">
      <a className="lp-skip" href="#main">Skip to content</a>
      <header className="lp-nav">
        <div className="lp-nav-inner">
          <Link href="/" className="lp-wordmark"><BrandMark />Retrace</Link>
          <nav aria-label="Sections" className="lp-nav-links">
            <a href="#facelift">Face lift</a>
            <a href="#how">How it works</a>
            <a href="#spec">Spec sheet</a>
          </nav>
          <div className="lp-nav-actions">
            <a className="lp-github" href={REPO} aria-label="View Retrace on GitHub">
              <svg aria-hidden="true" viewBox="0 0 24 24" fill="currentColor"><path d="M12 .5a12 12 0 0 0-3.79 23.39c.6.11.82-.26.82-.58v-2.23c-3.34.73-4.04-1.42-4.04-1.42-.55-1.39-1.33-1.76-1.33-1.76-1.09-.75.08-.73.08-.73 1.2.09 1.84 1.24 1.84 1.24 1.07 1.83 2.81 1.3 3.5.99.11-.77.42-1.3.76-1.6-2.67-.31-5.47-1.34-5.47-5.94 0-1.31.47-2.38 1.24-3.22-.13-.3-.54-1.53.12-3.18 0 0 1.01-.32 3.3 1.23a11.48 11.48 0 0 1 6 0c2.29-1.55 3.3-1.23 3.3-1.23.66 1.65.25 2.88.12 3.18.77.84 1.24 1.91 1.24 3.22 0 4.61-2.81 5.63-5.49 5.93.43.38.81 1.11.81 2.24v3.32c0 .32.22.7.83.58A12 12 0 0 0 12 .5Z" /></svg>
            </a>
            <TrackedLink event="Download" location="nav" href={DOWNLOAD} className="lp-btn lp-btn--light"><AppleGlyph />Download</TrackedLink>
          </div>
        </div>
      </header>

      <main id="main">
        <section className="lp-hero" aria-labelledby="hero-title">
          <h1 id="hero-title"><span className="lp-hero-lead">GET F**ked!</span> <span>Get the blueprint to rebuild it.</span></h1>
          <div className="lp-actions">
            <TrackedLink event="Download" location="hero" href={DOWNLOAD} className="lp-btn lp-btn--light"><AppleGlyph />Download for Mac</TrackedLink>
            <p className="lp-mono">macOS 14+ and Apple Silicon required · {VERSION}</p>
            <p className="lp-mono lp-mono--links"><a href={RELEASES}>All releases</a><span aria-hidden="true">|</span><a href={SETUP}>Setup guide</a></p>
          </div>
          <ScanHero />
        </section>

        <section className="lp-section lp-facelift" id="facelift" aria-labelledby="facelift-title">
          <h2 id="facelift-title" className="lp-h2">The face lift</h2>
          <p className="lp-sub">Same screen, same stock data. The breakdown lists every field, action and call Ledgerline exposes, so the rebuild can keep all of it. Drag the handle to compare.</p>
          <figure className="lp-compare-figure">
            <CompareSlider
              width={LEDGERLINE_SIZE.width}
              height={LEDGERLINE_SIZE.height}
              before={{ src: LEDGERLINE_BEFORE, alt: LEDGERLINE_BEFORE_ALT, label: "Before · Ledgerline 3.1" }}
              after={{ src: LEDGERLINE_AFTER, label: "After · rebuilt", alt: "The same Stock Items screen redesigned: dark sidebar navigation, stock summary cards, a table with stock level bars and status pills, and a detail panel for Safety glasses with a Reorder 120 units button." }}
            />
          </figure>
        </section>


        <HowItWorks />
        <SpecSheet />


        <section className="lp-cta" aria-labelledby="cta-title">
          <h2 id="cta-title">Get Retrace for your Mac</h2>
          <p className="lp-meta">Unzip, move Retrace.app into Applications and open it from the menu bar. macOS 14+, Apple Silicon.</p>
          <TrackedLink event="Download" location="cta" href={DOWNLOAD} className="lp-btn lp-btn--light"><AppleGlyph />Download for Mac</TrackedLink>
        </section>
      </main>

      <footer className="lp-footer">
        <span className="lp-wordmark"><BrandMark />Retrace</span>
        <span className="lp-dim">Runs on this Mac. Analysis only sees what you upload.</span>
        <span className="lp-footer-links">
          <a href={RELEASES}>Releases</a>
          <a href={REPO}>GitHub</a>
        </span>
      </footer>
    </div>
  );
}
