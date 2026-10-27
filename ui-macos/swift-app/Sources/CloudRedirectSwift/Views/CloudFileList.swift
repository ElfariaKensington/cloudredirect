import AppKit
import SwiftUI

struct CloudFileRow: Equatable {
    let name: String
    let size: Int64
    init(_ file: [String: Any]) {
        name = string(file, "name")
        size = Int64(number(file, "size"))
    }
}

// AppKit owns selection, keyboard navigation, range selection and dragging.
// Only the selection drawing uses the app's sage color.
struct CloudFileList: NSViewRepresentable {
    let files: [CloudFileRow]
    @Binding var selection: Set<String>
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let name = NSTableColumn(identifier: .init("name"))
        name.width = 460
        let size = NSTableColumn(identifier: .init("size"))
        size.width = 90; size.minWidth = 90; size.maxWidth = 90
        table.addTableColumn(name); table.addTableColumn(size)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        let changed = coordinator.parent.files != files
        coordinator.parent = self
        if changed { table.reloadData() }
        let indexes = IndexSet(files.indices.filter { selection.contains(files[$0].name) })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        coordinator.updateTextColors(table)
        coordinator.updating = false
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: CloudFileList
        var updating = false
        init(_ parent: CloudFileList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.files.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SageFileRowView() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.files.indices.contains(row), let tableColumn else { return nil }
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
            cell.identifier = tableColumn.identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            guard let field = cell.textField else { return cell }
            let file = parent.files[row]
            let size = tableColumn.identifier.rawValue == "size"
            field.stringValue = size ? ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) : file.name
            field.font = size ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 13)
            field.alignment = size ? .right : .left
            field.lineBreakMode = .byTruncatingMiddle
            field.toolTip = file.name
            field.textColor = tableView.selectedRowIndexes.contains(row) ? .black : .labelColor
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            updateTextColors(table)
            if !updating { parent.selection = Set(table.selectedRowIndexes.compactMap { parent.files.indices.contains($0) ? parent.files[$0].name : nil }) }
        }
        func updateTextColors(_ table: NSTableView) {
            for row in parent.files.indices {
                for column in 0..<table.numberOfColumns {
                    (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.textColor = table.selectedRowIndexes.contains(row) ? .black : .labelColor
                }
            }
        }
    }
}

final class SageFileRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(srgbRed: 175/255, green: 191/255, blue: 164/255, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

struct MigrationCloudRow: Equatable {
    let id: String
    let name: String
}

struct MigrationCloudList: NSViewRepresentable {
    let items: [MigrationCloudRow]
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let name = NSTableColumn(identifier: .init("name"))
        name.width = 460
        table.addTableColumn(name)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
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
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        coordinator.updateTextColors(table)
        coordinator.updating = false
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MigrationCloudList
        var updating = false

        init(_ parent: MigrationCloudList) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SageFileRowView() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.items.indices.contains(row), let tableColumn else { return nil }
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
            cell.identifier = tableColumn.identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            guard let field = cell.textField else { return cell }
            field.stringValue = parent.items[row].name
            field.font = .systemFont(ofSize: 13)
            field.lineBreakMode = .byTruncatingMiddle
            field.toolTip = parent.items[row].name
            field.textColor = tableView.selectedRow == row ? .black : .labelColor
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            updateTextColors(table)
            if !updating, table.selectedRow >= 0, parent.items.indices.contains(table.selectedRow) {
                parent.selection = parent.items[table.selectedRow].id
            } else if !updating, table.selectedRow == -1 {
                parent.selection = nil
            }
        }

        func updateTextColors(_ table: NSTableView) {
            for row in parent.items.indices {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.textColor = table.selectedRow == row ? .black : .labelColor
            }
        }
    }
}
