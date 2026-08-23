# Product Website Redesign — CLAUDE.md

## Rules (non-negotiable)

- Always invoke the `ui-ux-pro-max` skill before writing any frontend code. No exceptions, even for small edits.
- Output is **static HTML/CSS/JS only** — no build step, no bundler, no frameworks (no React/Vue/etc.), no external JS dependencies beyond what's needed for the carousel.
- All code lives under `website/`. Do not scatter files elsewhere.
- Semantic HTML throughout (proper heading hierarchy, `<section>`/`<nav>`/`<button>` over generic `<div>`s).
- Fully responsive: mobile, tablet, desktop breakpoints.
- Accessible: alt text on all images, keyboard-navigable carousel (arrow keys + visible focus states), sufficient color contrast against the palette below.

## File structure to produce

```
website/
├── index.html
├── styles.css
├── script.js
├── icon.svg
├── screenshots/
│   ├── menu.png
│   ├── settings.png
│   ├── model-management.png
│   └── onboarding-01.png ... onboarding-06.png
└── README.md
```

- Treat everything under `screenshots/` and `icon.svg` as **pre-existing assets** — reference them by path, do not attempt to generate or fabricate image content for them.
- If an asset is missing when you check the folder, flag it rather than silently substituting a placeholder.

## Sections (in order)

1. **Hero** — logo, headline, call-to-action
2. **Download/Install** — Homebrew install command(s), download button, donate option
3. **Features** — 4 features, card layout
4. **How It Works** — 3-step process
5. **Onboarding** — interactive carousel, 6 steps (`onboarding-01.png` – `onboarding-06.png`)
6. **Screenshots** — visual showcase (menu, settings, model-management)
7. **Use Cases** — 4 user scenarios
8. **Support** — donation CTA with Revolut link
9. **Footer** — links, copyright

## Design tokens

Define as CSS variables in `styles.css`, editable at the top of the file:

```css
:root {
  --primary-blue: rgb(84, 155, 230);
  --deep-blue: rgb(33, 38, 162);
  --light-blue: rgb(173, 225, 252);
}
```

Extend this token set (typography scale, spacing, dark-mode variables) as needed per the `frontend-design` skill's guidance — don't leave it at just three colors.

## Visual reference (match this style)

A reference screenshot (Osmo-style landing page) defines the target aesthetic. Match these attributes — not the literal copy or brand:

**Palette & background**

- Near-black background (`#0a0a0a` – `#111` range), not pure `#000`
- A single warm accent color used sparingly but boldly (their orange `~#ff4d1f` → substitute our `--primary-blue` family for the equivalent glow effect)
- Subtle film-grain/noise texture overlaid on the background (CSS `filter` + SVG noise, or a repeating noise PNG at low opacity) — this is a defining detail, not decoration to skip
- The hero background is NOT a single soft blob. It's built from 3–5 large overlapping arc/crescent shapes (like offset, oversized rings or C-shapes), each filled with a blurred gradient and varying opacity (roughly 15–60%), layered so their edges cut across each other and create banded, sliced glow regions rather than one uniform glow. Implement as an inline `<svg>` with several `<path>` or `<circle>` elements (thick strokes or filled crescents via arcs), each with a Gaussian blur `<filter>` and a gradient fill referencing the design tokens — not a single `radial-gradient()` CSS background. This layered-arc construction is the single most defining visual element of the reference and should not be simplified to one blob.

**Typography**

- Hero headline: very large (clamp ~64–110px), tight line-height, bold sans-serif, white text over dark background, wraps to 2 lines
- Body/nav text: light gray (~`#a0a0a0`), smaller, generous letter-spacing on secondary links

**Layout patterns**

- Top nav: logo left, centered primary nav links, auth/CTA buttons right (ghost "Log in" + solid button)
- Two stacked secondary link columns positioned left-mid-page (small muted text, e.g. resource/doc categories) — decorative wayfinding, not primary nav
- Hero CTA row: one solid light button + one dark/glass button containing small avatar/icon stack + label
- Supporting paragraph block anchored lower-left of hero, constrained width (~400px), muted gray text
- Thin decorative line/crosshair elements as accents near lower-right — hairline strokes, low opacity

**Motion cues (if adding JS)**

- Subtle parallax or slow drift on the background glow
- Buttons: slight scale/opacity transition on hover, no jarring movement

Apply this treatment primarily to the **Hero** section; carry the dark theme, grain texture, and accent-glow language through the rest of the page (Features, How It Works, etc.) for consistency, but you don't need to replicate the exact blob/crosshair motif everywhere.

## Browser support target

Chrome/Edge 90+, Firefox 88+, Safari 14+, modern mobile browsers. Use CSS scroll-snap for section/carousel scrolling with a smooth-scroll fallback for browsers that don't support it — don't gate functionality behind it.

## Definition of done

Before considering the task complete, verify:

- [ ] All 9 sections present and in order in `index.html`
- [ ] Carousel works via click/swipe AND keyboard (arrow keys, focus-visible)
- [ ] Page is usable at 375px, 768px, and 1440px widths
- [ ] No console errors when `index.html` is opened directly (file://) or served locally
- [ ] No build step required — opening `index.html` works as-is
- [ ] `website/README.md` exists and matches the deployment/customization docs (see separate README content)
