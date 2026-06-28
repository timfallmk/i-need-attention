import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                ForEach(OpenSourceLicenses.all) { component in
                    NavigationLink {
                        LicenseDetailView(component: component)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.name)
                            Text(component.licenseName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Everything else in the app is built on Apple's system frameworks, which don't require attribution.")
            }
        }
        .navigationTitle("Open Source")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseDetailView: View {
    let component: OpenSourceComponent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(component.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let url = component.url {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "link")
                            .font(.footnote)
                    }
                }

                Text(component.licenseText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
