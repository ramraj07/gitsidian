import SwiftUI
import Charts
import WidgetKit

/// Renders one Lock Screen size of a `LockProgram`. The widget adds `AccessoryWidgetBackground`
/// behind circular faces that want it (`LockFace.wantsBackground`); the app's preview draws its own.
struct LockProgramView: View {
    let program: LockProgram
    let family: LockFamily

    init(program: LockProgram, family: LockFamily) {
        self.program = program
        self.family = family
    }

    var body: some View {
        switch family {
        case .circular:
            if let face = program.circular { LockFaceView(face: face) } else { missing }
        case .rectangular:
            if let rows = program.rectangular, !rows.isEmpty { LockRowsView(rows: rows) } else { missing }
        case .inline:
            if let line = program.inline { LockInlineView(line: line) } else { missing }
        }
    }

    @ViewBuilder private var missing: some View {
        switch family {
        case .inline: Label("No inline layout", systemImage: "lock")
        case .circular: Image(systemName: "lock").font(.title2)
        case .rectangular:
            VStack(alignment: .leading, spacing: 0) {
                Text("No rectangular layout").font(.headline).lineLimit(1)
                Text("Add lock.rectangular(r => …)").font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct LockFaceView: View {
    let face: LockFace

    var body: some View {
        switch face {
        case .ring(let g):
            Gauge(value: g.value, in: g.min...g.max) {
                if let l = g.label { Text(l) }
            } currentValueLabel: {
                LockCenter(label: g.center, caption: g.label)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .gauge(let g):
            Gauge(value: g.value, in: g.min...g.max) {
                if let l = g.label { Text(l) }
            } currentValueLabel: {
                LockCenter(label: g.center)
            } minimumValueLabel: {
                Text(g.minLabel ?? "")
            } maximumValueLabel: {
                Text(g.maxLabel ?? "")
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
        case .timeRing(let start, let end, let center):
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                LockCenter(label: center)
            }
            .progressViewStyle(.circular)
            .widgetAccentable()
        case .number(let text, let caption, let symbol):
            VStack(spacing: 0) {
                if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)).widgetAccentable() }
                Text(text).font(.system(size: 24, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.4)
                if let caption { Text(caption).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .padding(6)
        case .symbol(let name, let caption):
            VStack(spacing: 1) {
                Image(systemName: name).font(.system(size: caption == nil ? 30 : 24, weight: .medium)).widgetAccentable()
                if let caption { Text(caption).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .padding(6)
        case .countdown(let date, let caption):
            VStack(spacing: 0) {
                Text(date, style: .timer).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center).lineLimit(1).minimumScaleFactor(0.6)
                if let caption { Text(caption).font(.system(size: 10, weight: .medium)).lineLimit(1) }
            }
            .padding(6)
        case .picture(let p):
            LockPictureView(picture: p, alignment: .center)
        }
    }
}

/// The text or symbol in the middle of a ring/gauge.
/// A ring's `label` shows under the center (the capacity style has no label slot of its own).
struct LockCenter: View {
    let label: LockLabel?
    var caption: String? = nil
    var body: some View {
        VStack(spacing: 0) {
            if let s = label?.symbol { Image(systemName: s).font(label?.text == nil ? .body : .caption2) }
            if let t = label?.text { Text(t).font(.system(size: 14, weight: .semibold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1) }
            if let caption { Text(caption).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7) }
        }
    }
}

struct LockRowsView: View {
    let rows: [LockRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in rowView(row) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func rowView(_ row: LockRow) -> some View {
        switch row {
        case .title(let text, let symbol):
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(text).lineLimit(1)
            }
            .font(.headline)
            .widgetAccentable()
        case .line(let text, let symbol, let trailing, let mono):
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.caption) }
                Text(text).font(mono ? .system(.body, design: .monospaced) : .body).lineLimit(1)
                if let trailing {
                    Spacer(minLength: 4)
                    Text(trailing).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .bar(let g):
            Gauge(value: g.value, in: g.min...g.max) {
                if let l = g.label { Text(l).font(.caption) }
            } currentValueLabel: {
                if let t = g.center?.text { Text(t) }
            } minimumValueLabel: {
                if let t = g.minLabel { Text(t) }
            } maximumValueLabel: {
                if let t = g.maxLabel { Text(t) }
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .widgetAccentable()
        case .timeBar(let start, let end, let label):
            ProgressView(timerInterval: start...end, countsDown: false) {
                if let label { Text(label).font(.caption) }
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .widgetAccentable()
        case .countdown(let date, let label):
            HStack(spacing: 4) {
                if let label { Text(label).lineLimit(1) }
                Spacer(minLength: 4)
                Text(date, style: .timer).monospacedDigit().multilineTextAlignment(.trailing)
            }
            .font(.body)
        case .relative(let date, let label):
            HStack(spacing: 4) {
                if let label { Text(label).lineLimit(1) }
                Spacer(minLength: 4)
                RelativeDateText.text(date).lineLimit(1)
            }
            .font(.body)
        case .sparkline(let values, let type):
            Chart(Array(values.enumerated()), id: \.offset) { i, v in
                switch type {
                case .bar: BarMark(x: .value("i", i), y: .value("v", v))
                case .line: LineMark(x: .value("i", i), y: .value("v", v)).interpolationMethod(.catmullRom)
                case .area:
                    AreaMark(x: .value("i", i), y: .value("v", v)).opacity(0.4).interpolationMethod(.catmullRom)
                    LineMark(x: .value("i", i), y: .value("v", v)).interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(maxHeight: .infinity)
            .widgetAccentable()
        case .picture(let p):
            LockPictureView(picture: p, alignment: .leading)
        }
    }
}

struct LockInlineView: View {
    let line: LockInline

    /// Inline widgets show one Text and one Image; anything else is dropped by the system.
    private var text: Text {
        guard let date = line.date else { return Text(line.text) }
        let prefix = line.text.isEmpty ? Text("") : Text(line.text + " ")
        switch line.dateStyle ?? .relative {
        case .timer: return prefix + Text(date, style: .timer)
        case .relative: return prefix + RelativeDateText.text(date)
        }
    }

    var body: some View {
        if let symbol = line.symbol {
            Label { text } icon: { Image(systemName: symbol) }
        } else {
            text
        }
    }
}

struct LockPictureView: View {
    let picture: LockPicture
    let alignment: Alignment

    var body: some View {
        if let ui = UIImage(data: picture.png, scale: 3) {
            Image(uiImage: ui)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: CGFloat(picture.width), maxHeight: CGFloat(picture.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }
}
