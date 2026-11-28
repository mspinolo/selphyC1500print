import SwiftUI

/// The collapsible column with the photos: choosing one shows it in the preview.
struct PhotoSidebar: View {
    let photos: [URL]
    let selection: URL?
    let select: (URL) -> Void
    let remove: (URL) -> Void
    let clear: () -> Void
    let add: () -> Void
    let drop: ([URL]) -> Bool

    @State private var isTargeted = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Original photos")).font(.headline)
                Text(photos.isEmpty ? tr("No photos selected") : trn(photos.count, one: "1 photo selected", other: "%d photos selected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if photos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .accessibilityHidden(true)
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(tr("Drop photos here"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(tr("Originals are only read. Conversion creates new temporary images."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(photos, id: \.self) { url in
                            row(for: url)
                        }
                    }
                    .padding(6)
                }
            }

            Divider()

            HStack {
                Button(tr("Add images…"), action: add)
                Spacer()
                Button(tr("Clear"), role: .destructive, action: clear)
                    .disabled(photos.isEmpty)
            }
            .padding(10)
        }
        .background(palette.panelBackground)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(palette.highlight, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { isTargeted = $0 }
    }

    private func row(for url: URL) -> some View {
        let isSelected = url == selection
        return HStack(spacing: 8) {
            ThumbnailView(url: url, side: 44)
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? palette.selection : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(url) }
        .contextMenu {
            Button(tr("Remove from list")) { remove(url) }
        }
        .help(url.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: tr("Remove from list")) { remove(url) }
    }
}
