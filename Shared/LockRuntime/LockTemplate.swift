import Foundation

enum LockTemplate {
    /// What "New Lock Screen widget" writes: one layout per size, including a custom SVG.
    static func starter(title: String) -> String {
        let t = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        // \(t) — a Gitsidian Lock Screen widget.
        // JavaScript, like a .gitsidian.widget file, but with an API made for the Lock Screen's tiny
        // space. Design each size on purpose; nothing is shrunk for you. Guide: docs/lockscreen.md
        //
        //   const lock = gitsidian.lockScreen();
        //   lock.circular(c => …)     76×76 pt, ONE of:
        //     c.ring(v, {min, max, center, symbol, label})   closed ring that fills
        //     c.gauge(v, {min, max, center, symbol, minLabel, maxLabel})   open arc
        //     c.timeRing(start, end, {center, symbol})       fills live between two dates
        //     c.number(text, {caption, symbol})  c.symbol(sfSymbol, {caption})  c.countdown(date, {caption})
        //     c.svg(markup)  c.canvas(ctx => …)              your own drawing, fills the circle
        //   lock.rectangular(r => …)  ~172×76 pt, up to 3 rows:
        //     r.title(text, {symbol})  r.line(text, {symbol, trailing, mono})
        //     r.bar(v, {min, max, label})  r.timeBar(start, end, {label})
        //     r.countdown(date, {label})  r.relative(date, {label})  r.sparkline([numbers], {type})
        //     r.svg(markup, {height})  r.canvas(ctx => …, {height})   first one alone = whole widget
        //   lock.inline(i => …)       one line above the clock: i.text(text, {symbol}),
        //                             i.countdown(date, {text, symbol}), i.relative(date, {text, symbol})
        //   lock.refreshAfter(minutes)
        //
        // The Lock Screen draws everything in one tint by brightness: use white, with opacity for
        // lighter shades. In SVG the default fill is white. Symbols are SF Symbol names.
        // Preview: open this file in Gitsidian, or run `node tools/lock-preview.mjs <file> --png out.png`.

        const lock = gitsidian.lockScreen();

        // Bake real data in when you write the file.
        const done = 23, goal = 30;
        const week = [1, 1, 0, 1, 1, 0, 1];   // wrote a note that day?

        lock.circular((c) => c.ring(done, { max: goal, center: String(done), label: "notes" }));

        lock.rectangular((r) => {
          r.title("\(t)", { symbol: "flame" });
          r.line("Write the summary", { trailing: "Fri" });
          // A custom drawing: one dot per day, filled when a note was written.
          const dots = week.map((d, i) =>
            `<circle cx="${8 + i * 22}" cy="9" r="6" ${d ? "" : 'fill="none" stroke="white" stroke-width="1.5" opacity="0.6"'}/>`
          ).join("");
          r.svg(`<svg viewBox="0 0 154 18">${dots}</svg>`, { height: 18 });
        });

        lock.inline((i) => i.text(done + "/" + goal + " notes this week", { symbol: "flame" }));

        lock.refreshAfter(60);

        """
    }
}
