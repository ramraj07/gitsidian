# Home-screen widgets: `*.gitsidian.widget`

Any file in a vault whose name ends in **`.gitsidian.widget`** can be shown on the
iPhone Home Screen. Add the **Vault widget** from the widget gallery, long-press it,
**Edit Widget**, and pick the file. Each widget instance shows only the file it was
given, so a Smart Stack can hold several. A widget with no file picked shows the only
widget file if there is exactly one, otherwise it asks you to choose.

The same widget is also offered on the **Lock Screen** (rectangular, circular and
inline). See [Lock Screen](#lock-screen) for how one file renders a compact layout.

## The format

The file is a **JavaScript program**. It builds the widget through a small runtime
API, and the widget renders the result natively in SwiftUI. Nothing is parsed as HTML.
It's the same runtime and API (v1) as [Kondai](https://github.com/ramraj07/kondai)
widgets, so a Kondai script works here unchanged (`kondai.widget()` is an alias).

Why a program and not JSON or YAML: WidgetKit can't scroll, host a web view, or run
code between refreshes. A script lets one file have pages, live timers, charts,
canvas drawings and buttons, and still render as plain SwiftUI. An agent (or a CI
job, or you) rewrites the file with fresh data and commits it.

```js
const w = gitsidian.widget();
const p = w.page();
p.row(r => { r.text("Inbox", { font: "headline" }); r.spacer(); r.text("3", { font: "title", color: "#7c5cff" }); });
p.list([
  { title: "Reply to Sam", detail: "today", url: gitsidian.note("Inbox/Sam") },
  { title: "Book flights", detail: "Fri" },
]);
p.spacer();
p.button("Open inbox", gitsidian.note("/Inbox.md"));
w.refreshAfter(60);
```

### Runtime API

```
gitsidian.widget()                  -> Widget        (alias: kondai.widget())
gitsidian.note(path)                -> "gitsidian://open?…" URL that opens a vault file in the app.
                                       "/x/y" is vault-absolute; anything else is relative to the
                                       widget file's folder. Note names without .md resolve like [[links]].
                                       "Note#Heading" / "Note#^block-id" open scrolled to that section.
gitsidian.family                    -> "small" | "medium" | "large" | "extraLarge" | "app" (in-app preview)
                                       Lock Screen: "rectangular" | "circular" | "inline"
gitsidian.path / .repo / .branch    -> where this file lives

Widget.page()                       -> Page   pages are 1..n; >1 page adds a ‹ n/N › pager
Widget.fullView(html)                         shown in the app's preview ("Full view"), scrollable
Widget.refreshAfter(minutes)                  next run hint, clamped 5..1440 (iOS budgets ~40–70/day)

Every node method appends to its container and returns the node.
Container.row(fn) / Container.column(fn)
Container.text(str, {font, color, align, lines})
    font: largeTitle | title | headline | body | caption | mono      color: "#rrggbb[aa]"
    align: leading | center | trailing                                lines: 0 = unlimited
Container.image(base64OrDataURL, {width, height, corner})
Container.canvas(w, h, ctx => …)    Canvas 2D subset, rendered at 3x
Container.relativeDate(date)        "5 min ago" / "in 2 hr", minute granularity (live on iOS 18)
Container.timer(date)               live seconds counter; use only for countdowns worth watching
Container.progress(start, end)      live bar between two dates
Container.gauge(value, {min, max, label})
Container.list([{title, detail, url}])        rows with url are tappable
Container.chart({type: "bar"|"line"|"area", data: [{x, y}], color})
Container.button(label, url)        opens any URL scheme (gitsidian.note(), https, maps://, shortcuts://…); Gitsidian flashes briefly
Container.button(label, {page: n})  switches page in place, no app launch
Container.spacer()
```

Canvas subset: `fillStyle strokeStyle lineWidth font globalAlpha textAlign fillRect
strokeRect clearRect beginPath moveTo lineTo arc closePath fill stroke fillText save
restore translate scale rotate roundRect createLinearGradient/addColorStop`.

### Limits

No network, timers, `fetch` or file access: the data is in the file. 2 s run time,
~30 MB memory. Script errors show as text in the widget and in the in-app preview.
Typical sizes: small 170×170 pt, medium 364×170, large 364×382 (minus 12 pt padding).
Lock Screen: rectangular about 160×72 (172×76 on Max phones), circular 76×76, inline one line.

## Lock Screen

One `.gitsidian.widget` file serves the Home Screen and the Lock Screen. Branch on
`gitsidian.family` and build a small layout when it is `rectangular`, `circular` or
`inline`:

```js
const w = gitsidian.widget();
const p = w.page();
switch (gitsidian.family) {
  case "inline":      p.text("3 tasks · next: Reply to Sam"); break;
  case "circular":    p.gauge(3, { min: 0, max: 10, label: "tasks" }); break;
  case "rectangular": p.text("Inbox", { font: "headline" }); p.text("Reply to Sam", { lines: 1 }); p.text("Book flights", { lines: 1 }); break;
  default:            /* the Home Screen layout */
}
```

How the Lock Screen renders a page:

- **Only page 1 is shown**, and there is no pager.
- **Buttons, page buttons and list-row links are left out.** The Lock Screen only takes a tap on
  the whole widget, which opens the file in Gitsidian.
- Type is a step smaller (`largeTitle` and `title` shrink, `body` stays), charts lose their axis
  labels, and canvases and images shrink to fit.
- **circular** centres the page; a single `gauge` fills it as a ring.
- **inline** is one line of text: the page's texts, the first list row, gauges and dates are joined
  with ` · `. Images, canvases and charts are skipped.
- iOS draws Lock Screen widgets in one tint, so colours become shades of the same colour.

A file that doesn't branch on the family still works: its first page is shown compactly and
clipped. The in-app preview shows all three Lock Screen sizes under the Home Screen ones.

## How it updates

- **In the app**, opening a widget file shows a live preview at small, medium and
  large sizes and the three Lock Screen sizes, plus a Code tab. **New widget** (file menu or ⋯) writes a starter file.
- The app copies every widget file it sees into the App Group, with the git blob sha
  of the GitHub version it's based on, and reloads the widgets when they change.
- **The widget fetches the file from GitHub itself** on every timeline refresh
  (contents API, using the same token). If GitHub's sha differs from the cached one,
  the new version wins. So a commit from an agent or your laptop shows up without
  opening the app; unpushed edits made on the phone are shown until GitHub moves.
- Tapping the widget opens the file in Gitsidian.
- Buttons and list rows with a `url` can open other apps (`maps://`, `tel:`, `shortcuts://run-shortcut?name=…`,
  `https://…`, any installed app's scheme). Widget taps always arrive in Gitsidian first, and it passes
  non-Gitsidian URLs on to iOS, so the app flashes briefly before the target opens.
