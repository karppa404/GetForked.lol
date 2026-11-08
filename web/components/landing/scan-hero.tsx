import { LEDGERLINE_SIZE, SCAN_TARGETS } from "./ledgerline-targets";

export const LEDGERLINE_BEFORE = "/ledgerline/before.webp";
export const LEDGERLINE_AFTER = "/ledgerline/after.webp";
export const LEDGERLINE_BEFORE_ALT =
  "Ledgerline Inventory 3.1, a fictional Windows 2000-era inventory app: grey bevelled toolbar, a navigator tree, a Stock Items grid of parts with supplier, on-hand and reorder columns, and an item form below.";

/** Hero visual: the legacy app with a red scan line sweeping over it. CSS animation only, no client JS. */
export function ScanHero() {
  return (
    <figure className="lp-scan">
      <div className="lp-scan-frame">
        {/* eslint-disable-next-line @next/next/no-img-element -- static local screenshot, no optimizer needed */}
        <img src={LEDGERLINE_BEFORE} width={LEDGERLINE_SIZE.width} height={LEDGERLINE_SIZE.height} alt={LEDGERLINE_BEFORE_ALT} fetchPriority="high" decoding="async" />
        <div className="lp-scan-marks" aria-hidden="true">
          {SCAN_TARGETS.map((t) => (
            <span key={t.tag} style={{ left: `${t.x}%`, top: `${t.y}%`, width: `${t.w}%`, height: `${t.h}%` }}>
              <em>{t.tag}</em>
            </span>
          ))}
        </div>
        <div className="lp-scan-beam" aria-hidden="true" />
      </div>
      <figcaption>
        <span className="lp-scan-chip"><i aria-hidden="true" />Scanning Ledgerline Inventory 3.1</span>
        <span>A made-up legacy app. The overlay is illustrative.</span>
      </figcaption>
    </figure>
  );
}
