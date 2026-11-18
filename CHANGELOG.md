# Changelog

All notable changes to **Lunar** are documented in this file.

## [0.1.1] - 2026-11-18

### 2D Grapher
- **Interactive parameter sliders:** Undefined coefficients like `a` or `m` automatically generate live sliders with an inline `⋯` settings menu (`Natural`, `Integers`, `Step 2`, custom `Step`, and `Range` bounds).
- **2D inequalities & domain restrictions:** Plot shaded regions (`y <= x + 2`, `x^2 + y^2 < 9`, or word forms like `leq`, `less than`) with solid/dashed boundaries, and restrict curves or inequalities with `{...}` intervals (e.g. `y = x^2 {-2 <= x <= 2}`).
- **Root & intersection snapping:** Hover or click intercepts, curve-to-axis intersections, and multi-curve intersection points to pin exact coordinates on the canvas.
- **Function & symbol palette (`ƒx`):** Open the zero-lag palette on the top-right graph bar to insert constants (`π`, `e`, `φ`), inequalities, domain blocks, powers/roots (`|x|`, `ⁿ√`), logarithms (`ln`, `log₁₀`, `log_b(x)`), and trig/hyperbolic functions directly at the cursor.
- **Subscript & superscript formatting:** `^` powers and `log_b(x)` subscript bases render visually inline while keeping plain-text math copyable.
- **Region selection & PNG/JPEG export:** Click `Select` to drag a crop box (`Esc` clears/unlocks), `Copy` to place crisp high-DPI PNG images on the clipboard, or `Export` to save PNG/JPEG files.
- **Smoother equation editing:** Debounced equation parsing prevents slider re-layout lag while typing fast.

### Study, Cards & Backups
- **Study Undo (`⌘Z`):** Step backward through SM-2 ratings and Gauntlet survival turns without losing card history, including from the session-complete screen.
- **Full SQLite backup & Anki `.apkg` import:** Export and restore complete `.db` snapshots (`merge` or `replace` mode) and import standard `.apkg` decks from Settings -> Backup & Restore.
- **Interleaved card attachments:** Paste multiple clipboard images inline alongside text and LaTeX (`Image 1`, `Image 2`, ...), preserve exact visual order across preview/save, and fix editor preview layout jitter.

---

## [0.1.0] - 2026-11-16

Initial public macOS release of Lunar: local-first spaced-repetition flashcards (`Today`, `Library`, `Deck`, `Gauntlet`, `Analytics`), progressive step hints, offline KaTeX LaTeX rendering, foundational 2D grapher + CAS (`diff`, `integrate`, `solve`), and a menu-bar Pomodoro timer backed by the `lunar-core` Go SQLite daemon.
