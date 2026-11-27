# Lock Screen widgets: `*.gitsidian.lock` (for agents and people)

A Lock Screen widget is a separate file from a Home Screen widget. **Publish = commit
`<Name>.gitsidian.lock` to the vault repo's synced branch and push.** The user adds the
**Lock Screen widget** (long-press the Lock Screen › Customize › Lock Screen › tap the
widget area › Gitsidian) and picks the file. It refreshes from GitHub like Home Screen widgets.

The Lock Screen is tiny, monochrome and glanced at for under a second. Nothing is shrunk
from a bigger layout: you design each of the three sizes on purpose, using building blocks
made for that space, or your own SVG.

## The three sizes

| Size | Space (pt) | Where | What it's good for |
|---|---|---|---|
| `circular` | 76 × 76 circle | below the clock | one number, one ring, one symbol, one tiny drawing |
| `rectangular` | ~172 × 76 (160 × 72 on smaller phones) | below the clock | a title + 2 lines, or a strip of data, or one custom drawing |
| `inline` | one line, ~25 characters | above the clock, next to the date | a single short fact |

Everything is drawn **in one tint by brightness**: white is full strength, `#ffffff80`
is half, black is invisible. Colors are thrown away. There is **no tapping on parts** of
the widget: a tap anywhere opens the `.lock` file in Gitsidian, so there are no buttons.

## The file

Plain JavaScript (same sandbox as `.gitsidian.widget`: no network, timers or file access,
2 s, bake data in at write time).

```js
const lock = gitsidian.lockScreen();

lock.circular(c => c.ring(6200, { max: 10000, center: "6.2k", symbol: "figure.walk" }));

lock.rectangular(r => {
  r.title("Inbox", { symbol: "tray" });
  r.line("Reply to Sam", { trailing: "2 pm" });
  r.bar(3, { max: 8, label: "3 of 8 done" });
});

lock.inline(i => i.text("3 due · Reply to Sam", { symbol: "checklist" }));

lock.refreshAfter(30);
```

Define all three. A size you leave out shows "No … layout" if the user adds it.
The script runs once per size with `gitsidian.family` set (`"rectangular"`, `"circular"` or
`"inline"`), so you can also compute things only for the size being drawn.

## API

### `lock.circular(c => …)`: exactly one of

| Call | Draws |
|---|---|
| `c.ring(value, {min, max, center, symbol, label})` | closed ring that fills; `center` text and/or `symbol` inside, small `label` under it |
| `c.gauge(value, {min, max, center, symbol, minLabel, maxLabel})` | open arc (like a speedometer) with end labels |
| `c.timeRing(start, end, {center, symbol})` | ring that **fills live** from `start` to `end` (meeting, timer, sleep) |
| `c.number(text, {caption, symbol})` | one big number or short word, with a tiny caption |
| `c.symbol(sfSymbol, {caption})` | one SF Symbol, big |
| `c.countdown(date, {caption})` | live `12:34` countdown |
| `c.svg(markup)` | **your own drawing**, scaled to fill the circle |
| `c.canvas(ctx => …)` | Canvas 2D drawing on 76 × 76 (same subset as Home Screen widgets) |

Defaults: `min` 0, `max` 1. Ring/gauge/timeRing draw their own track; everything else sits on
the standard round backdrop.

### `lock.rectangular(r => …)`: up to 3 rows, top to bottom

| Call | Row |
|---|---|
| `r.title(text, {symbol})` | bold headline, accented |
| `r.line(text, {symbol, trailing, mono})` | body text, optional dim right-hand text |
| `r.bar(value, {min, max, label, minLabel, maxLabel})` | linear progress bar, label above |
| `r.timeBar(start, end, {label})` | bar that **fills live** between two dates |
| `r.countdown(date, {label})` | label left, live `12:34` right |
| `r.relative(date, {label})` | label left, "in 2 hr" / "5 min ago" right (minute precision) |
| `r.sparkline([numbers], {type})` | tiny chart, `type`: `line` (default), `area`, `bar`; fills the rows left |
| `r.svg(markup, {height})` | **your own drawing**. As the first row it fills the whole widget (172 × 76); later rows default to 24 pt tall |
| `r.canvas(ctx => …, {height})` | Canvas 2D, same sizing as `svg` |

A 4th row is an error, on purpose. Pick what matters.

### `lock.inline(i => …)`: one of

| Call | Line |
|---|---|
| `i.text(text, {symbol})` | text with an optional leading SF Symbol |
| `i.countdown(date, {text, symbol})` | `text` then a live `12:34` |
| `i.relative(date, {text, symbol})` | `text` then "in 2 hr" |

iOS shows one symbol and one line of text there and cuts the rest. Keep it under ~25 characters.

`lock.refreshAfter(minutes)`: 5–1440, iOS may stretch it. Dates are ISO strings or `Date`.
Symbols are [SF Symbols](https://developer.apple.com/sf-symbols/) names (`flame`, `drop.fill`,
`figure.run`, `checklist`, `calendar`, `bolt.fill`, `moon.stars`…). An unknown name draws nothing.

## Custom SVG

`c.svg()` and `r.svg()` take SVG markup, rendered natively on the phone when the script runs.

```js
// A 7-day streak strip: filled dot = done that day.
const days = [1, 1, 0, 1, 1, 1, 0];
r.svg(`<svg viewBox="0 0 154 18">${days.map((d, i) =>
  `<circle cx="${8 + i * 22}" cy="9" r="6" ${d ? "" : 'fill="none" stroke="white" stroke-width="1.5" opacity="0.5"'}/>`
).join("")}</svg>`, { height: 18 });
```

- **Design on the real size**: `viewBox="0 0 76 76"` for circular, `0 0 172 76` for a full
  rectangular widget, `0 0 172 24` for a row. Other viewBoxes are scaled to fit (centred).
- **Default fill is white** (not black as in browsers), and `currentColor` is white. Use
  `opacity` / `fill-opacity` / `#ffffff66` for lighter shades. Never black: it disappears.
- Supported: `svg g path rect circle ellipse line polyline polygon text tspan`, every path
  command including arcs, `transform`, `fill stroke stroke-width opacity fill-opacity
  stroke-opacity fill-rule stroke-linecap stroke-linejoin stroke-dasharray stroke-dashoffset
  font-size font-weight font-family text-anchor display visibility`, and the same in `style="…"`.
- **Not supported** (skipped): gradients, patterns, masks, clip paths, filters, `<use>`,
  `<image>`, `<style>` sheets, `textPath`, markers. Fake a gradient with a few opacity bands.
- Text in SVG uses the system font. Under 9 pt is unreadable on a Lock Screen.
- Max 256 KB and 5,000 elements. Errors (bad XML) show in the widget with the line number.

## Designing for the Lock Screen

The user looks for one second. Ask: **what is the one thing they want to know without
unlocking?** Then pick the size that says it best, and make the other two say the same thing
at their own scale (inline = the sentence, circular = the number, rectangular = the number
with its context).

Patterns that work:

- **Progress toward a goal** → circular `ring` with the count in the center; rectangular
  title + `bar`; inline "6.2k / 10k steps".
- **Next event** → circular `timeRing(start, end)` or `countdown`; rectangular title (what),
  `line` (where, trailing time), `timeBar`; inline `relative(date, {text: "Standup"})`.
- **A streak or a week** → rectangular `svg` dot strip or bar chart; circular `number` with
  `caption: "day streak"`.
- **A trend** → rectangular title + `sparkline`; circular `gauge` with `minLabel`/`maxLabel`.
- **A state** (on/off, mood, weather-like) → circular `symbol` or an SVG icon; inline symbol + word.
- **Something richer** (a mini calendar, a habit grid, a clock face, a map of a week) →
  one full-size `r.svg()` or `c.svg()`. This is where you can be inventive: dot matrices,
  radial charts, tally marks, tiny bar charts with labels, progress arcs split into segments.

Rules of thumb:

- One idea per widget. If you need a sentence to explain it, it's too much.
- Numbers short: `6.2k` not `6,213`; `3h` not `3 hours`. Words short: `Fri` not `Friday`.
- Contrast by brightness only: full white for the main thing, 40–60 % for context.
- Leave space. A 76 pt circle with one bold number reads better than three small ones.
- Don't show "updated 5 min ago" or a seconds counter unless it's a countdown worth watching.
- Never invent data. If it's stale, say less rather than something wrong.

## Preview before you commit

**In this repo** there's a previewer that runs the file exactly as the app does (same API,
same errors) and draws it at real point sizes on a mock Lock Screen, in one tint, plus 3x zooms:

```sh
node tools/lock-preview.mjs Focus.gitsidian.lock --out /tmp/focus.html --png /tmp/focus.png
```

- `--png` needs Playwright (`require("playwright")`); without it, open the HTML in any browser,
  or `npx playwright screenshot --full-page file:///tmp/focus.html /tmp/focus.png`.
- **Look at the PNG** (an agent can read images). Check: is the one idea obvious at actual
  size? Is anything cut off? Does the SVG read in one tint?
- The previewer also prints: script errors (with line numbers), text that's cut off, SVG
  features the phone skips, black fills, and every SF Symbol name used (drawn as labelled
  boxes, since browsers can't draw SF Symbols: check the names exist).
- `--json` prints what each size built, for a quick check without a browser.
- Write the preview files outside the vault (e.g. `/tmp`), so they don't get committed.

The previewer is close but approximate (browser fonts, symbol placeholders). **The app's own
preview is exact**: open the `.lock` file in Gitsidian to see all three sizes rendered natively.

## Checklist

1. Fetch real data. Decide the one thing the widget says.
2. Write `<Name>.gitsidian.lock` with all three sizes.
3. Run the previewer, look at the PNG, fix anything cut off or unclear. Repeat.
4. Commit and push to the branch the vault syncs. Keep the same path when updating, because
   the user picked the widget by its path.
5. Report the path and what each size shows.
