# brand — Dikta visual identity

Brand assets for Dikta: the logo mark, the Ink badge, and the palette. These are *collateral* for docs, website, and social — the live menubar icon is rendered in code via `hs.canvas` (see the [branding plan][branding-plan] § D4), **not** loaded from these files. The identity rationale and the locked name decision live in that plan.

## Files

- `dikta-mark.svg` / `dikta-mark.png` — the spoken-mark: a filled voice-dot resolving into two text-strokes. Monochrome, transparent background. The canonical mark.
- `dikta-badge.svg` / `dikta-badge.png` — the mark in Paper on an Ink rounded-rect badge, same tight framing as the mark.

The SVGs are the source of truth; the PNGs are rendered from them — see [Regenerating the PNGs][regen].

## Palette

Docs and website only — never the menubar glyph, which is a monochrome template that discards color.

| Token | Hex | Use |
|-------|-----|-----|
| Ink | `#16161D` | Near-black; primary mark on light backgrounds, badge background. |
| Paper | `#F7F5F0` | Warm off-white; background, mark on Ink. |
| Signal | `#E5484D` | Restrained red; the recording state in docs and marketing. |
| Aegean | `#2D7FF9` | Cool accent for links and CTAs. No flag or nationality cues — the brand is language-agnostic. |

## Regenerating the PNGs

<a id="regen"></a>

The PNGs are produced from the SVGs with [librsvg][librsvg]'s `rsvg-convert` (`brew install librsvg`). `qlmanage` and `sips` are not suitable — they pad non-square art to a square and drop transparency.

```bash
rsvg-convert -w 1400 -h 600 dikta-mark.svg  -o dikta-mark.png
rsvg-convert -w 1400 -h 600 dikta-badge.svg -o dikta-badge.png
```

[branding-plan]: ../engineering/plans/2026-05-26-branding-identity.md
[librsvg]: https://gitlab.gnome.org/GNOME/librsvg
[regen]: #regen
