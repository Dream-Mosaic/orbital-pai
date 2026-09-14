# Orbital P.A.I — brand asset prompts (Nano Banana / Gemini image)

Tracks issue #2. Every prompt below starts with the shared style block so all assets
come out of one visual language: the Meridian orb as it renders on screen. Generate,
pick candidates, process on your side, then hand back for integration (sizes in the
last section).

Source of the colours: `native/lib/meridian/tokens.dart` and `palette.dart`
(`OrbState.speaking` = Henry's colour).

| Token | Hex | Use |
|---|---|---|
| ground | `#020309` | app background |
| shell | `#07080F` | cards, adaptive-icon background layer |
| ink | `#E8EBF4` | primary text |
| ink dim | `#9AA1B6` | secondary text |
| ink faint | `#5D647A` | muted / hairlines |
| Henry green (brand) | `#3ECF9A` | orb rim, wordmark accent, primary button |
| Henry glow | `#10B981` | halo / bloom |
| Henry wave | `#6EE7B7` | the waveform line |
| you amber | `#F2AC46` | secondary accent only (never on the icon) |

Display type: **Space Grotesk** (bold, wide tracking). Body: **Inter**.

---

## 0. Shared style block

Paste this at the top of every prompt, then append the per-asset section.

```
A single glossy sphere of dark smoked glass, viewed straight on, lit from the upper
left so a soft specular highlight sits in its top-left quadrant. The sphere's edge is
a thin luminous rim in mint green #3ECF9A, and it emits a soft, wide bloom in emerald
#10B981 that fades into the background. Across the exact horizontal middle of the
sphere runs one thin, bright, slightly wavy line in pale green #6EE7B7, like a calm
audio waveform, glowing gently. Just outside the sphere is a single hairline ring in
faint grey-green, perfectly circular and concentric. Background is a near-black
navy #020309, flat, with only the sphere's bloom lighting it. The sphere is centred.
Clean, minimal, product-icon quality, crisp edges, subtle depth, no noise.
```

Append this negative list to every prompt as well:

```
No text, no letters, no logos, no robots, no faces, no eyes, no planets, no stars,
no galaxies, no rings tilted in 3D, no lens flares, no particles, no extra spheres,
no reflections of a room, no hands, no borders, no drop shadow outside the bloom.
```

---

## 1. App icon master (Android / desktop launcher)

Size: **1024 × 1024**, square, PNG.

### 1a. Full icon (used as-is for macOS / Windows / legacy Android)

```
[shared style block]

Composition: the sphere's diameter is about 68% of the frame width, centred. The
hairline ring sits at about 78% of the frame width. The bloom may reach the frame
edge but the background corners stay near-black. Square canvas, 1:1, no rounded
corners (the OS applies its own mask).
```

### 1b. Adaptive-icon foreground layer (Android)

Android crops adaptive icons to a circle/squircle from the centre 66%. Keep the sphere
inside that safe zone; the ring will be partially clipped, which is fine.

```
[shared style block]

Composition: the sphere's diameter is about 52% of the frame width, centred. The
hairline ring at about 60%. Everything outside the ring is a flat, uniform
#07080F with no gradient and no bloom past the ring — this layer will be
composited over a solid background, so the outer area must be perfectly flat.
Square canvas, 1:1.
```

Background layer: no generation needed, a flat `#07080F` square.

---

## 2. Favicon source

Size: **512 × 512**, square, PNG. This will be downscaled to 16 px, so it is
deliberately simpler and higher-contrast than the app icon.

```
[shared style block]

Simplify: remove the outer hairline ring entirely. Make the waveform line about
twice as thick as usual and nearly straight, with only a hint of wave. Make the
sphere's rim brighter and the bloom tighter so the disc reads as a solid glowing
green circle from a distance. The sphere's diameter is about 80% of the frame.
Background stays #020309 (it may be masked to transparent afterwards).
```

Also worth trying: the same prompt with `Background is fully transparent` for an
SVG-traced or PNG-alpha favicon.

---

## 3. Authentik (identity provider branding)

### 3a. Horizontal logo, transparent background

Size: **1600 × 400** (4:1), PNG with alpha.

```
[shared style block, but replace the background sentence with:]
Background is fully transparent.

Composition: the sphere sits at the left, its diameter about 70% of the canvas
height, with its hairline ring around it. To the right of the sphere, vertically
centred, the word "ORBITAL" in a bold geometric grotesque typeface similar to
Space Grotesk, all caps, wide letter-spacing, in off-white #E8EBF4. Below it, in
much smaller letters with the same wide spacing, "P.A.I" in mint green #3ECF9A.
The sphere's bloom lightly touches the left edge of the text. Wide 4:1 canvas.
```

Image models misspell. **Check the wordmark letter by letter.** If it is wrong, generate
with the text sentences removed and set the wordmark in post (Space Grotesk Bold, tracking
+0.2em) — the font is already in `native/assets/fonts/SpaceGrotesk.ttf`.

### 3b. Square avatar / tenant icon

Reuse **1a** (the full app icon). Authentik shows it small on the login card, so if it
looks muddy use **2** (the favicon source) instead.

### 3c. Colour scheme for Authentik's brand settings

Authentik (Admin → System → Brands → Branding / custom CSS) takes a logo, favicon, and
custom CSS. The variables to set:

```css
:root {
  --ak-dark-background: #020309;        /* page */
  --ak-dark-background-darker: #020309;
  --ak-dark-background-light: #07080F;  /* login card */
  --ak-dark-background-lighter: #0D0F19;
  --ak-dark-foreground: #E8EBF4;        /* text */
  --ak-dark-foreground-darker: #9AA1B6;
  --ak-dark-foreground-link: #3ECF9A;   /* links */
  --ak-accent: #3ECF9A;                 /* primary button */
  --pf-global--primary-color--100: #3ECF9A;
  --pf-global--primary-color--200: #10B981;
  --pf-global--link--Color: #3ECF9A;
  --pf-global--BorderColor--100: rgba(255,255,255,0.07);
}
```

Variable names change between Authentik releases; verify against the running version's
default stylesheet before relying on them. The intent is: ground `#020309`, card `#07080F`,
text `#E8EBF4`, everything interactive `#3ECF9A`.

Optional login background (if the flow uses a background image), **1920 × 1080**:

```
[shared style block]

Composition: the sphere is small, about 22% of the frame height, placed at the
lower-left third; the rest of the frame is near-black #020309 with the sphere's
bloom fading across it very softly. The right two-thirds of the frame are empty
and very dark so a login card can sit on top. Wide 16:9 canvas.
```

---

## 4. README hero

### 4a. Wide banner

Size: **1600 × 600** (8:3), PNG.

```
[shared style block]

Composition: the sphere is on the left third of the canvas, its diameter about 60%
of the canvas height, with the hairline ring. The remaining right two-thirds of
the canvas is empty near-black #020309 with only a faint trace of the green bloom
reaching into it. Very subtle, barely visible fine horizontal grain across the
whole background, like a dark OLED surface. Wide 8:3 canvas.
```

Add the wordmark ("Orbital P.A.I" + a one-line tagline) in post on the right side,
same typography as 3a. Leaving the text out of the generation is intentional.

### 4b. Social / OpenGraph card

Size: **1200 × 630**. Same prompt as 4a with "Wide 8:3 canvas" replaced by
"Landscape 1.9:1 canvas", sphere diameter about 70% of the canvas height.

---

## 5. Hand-back: what integration needs from you

Deliver PNGs at the master sizes above; resizing is done on the integration side.

| Target | Source | Sizes produced during integration |
|---|---|---|
| Android launcher (`native/android/.../mipmap-*`) | 1a + 1b | mdpi 48 → xxxhdpi 192, plus adaptive fg/bg 108 dp layers, via `flutter_launcher_icons` |
| macOS / Windows launcher (not scaffolded yet) | 1a | `.icns` set 16–1024 / `.ico` 16–256 when those targets are added |
| Web favicon (`server/priv/static/favicon.ico`, `images/favicon.svg`) | 2 | 16, 32, 48 in the `.ico`; SVG if traced |
| PWA icons (`images/icon-192.png`, `icon-512.png`, `apple-touch-icon.png`, `manifest.webmanifest`) | 1a | 192, 512, 180 |
| Authentik logo / favicon / CSS | 3a, 2, 3c | as delivered |
| README hero (`docs/brand/hero.png`) + OG image | 4a, 4b | as delivered, wordmark added in post |

## 6. Delivered candidates (2026-09-12)

Originals as downloaded live in `raw/` (q100 JPEGs, ~2 MB total). Processed with
ImageMagick into:

| File | From | Notes |
|---|---|---|
| `icon-1a.jpg` | full_app_icon | 1024², q88. PNG master is derived at integration time. |
| `orb-transparent.png` | icon-1a | the orb cut out on real alpha (black-to-alpha, unpremultiplied) |
| `authentik-logo-3a.png` | orb-transparent + Space Grotesk | 2064×512, real alpha. Gemini's "transparent" logo had a painted checkerboard (JPEG has no alpha), so the wordmark was set in post. |
| `authentik-logo-3a-preview.jpg` | same, flattened on `#07080F` | for eyeballing only |
| `authentik-login-bg-3c.jpg` | Authentik_Horizontal_Logo_optional | 1376×768, q85 |
| `hero-4a.jpg` | readme_banner | 1696×624, q85; wordmark still to add |
| `social-4b.jpg` | social_media_banner | 1024², q85. Came back square and busy (extra diagrams, "TRANSMISSION STATUS"); not a usable OG card, regenerate with 4b if wanted. |

No adaptive-icon foreground (1b) or favicon source (2) yet; both derive from `icon-1a` at
integration if not generated separately.

## 7. Authentik branding (applied 2026-09-14)

`authentik/custom.css` + `authentik/apply.sh` (needs `AUTHENTIK_API_KEY`; `--css-only` skips
the image URLs). `brand-before.json` is the pre-change snapshot for rollback. The images live
in `server/priv/static/images/brand/` and are uploaded into Authentik's own media store by
the script (`POST /admin/file/`); the brand fields hold the bare filename. The login
background is recomposed by ImageMagick onto a 2560×1440 canvas with the orb at the far
left, so `background-size: cover` keeps it clear of the card.
`login-branded.jpg` is the finished login page.
