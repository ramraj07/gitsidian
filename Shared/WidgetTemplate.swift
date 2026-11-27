import Foundation

enum WidgetTemplate {
    /// What "New widget" writes: a two-page example that touches most of the API.
    static func starter(title: String) -> String {
        let t = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        // \(t) — a Gitsidian home-screen widget.
        // This file is JavaScript: it builds the widget with the runtime API below, then
        // the widget renders it natively. No network or timers; put the data in this file
        // (an agent or a script can rewrite it and commit). Same API as Kondai widgets.
        //
        //   gitsidian.widget()                 -> w      (`kondai.widget()` works too)
        //   w.page()                           -> page   (pages 1..n; a pager appears; or button(label, {page: n}))
        //   w.refreshAfter(minutes)  w.fullView(html)
        //   page.text(s, {font, color, align, lines})   font: largeTitle|title|headline|body|caption|mono
        //   page.row(r => …)  page.column(c => …)  page.spacer()
        //   page.list([{title, detail, url}])  page.chart({type: "bar"|"line"|"area", data: [{x, y}], color})
        //   page.gauge(v, {min, max, label})  page.progress(start, end)  page.timer(date)  page.relativeDate(date)
        //   (timer/progress tick live: only for countdowns worth watching. relativeDate = "5 min ago")
        //   page.canvas(w, h, ctx => …)        Canvas 2D subset
        //   page.image(base64OrDataURL, {width, height, corner})
        //   page.button(label, url | {page: n})   url can open other apps: maps://?q=…, tel:…, https://…,
        //                                      shortcuts://run-shortcut?name=…, spotify:…, any app's URL scheme
        //   gitsidian.note("Some note")        -> URL that opens a note in Gitsidian
        //   gitsidian.note("Note#Heading")     -> …scrolled to a section ("Note#^block-id" for a ^block-id line)
        //   gitsidian.family                   -> "small" | "medium" | "large" | "extraLarge" | "app"
        //   gitsidian.path / .repo / .branch

        const w = gitsidian.widget();
        const big = gitsidian.family === "large" || gitsidian.family === "extraLarge";

        const week = [
          { x: "Mon", y: 3 }, { x: "Tue", y: 5 }, { x: "Wed", y: 2 },
          { x: "Thu", y: 6 }, { x: "Fri", y: 4 }, { x: "Sat", y: 1 }, { x: "Sun", y: 2 },
        ];
        const done = week.reduce((s, d) => s + d.y, 0);
        const goal = 30;

        // Page 1: headline number, ring and a chart.
        const p1 = w.page();
        p1.row((r) => {
          r.text("\(t)", { font: "headline", lines: 1 });
        });
        p1.row((r) => {
          r.canvas(64, 64, (ctx) => {
            const frac = Math.min(done / goal, 1);
            ctx.lineWidth = 8;
            ctx.strokeStyle = "#8e8e9340";
            ctx.beginPath(); ctx.arc(32, 32, 26, 0, Math.PI * 2); ctx.stroke();
            ctx.strokeStyle = "#7c5cff";
            ctx.beginPath(); ctx.arc(32, 32, 26, -Math.PI / 2, -Math.PI / 2 + frac * Math.PI * 2); ctx.stroke();
            ctx.fillStyle = "#7c5cff";
            ctx.font = "bold 15px sans-serif";
            ctx.textAlign = "center";
            ctx.fillText(Math.round(frac * 100) + "%", 32, 37);
          });
          r.column((c) => {
            c.text(done + " / " + goal, { font: "title" });
            c.text("notes written this week", { font: "caption", color: "#8e8e93" });
          });
        });
        if (big) p1.chart({ type: "bar", data: week, color: "#7c5cff" });
        p1.spacer();
        p1.button("Open note", gitsidian.note("README"));

        // Page 2: a list of tappable notes.
        const p2 = w.page();
        p2.text("Up next", { font: "headline" });
        p2.list([
          { title: "🟣 Plan the week", detail: "Mon", url: gitsidian.note("README") },
          { title: "🟢 Review inbox", detail: "Today" },
          { title: "🔵 Write the summary", detail: "Fri" },
        ]);
        p2.spacer();
        p2.text("More than one page adds a ‹ 1/2 › pager at the bottom.", { font: "caption", color: "#8e8e93", lines: 1 });

        w.refreshAfter(60);

        """
    }
}
