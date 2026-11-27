# Home-screen widgets: `*.gitsidian.widget`

Any file in a vault whose name ends in **`.gitsidian.widget`** can be shown on the
iPhone Home Screen. Add the **Vault widget** from the widget gallery, long-press it,
**Edit Widget**, and pick the file. Each widget instance shows only the file it was
given, so a Smart Stack can hold several. A widget with no file picked shows the only
widget file if there is exactly one, otherwise it asks you to choose.

**Lock Screen** widgets are a separate file type, `*.gitsidian.lock`, with their own API made
for the tiny space (rings, gauges, live countdowns, custom SVG) and a previewer for agents.
See [`lockscreen.md`](lockscreen.md).

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
gitsidian.tasks(markdown)           -> [{text, checked}] from "- [ ] text" / "- [x] text" lines
gitsidian.family                    -> "small" | "medium" | "large" | "extraLarge" | "app" (in-app preview)
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
Container.checkbox(text, {checked, detail, note})   tappable task; see "Checkboxes" below
Container.checklist(tasks, {note})  a column of checkboxes. tasks: a markdown string of "- [ ] …"
                                    lines, or [{text, checked, detail, note}]
Container.spacer()
```

Canvas subset: `fillStyle strokeStyle lineWidth font globalAlpha textAlign fillRect
strokeRect clearRect beginPath moveTo lineTo arc closePath fill stroke fillText save
restore translate scale rotate roundRect createLinearGradient/addColorStop`.

### Limits

No network, timers, `fetch` or file access: the data is in the file. 2 s run time,
~30 MB memory. Script errors show as text in the widget and in the in-app preview.
Typical sizes: small 170×170 pt, medium 364×170, large 364×382 (minus 12 pt padding).

## Checkboxes

Checkboxes tick off tasks from the Home Screen without opening the app. Each one is
bound to a **markdown task line** (`- [ ] text`) in a vault file, matched by its text.
Tapping it flips that line's `[ ]` / `[x]`, and the widget commits the change to GitHub
itself ("Check off "Book flights" from widget"). Nothing else in the file is touched.

**Tasks kept in the widget file.** Write them as markdown inside a template string. A tap
rewrites the line right there, so the next run of the script sees the new state:

```js
const w = gitsidian.widget();
const p = w.page();
p.text("Today", { font: "headline" });
p.checklist(`
- [ ] Reply to Sam
- [x] Book flights
- [ ] Call the bank
`);
```

`gitsidian.tasks(md)` parses the same lines into `[{text, checked}]` if you want to count
or filter them first (`tasks.filter(t => !t.checked).length + " left"`).

**Tasks kept in a note.** Pass `note` and the tap edits that note instead. The script
has no file access, so it can't read the note; whoever writes the widget (usually an
agent) copies each task's text and state in. The widget remembers your tap until the
widget file is next rewritten.

```js
p.checkbox("Renew passport", { checked: false, note: "/Projects/Admin.md", detail: "Fri" });
p.checklist([{ text: "Water plants", checked: true }, { text: "Bins out" }], { note: "Home" });
```

Rules:
- `note` follows `gitsidian.note()` paths (`/x` from the vault root, otherwise relative to
  the widget file), but it must name the file: a name without an extension gets `.md`;
  it isn't searched for like a `[[link]]`. Leave `note` out for the widget file itself.
- Bullets `-`, `*`, `+` and `1.` all work. Matching ignores surrounding spaces. If two
  lines have the same text, the first one not already in the new state changes.
- In the widget file, keep each task on its own line, and don't build its text with
  `${…}`: the text in the file must equal the text shown.
- If the line was edited or removed elsewhere, the tap is dropped and the widget shows
  the script's value again. Taps made offline are kept and committed on the next refresh.
- In the app's preview, ticking edits the local file and the usual sync pushes it.

## How it updates

- **In the app**, opening a widget file shows a live preview at small, medium and
  large sizes, plus a Code tab. **New widget** (file menu or ⋯) writes a starter file.
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
