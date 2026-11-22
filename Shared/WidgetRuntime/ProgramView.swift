import SwiftUI

/// The widget's whole content for a program: the current page plus a pager when
/// the script built more than one page.
struct ProgramView: View {
    let program: WidgetProgram
    let pageNumber: Int   // 1-based
    @Environment(\.widgetPageButton) private var pageButton

    init(program: WidgetProgram, pageNumber: Int) {
        self.program = program
        self.pageNumber = pageNumber
    }

    private var number: Int { program.clampedPageNumber(pageNumber) }

    var body: some View {
        if program.isEmpty {
            StatusView(title: "Empty widget", detail: "The script built no page.", symbol: "rectangle.dashed")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                PageView(nodes: program.page(number: number))
                if program.pages.count > 1 {
                    let n = program.pages.count
                    HStack(spacing: 8) {
                        pageButton.make("‹", (number - 2 + n) % n + 1)
                        Text("\(number)/\(n)").font(.caption2).foregroundStyle(.secondary)
                        pageButton.make("›", number % n + 1)
                        Spacer()
                    }
                }
            }
        }
    }
}

/// Sign-in prompt, errors, empty state.
struct StatusView: View {
    let title: String
    let detail: String?
    let symbol: String

    init(title: String, detail: String? = nil, symbol: String = "info.circle") {
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
