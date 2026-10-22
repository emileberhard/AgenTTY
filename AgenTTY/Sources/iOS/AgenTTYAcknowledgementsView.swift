import SwiftUI

struct AgenTTYAcknowledgementsView: View {
    @State private var notices: String?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            if let notices {
                Text(verbatim: notices)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else if let failure {
                ContentUnavailableView("Acknowledgements Unavailable", systemImage: "doc.text", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
        .task {
            do {
                notices = try await Task.detached {
                    guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    return try String(contentsOf: url, encoding: .utf8)
                }.value
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
