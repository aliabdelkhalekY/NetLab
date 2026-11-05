import NetLabCore
import SwiftUI
import UIKit

enum Format {
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "…" }
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        return "\(Int((seconds * 1000).rounded())) ms"
    }

    static func status(_ call: Call) -> String {
        if let error = call.errorCode { return error }
        if let status = call.response?.statusCode { return String(status) }
        return "Pending"
    }

    static func statusColor(_ code: Int?, error: String? = nil) -> Color {
        if error != nil { return .red }
        guard let code else { return .secondary }
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    static func variantTitle(_ variant: Variant) -> String {
        switch variant.id {
        case "2xx": return "Last success · \(variant.statusCode)"
        case "5xx": return "Last server error · \(variant.statusCode)"
        default: return "Last \(variant.statusCode)"
        }
    }

}

struct MethodLabel: View {
    let method: String

    var body: some View {
        Text(method)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 38, alignment: .leading)
    }
}

struct StatusText: View {
    let call: Call

    var body: some View {
        Text(Format.status(call))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(Format.statusColor(call.response?.statusCode, error: call.errorCode))
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct BodyView: View {
    let data: Data?
    let truncated: Bool
    let redaction: Redaction
    let reveal: Bool

    @State private var showsRaw = false

    private var json: JSONValue? {
        guard let data, !data.isEmpty, let value = try? JSONValue(data: data) else { return nil }
        return reveal ? value : redaction.redact(json: value)
    }

    var body: some View {
        if let data, !data.isEmpty {
            if let json {
                Picker("View", selection: $showsRaw) {
                    Text("Tree").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                if showsRaw {
                    RawText(text: json.text())
                } else {
                    JSONTreeView(value: json)
                }
            } else if let text = String(data: data, encoding: .utf8) {
                RawText(text: text)
            } else {
                Text("Binary body, \(data.count) bytes").foregroundStyle(.secondary)
            }
            if truncated {
                Text("Shortened to the first 1 MB.").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Text("No body").foregroundStyle(.secondary)
        }
    }
}

struct RawText: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 4)
        }
    }
}

struct HeadersView: View {
    let headers: [String: String]
    let redaction: Redaction
    let reveal: Bool

    var body: some View {
        if headers.isEmpty {
            Text("No headers").foregroundStyle(.secondary)
        }
        ForEach(headers.keys.sorted(), id: \.self) { name in
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption).foregroundStyle(.secondary)
                Text(!reveal && redaction.isSensitiveHeader(name) ? Redaction.mask : headers[name] ?? "")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}
