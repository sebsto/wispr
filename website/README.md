# Website

A static, self-contained product website. No build step required.

## Deployment

This site is plain HTML/CSS/JS and can be deployed anywhere that serves static files:

- **GitHub Pages**: push the contents of `website/` to a `gh-pages` branch
- **Netlify**: drag and drop the `website` folder into the Netlify dashboard
- **Vercel**: connect your repository and set the root directory to `website`
- **Any static host**: upload the files via FTP/SFTP

## Customization

### Colors

Edit the CSS variables at the top of `styles.css`:

```css
:root {
  --primary-blue: rgb(84, 155, 230);
  --deep-blue: rgb(33, 38, 162);
  --light-blue: rgb(173, 225, 252);
  /* ... */
}
```

### Hero wave background

The animated field behind the hero is rendered on a WebGL2 canvas by `waves.js`.
It is a dependency-free port of the React Bits `GradientWaves` component — the
GLSL shader is unchanged, but the `ogl` scaffolding was rewritten against the raw
WebGL2 API, so there is still no build step and nothing to install.

**Tuning it.** Every parameter lives in the `WAVES_CONFIG` block at the top of
`waves.js`. Edit a value and reload, or open the page with `?tune=1` for a live
control panel:

```
index.html?tune=1
```

The panel gives you a slider, picker or toggle for all 25 parameters, a
**Copy config** button that emits a `WAVES_CONFIG` block you can paste straight
back into `waves.js`, and **Replay intro** to watch the load animation again
without reloading. **Reset** returns everything to the values in the file. The
panel is only built when `?tune=1` (or `#tune`) is present, so visitors never see
it, and it also exposes `window.__waves` for tweaking from the console:

```js
__waves.apply({ speed: 0.6, brightness: 1.2 });
```

The three colors accept a design-token reference, so the palette stays defined in
one place — `var(--deep-blue)` resolves against the variables in `styles.css`.
Plain `#rrggbb` and `rgb()` values work too.

| Key | Default | What it does |
|-----|---------|--------------|
| `horizonColor` | `var(--deep-blue)` | Distant haze the waves fade into |
| `waveColor` | `var(--primary-blue)` | Mid color of the rolling wave bodies |
| `crestColor` | `#FFFFFF` | Highlight on the nearest crests |
| `speed` | `0.3` | Animation speed of the field |
| `amplitude` | `3.7` | Height of the waves |
| `waveScale` | `0.5` | Overall spatial frequency |
| `waveRatio` | `0.9` | Ratio of short to long wavelength components |
| `swell` | `35` | Large-scale horizontal swell distortion |
| `turbulence` | `20` | Large-scale cross-flow turbulence |
| `tilt` | `1.02` | Camera pitch toward the horizon, in radians |
| `zoom` | `1` | Field-of-view zoom, and the target the intro springs to |
| `height` | `2.8` | Vertical offset of the horizon line |
| `fogDepth` | `32` | Distance over which waves fade into haze |
| `detail` | `'medium'` | Raymarch quality: `low`, `medium`, `high` |
| `brightness` | `1.5` | Final color multiplier |
| `opacity` | `1` | Global opacity of the effect |
| `intro` | `true` | Spring the zoom in on load |
| `introZoomFrom` | `0.43` | Zoom the intro starts from (lower = wider) |
| `introStiffness` | `60` | Spring constant; higher snaps faster |
| `introDamping` | `31` | Friction. Overshoot needs this under `2 * sqrt(introStiffness)` — about `15.5` at the current stiffness, so the default eases in with no bounce |
| `mouseInteraction` | `true` | Pointer-driven camera parallax |
| `parallaxStrength` | `0.5` | Strength of the cursor drift |
| `grain` | `true` | Shader film grain, on top of the page-wide grain overlay |
| `grainIntensity` | `0.095` | Amplitude of that grain |
| `maxDpr` | `2` | Render-buffer resolution ceiling. Each step up multiplies the shaded pixel count, and this shader is the most expensive thing on the page |

**Behaviour worth knowing.** The render loop is paused whenever the hero scrolls
out of view or the tab is hidden. Under `prefers-reduced-motion: reduce` the
field is drawn once as a still frame and never animates. If WebGL2 is
unavailable — or JS is off entirely — the hero falls back to the CSS glow in
`styles.css` (`.hero-glow`), which is otherwise hidden by the `.waves-active`
class. The `.hero-scrim` layer sits between the canvas and the copy to keep hero
text above the 4.5:1 contrast threshold; if you brighten the waves a lot, darken
the scrim to match.

Turning the effect off completely: delete the `<div class="hero-waves">` and
`<div class="hero-scrim">` elements plus the `waves.js` script tag from
`index.html`. The CSS glow takes over with no other changes.

### Load curtain & hero entrance

On first visit the page holds behind a curtain — the wordmark over a hairline
that fills with `--primary-blue` — then lifts into a staggered reveal of the hero
copy while the wave field springs its zoom open. The curtain lives in
`index.html`; the sequencing is at the bottom of `script.js`.

**It waits on real signals, not a timer:** `document.fonts.ready`, `window.load`,
and the first painted wave frame (`waves.js` fires a `wispr:waves-ready` event).
The fill advances as each one lands. Three guards keep that honest:

- `MIN_HOLD` (450ms) — the floor, so a warm cache doesn't flash the curtain for a
  single frame
- `FAILSAFE` (1200ms) — lifts regardless, so a stalled signal can never strand
  the page
- the wave signal also resolves 200ms after `load`, so a machine without WebGL2
  isn't waiting on a frame that will never arrive

Both constants are at the top of that block in `script.js`. `MIN_HOLD` is the one
that changes how the wait *feels*.

**The reveal.** Lifting the curtain removes `intro-armed` from `<html>`, which
plays every hero beat at once — each element offset by its own `--intro-delay`,
set per element near the bottom of `styles.css`:

| Element | Delay |
| --- | --- |
| `.hero-eyebrow` | 60ms |
| headline line 1 | 120ms |
| headline line 2 | 180ms |
| `.hero-cta` | 260ms |
| `.hero-blurb` | 340ms |
| `.hero-wayfinding` | 340ms |

The same moment releases the zoom spring, so the background motion and the copy
arrive together rather than in sequence. To retime the entrance, edit those
`--intro-delay` values; to change the distance or curve, edit the shared
`[data-intro]` rule above them. Elements opt in purely by carrying a
`data-intro` attribute in `index.html`.

**Things to know before editing.** The classes are set by an inline `<script>` in
`<head>` rather than by `script.js`, because they have to be in place before the
first paint — set them later and you get a flash of unstyled content. Nothing is
hidden unless that script runs, so with JS disabled the page is simply visible.

Because those classes hide things (`intro-loader` covers the page, `intro-armed`
holds the hero, `reveal-armed` sits the later sections at `opacity: 0`), the
inline script also carries a failsafe for the case where it runs but `script.js`
does not — a 404, a blocking extension or proxy, a syntax error. `script.js` sets
`document.documentElement.dataset.introReady = '1'` on its last line; the inline
script checks that flag on `DOMContentLoaded` and, if it is unset, strips all
three classes. The page then renders plain and fully visible instead of stranded
behind the curtain. Keep that assignment as the final statement of `script.js`:
moved earlier, it stops covering a mid-file throw.
The curtain shows once per browser session (a `wispr-intro` key in
`sessionStorage`); later loads keep the stagger and skip the curtain. Under
`prefers-reduced-motion: reduce` there is no curtain, no stagger and no spring —
the final state paints immediately. And if an element already carries its own
`transform`, the entrance offset has to be composed into it rather than layered
on: `.hero-wayfinding` is centred with `translateY(-50%)`, so it has a dedicated
armed rule. Skip that and it slides its whole centring offset instead of 12px.

### Content

Edit the text directly in `index.html`. The structure is semantic and organized by section, so it's easy to find and change.

### Fonts

Headings use [Space Grotesk](https://fonts.google.com/specimen/Space+Grotesk) and body text uses [DM Sans](https://fonts.google.com/specimen/DM+Sans), loaded from Google Fonts in `index.html`. If the fonts can't load (e.g. offline), the site falls back to system fonts and remains fully usable. To change fonts, edit the `<link>` in `index.html` and the `--font-heading` / `--font-body` variables in `styles.css`.

### Images

All images live in the website directory:

- `icon.svg` — logo
- `screenshots/menu.png` — menu bar screenshot
- `screenshots/settings.png` — settings screenshot
- `screenshots/model-management.png` — model management screenshot
- `screenshots/onboarding-01.png` through `onboarding-06.png` — onboarding flow screenshots

Scripts: `script.js` handles the nav, carousel, copy buttons and the load
curtain; `waves.js` renders the hero background.

The site is fully self-contained and portable — copy the `website/` folder anywhere and it works.

## Browser Support

- Chrome/Edge 90+
- Firefox 88+
- Safari 14+
- All modern mobile browsers

The hero wave background needs WebGL2, which lands in Safari 15 — Safari 14 and
any browser with WebGL2 disabled or unavailable (including software-rendering
blocklists) fall back to the CSS glow automatically. Every other part of the page
is unaffected.

Scroll-snap is used for smooth section/carousel scrolling and is supported in all modern browsers; older browsers fall back to standard smooth scrolling.
