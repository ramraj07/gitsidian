# Publishing a Gitsidian widget (for agents)

**Publish = commit a file named `<Name>.gitsidian.widget` to the vault repo's synced branch and push.**
The phone's widget fetches it from GitHub on its next refresh (≈every `refreshAfter` minutes, iOS-throttled). To update it, overwrite the whole file and commit again. Keep the same path, because the user picked the widget by its path.

## The file
Plain JavaScript (ES2020). No imports, network, `fetch`, timers or file access. **Bake all data in at write time.** Limits: 2 s run, ~30 MB, keep under 512 KB.

```js
const w = gitsidian.widget();                 // once
const p = w.page();                           // pages 1..n; >1 page adds a ‹ n/N › pager
p.row(r => { r.text("Title", {font: "headline"}); r.spacer(); r.text("42", {font: "title", color: "#34c759"}); });
p.list([{title: "Item", detail: "today", url: gitsidian.note("Inbox")}]);
p.spacer();
p.button("Open", gitsidian.note("/Projects/Plan.md"));
w.refreshAfter(60);
```

## API
| Call | Notes |
|---|---|
| `w.page()` | new page |
| `w.refreshAfter(min)` | 5–1440 |
| `w.fullView(html)` | scrollable HTML shown in the app |
| `.row(fn)` `.column(fn)` | `fn(container)`; containers have every method below |
| `.text(s, {font, color, align, lines})` | font: `largeTitle title headline body caption mono`; color `#rrggbb[aa]`; align `leading center trailing` |
| `.list([{title, detail, url}])` | ≤50 rows; `url` makes the row tappable |
| `.chart({type, data:[{x,y}], color})` | type: `bar line area` |
| `.gauge(v, {min, max, label})` | default 0..1 |
| `.progress(start, end)` `.timer(date)` `.relativeDate(date)` | live; ISO string or `Date` |
| `.canvas(w, h, ctx => …)` | Canvas2D subset: fill/stroke styles, rects, paths, `arc`, `roundRect`, `fillText`, transforms, `createLinearGradient` |
| `.image(base64 or dataURL, {width, height, corner})` | |
| `.button(label, url)` / `.button(label, {page: n})` | any URL scheme / switch page in place |
| `.spacer()` | |
| `gitsidian.note(path)` | URL that opens a vault file. `/x` = from the vault root, otherwise relative to this file. A name without `.md` resolves like `[[links]]`. |
| `gitsidian.family` | `small medium large extraLarge app`; branch on it |
| `gitsidian.path` `.repo` `.branch` | |

`kondai.widget()` is an alias. Kondai scripts work unchanged.

## Layout rules
- Sizes (pt, before 12 pt padding): small 170×170, medium 364×170, large 364×382. **No scrolling.** Overflow gets clipped, so paginate.
- Shape: header row → content → `spacer()` → buttons. Medium has room for ~4 list rows; large ~10.
- Keep canvas width ≤ 300 (≤ 140 on small). Use `lines: 1` on text that could wrap.
- Use `relativeDate`/`timer`/`progress` for anything time-based, because baked text goes stale.

## Checklist
1. Fetch real data first; never invent numbers.
2. Write the file, then sanity-run it: `node -e` with a stub `gitsidian` object, or just check syntax with `node --check`.
3. Commit with a clear message and push to the branch the vault syncs.
4. Report the path, what each page shows, and what will go stale.

Errors appear as text in the widget, with the line number.
