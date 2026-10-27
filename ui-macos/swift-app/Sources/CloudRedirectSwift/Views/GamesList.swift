import AppKit
import SwiftUI

struct GameListItem: Equatable {
    let id: Int
    let name: String
    let detail: String
    let artwork: String
    let canDelete: Bool

    init(_ game: [String: Any]) {
        id = number(game, "appId")
        name = string(game, "name")
        detail = "\(number(game, "fileCount")) files · \(string(game, "sizeFormatted"))"
        artwork = string(game, "headerUrl")
        canDelete = game["isLocal"] as? Bool == true || game["isRemote"] as? Bool == true
    }
}

// NSTableView owns clicks, keyboard navigation, focus and selection.
// The cell keeps the existing artwork, spacing and delete button.
struct GamesList: NSViewRepresentable {
    let items: [GameListItem]
    @Binding var selection: Int?
    let onDelete: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("game"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 76
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        let changed = coordinator.parent.items != items
        coordinator.parent = self
        if changed { table.reloadData() }
        let indexes = IndexSet(items.indices.filter { items[$0].id == selection })
        if table.selectedRowIndexes != indexes {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        coordinator.updateCells(table)
        coordinator.updating = false
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: GamesList
        var updating = false
        init(_ parent: GamesList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GameSelectionRow() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.items.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("game")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? GameTableCell ?? GameTableCell()
            cell.identifier = identifier
            configure(cell, row: row, table: tableView)
            return cell
        }

        private func configure(_ cell: GameTableCell, row: Int, table: NSTableView) {
            let item = parent.items[row]
            cell.configure(item, selected: table.selectedRow == row) { [weak self] in self?.parent.onDelete(item.id) }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            updateCells(table)
            if !updating {
                parent.selection = parent.items.indices.contains(table.selectedRow) ? parent.items[table.selectedRow].id : nil
            }
        }

        func updateCells(_ table: NSTableView) {
            for row in parent.items.indices {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? GameTableCell {
                    configure(cell, row: row, table: table)
                }
            }
        }
    }
}

private final class GameSelectionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(srgbRed: 158/255, green: 175/255, blue: 147/255, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
    }
}

private final class GameArtworkView: NSHostingView<GameArt> {
    // Artwork lets the table receive row clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct GameDeleteButton: View {
    let name: String
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash").font(.system(size: 15)).frame(width: 28, height: 28)
        }
        .buttonStyle(IconActionStyle())
        .help("Delete saves for \(name)")
        .accessibilityLabel("Delete saves for \(name)")
    }
}

private final class GameTableCell: NSTableCellView {
    private let artwork = GameArtworkView(rootView: GameArt(url: ""))
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSHostingView(rootView: GameDeleteButton(name: "", action: {}))
    private var artworkURL = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        for view in [artwork, labels, deleteButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 104),
            artwork.heightAnchor.constraint(equalToConstant: 49),
            labels.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 14),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -14),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 36),
            deleteButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        textField = nameLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: GameListItem, selected: Bool, onDelete: @escaping () -> Void) {
        nameLabel.stringValue = item.name
        detailLabel.stringValue = item.detail
        nameLabel.textColor = selected ? .black : .labelColor
        detailLabel.textColor = selected ? .black : .secondaryLabelColor
        if artworkURL != item.artwork {
            artworkURL = item.artwork
            artwork.rootView = GameArt(url: item.artwork)
        }
        deleteButton.isHidden = !item.canDelete
        deleteButton.rootView = GameDeleteButton(name: item.name, action: onDelete)
    }
}
