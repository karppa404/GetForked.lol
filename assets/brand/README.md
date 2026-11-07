# Retrace brand assets

Generated with the built-in imagegen tool. The mark is an original angular folded path suggesting a retraced route and an abstract R. The warm coral palette follows the existing Retrace interface; Raycast was a reference for economy and small-size legibility, not an asset source.

## Sources

- [Transparent mark master](retrace-mark-master.png)
- [macOS tile master](retrace-app-icon-master.png)

## Applied assets

- `macos/Packaging/Retrace.icns`: 16–1024 pixel app icon representations.
- `macos/Sources/Retrace/Resources/RetraceMenuBarTemplate.png` and `@2x.png`: 18-point menu-bar mark. SwiftUI renders it as a system template, preserving light/dark contrast. Recording and pause badges remain separate from the brand.
- `web/public/brand/retrace-mark.png`: 128-pixel transparent logo for the landing page and dashboard.
- `web/app/icon.png`: 64-pixel favicon; `web/app/apple-icon.png`: 180-pixel touch icon. Next.js supplies their metadata links.

Rebuild derivatives on macOS with `scripts/build-brand-icons.sh`. It uses sips and iconutil for crop/resize and icon-container conversion, preserving generated alpha. No image API key or image generation call is needed to rebuild the checked-in formats.

## Exact generation prompts

### Master

Use case: logo-brand
Asset type: master logo mark for Retrace, a macOS app that observes workflows and traces evidence into diagrams; the same silhouette must work as a 16px menu bar icon and favicon.
Primary request: create a single original abstract geometric symbol with the confidence and economy of Raycast's icon design, but a distinct Retrace identity. A compact continuous angular ribbon that folds back on itself, suggesting a retraced path and a subtle abstract R through negative space. Two or three bold interlocking planes maximum. Strong square-ish silhouette, balanced negative space, broad uniform visual weight, unmistakable when tiny. Flat vector-like edges, no thin strokes.
Color palette: one solid warm coral-orange (#F36B45) matching Retrace's dark interface. No gradients.
Composition: one centered mark, isolated on genuinely transparent background, with about 15 percent clear padding on all sides, square image.
Constraints: no words, no letters written as text, no surrounding app tile, no mockup, no scene, no grid, no shadow, no glow, no texture, no extra variants. Do not reproduce Raycast's diagonal stripe/arrow mark. This should feel like an independent premium macOS developer tool.

### Targeted refinement

Use case: precise-object-edit / logo-brand. Edit target: the attached Retrace logo. Keep its exact angular R/ribbon silhouette and proportions. Change only the rendering: make every solid face one perfectly uniform flat coral #F36B45. Remove ALL stray orange/red flecks, debris, texture, edge glow, faint outlines, gradients and shadows both inside the negative space and outside the mark. Negative spaces and background must be completely transparent, with clean antialiased boundaries only along the actual silhouette. One isolated production-ready logo on a square transparent canvas. No new shapes, no type, no app tile, no mockup. Deliver an impeccably clean flat icon master.

### App icon

Use case: logo-brand. Asset type: final macOS application icon. Edit target: the supplied orange Retrace mark. Preserve the exact geometric R/ribbon silhouette, including all negative space. Place this mark, in clean flat coral-orange, centered on a deep charcoal (#141416) rounded-square macOS app tile. The mark occupies approximately 68 percent of tile width. Use a calm flat finish and extremely subtle natural edge definition. The tile should occupy about 86 percent of the square image, surrounded by genuinely transparent padding for the macOS icon grid. No letters or words outside the mark, no mockup, no scenery, no perspective, no bevel on the logo, no glow, no specks, no extra shapes. One crisp premium macOS app icon.

