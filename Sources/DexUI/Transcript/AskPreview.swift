import DexCore
import SwiftUI
import WebKit

/// The mockup an option carries, drawn as the fragment Claude actually wrote.
///
/// Every option's preview arrives at once off the socket, so all of them are on
/// screen together — which is the comparison previews are for, and the thing the
/// terminal could never do with one panel and a cursor.
package struct AskPreview: NSViewRepresentable {
    let html: String
    /// How tall the fragment draws at the width it was given, once it has loaded.
    var onHeight: (CGFloat) -> Void = { _ in }

    package init(html: String, onHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.html = html
        self.onHeight = onHeight
    }

    /// What a preview is drawn at until it has said how tall it is.
    package static let placeholder: CGFloat = 132

    /// Past this a mockup is cut rather than grown, so one oversized fragment
    /// can't push every other option out of the card.
    package static let maxHeight: CGFloat = 420

    package func makeNSView(context: Context) -> FittingWebView {
        let configuration = WKWebViewConfiguration()
        // A preview is a picture, not a program: nothing it contains should be
        // able to run, navigate, or reach the network.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let view = FittingWebView(frame: .zero, configuration: configuration)
        view.onHeight = onHeight
        view.navigationDelegate = context.coordinator
        // Undocumented, but the only way to stop a web view painting white over
        // the card in dark mode; the fragment sets no background of its own.
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.document(fragment: html), baseURL: nil)
        return view
    }

    package func updateNSView(_ view: FittingWebView, context: Context) {
        view.onHeight = onHeight
        guard context.coordinator.rendered != html else { return }
        context.coordinator.rendered = html
        view.loadHTMLString(Self.document(fragment: html), baseURL: nil)
    }

    package func makeCoordinator() -> Coordinator { Coordinator(rendered: html) }

    package final class Coordinator: NSObject, WKNavigationDelegate {
        var rendered: String

        init(rendered: String) { self.rendered = rendered }

        /// Nothing in a preview may navigate. The fragment is model output, and
        /// a mockup that can open a URL is a mockup that can be made to. Only
        /// the fragment's own `about:blank` loads: a meta refresh arrives as
        /// `.other` too, and would carry whatever it put in its URL off the Mac.
        /// The async form, because the handler form only "nearly matches" the
        /// requirement under strict concurrency and WebKit never calls it.
        package func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.scheme == "about" ? .allow : .cancel
        }

        package func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            (webView as? FittingWebView)?.measure()
        }
    }

    /// A fragment's height depends on its width, so it is asked again whenever
    /// the width changes and not only when it loads.
    package final class FittingWebView: WKWebView {
        var onHeight: (CGFloat) -> Void = { _ in }
        private var measuredWidth: CGFloat = -1

        package override func layout() {
            super.layout()
            guard bounds.width != measuredWidth else { return }
            measuredWidth = bounds.width
            measure()
        }

        /// In the app's own content world, which the fragment's disabled
        /// JavaScript doesn't reach.
        func measure() {
            guard bounds.width > 0 else { return }
            Task { @MainActor in
                let value = try? await evaluateJavaScript(
                    "document.body.scrollHeight", in: nil, contentWorld: .defaultClient)
                guard let height = (value as? NSNumber)?.doubleValue, height > 0 else { return }
                onHeight(CGFloat(height.rounded(.up)))
            }
        }
    }

    /// The SDK strips script, style and doctype before the fragment reaches us;
    /// the sandbox here is the second lock rather than the only one.
    static func document(fragment: String) -> String {
        """
        <!doctype html>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" \
        content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
          body { font: 13px -apple-system, system-ui, sans-serif; color: canvastext; }
          * { max-width: 100%; }
        </style>
        <body>\(fragment)</body>
        """
    }
}
