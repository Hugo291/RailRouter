import SwiftUI
import AppKit

/// Native AppKit group rows keep one scroll surface, resizable columns and sortable headers.
struct ModelLibraryTable: NSViewRepresentable {
    let models: [LLMModel]
    let grouping: ModelGrouping
    @Binding var selection: String?
    @Binding var sortOrder: [KeyPathComparator<LLMModel>]
    @Binding var collapsedGroups: Set<String>

    struct Row: Equatable {
        var title: String? = nil
        var groupKey: String? = nil
        var collapsed = false
        var model: LLMModel? = nil
    }

    static func rows(_ models: [LLMModel], grouping: ModelGrouping, sortOrder: [KeyPathComparator<LLMModel>], collapsed: Set<String> = []) -> [Row] {
        var sorted = models.sorted(using: sortOrder)
        // Unknown metadata is not zero: keep it last in either direction.
        if let key = sortOrder.first?.keyPath {
            let known: (LLMModel) -> Bool = { model in
                if key == \LLMModel.parametersSortKey { return model.parameterCount != nil }
                if key == \LLMModel.quantizationSortKey { return model.quantizationBits != nil }
                if key == \LLMModel.sizeSortKey { return model.localSize != nil }
                if key == \LLMModel.modifiedSortKey { return model.modified != nil }
                return true
            }
            sorted = sorted.filter(known) + sorted.filter { !known($0) }
        }
        if grouping == .none { return sorted.map { Row(model: $0) } }
        let groups = Dictionary(grouping: sorted, by: { grouping.key($0) })
        return groups.keys.sorted().flatMap { key -> [Row] in
            let items = groups[key] ?? []
            guard let first = items.first else { return [] }
            let groupKey = "\(grouping.rawValue)|\(key)"
            let isCollapsed = collapsed.contains(groupKey)
            return [Row(title: "\(grouping.label(first))  ·  \(items.count)", groupKey: groupKey, collapsed: isCollapsed)]
                + (isCollapsed ? [] : items.map { Row(model: $0) })
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.rowClicked(_:))
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 4, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsColumnReordering = false
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(L("Bibliothèque de modèles"))
        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("name", L("Nom"), 170, 125), ("parameters", L("Paramètres"), 94, 90),
            ("quantization", L("Quantification"), 92, 86), ("size", L("Taille"), 78, 65),
            ("capabilities", L("Capacités"), 112, 108), ("modified", L("Modifié"), 130, 115)
        ]
        for (key, title, width, minimum) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            column.minWidth = minimum
            column.resizingMask = key == "name" ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let rows = Self.rows(models, grouping: grouping, sortOrder: sortOrder, collapsed: collapsedGroups)
        coordinator.updating = true
        if coordinator.rows != rows {
            coordinator.rows = rows
            coordinator.table?.reloadData()
        }
        if let table = coordinator.table {
            let index = rows.firstIndex { $0.model?.id == selection && $0.model != nil }
            if let index {
                if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            } else { table.deselectAll(nil) }
        }
        coordinator.updating = false
    }

    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ModelLibraryTable
        var rows: [Row] = []
        weak var table: NSTableView?
        var updating = false
        init(_ parent: ModelLibraryTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].model != nil }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].title == nil ? 30 : 32 }
        /// A click on the name cell (anywhere, not only the button) also copies the model identifier.
        @objc func rowClicked(_ sender: NSTableView) {
            let row = sender.clickedRow, column = sender.clickedColumn
            guard rows.indices.contains(row), rows[row].model != nil, column >= 0,
                  sender.tableColumns[column].identifier.rawValue == "name",
                  let cell = sender.view(atColumn: column, row: row, makeIfNecessary: false) as? CopyHoverCell else { return }
            cell.copyValueToPasteboard()
        }

        @objc func toggleGroup(_ sender: NSButton) {
            guard let table, case let row = table.row(for: sender), rows.indices.contains(row),
                  let key = rows[row].groupKey else { return }
            if parent.collapsedGroups.contains(key) { parent.collapsedGroups.remove(key) }
            else { parent.collapsedGroups.insert(key) }
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, rows.indices.contains(table.selectedRow) else { return }
            parent.selection = rows[table.selectedRow].model?.id
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first else { return }
            let order: SortOrder = descriptor.ascending ? .forward : .reverse
            let comparator: KeyPathComparator<LLMModel>
            switch descriptor.key {
            case "parameters": comparator = KeyPathComparator(\.parametersSortKey, order: order)
            case "quantization": comparator = KeyPathComparator(\.quantizationSortKey, order: order)
            case "size": comparator = KeyPathComparator(\.sizeSortKey, order: order)
            case "capabilities": comparator = KeyPathComparator(\.capabilitiesSortKey, order: order)
            case "modified": comparator = KeyPathComparator(\.modifiedSortKey, order: order)
            default: comparator = KeyPathComparator(\.name, comparator: .localizedStandard, order: order)
            }
            parent.sortOrder = [comparator, KeyPathComparator(\.name, comparator: .localizedStandard)]
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if let title = rows[row].title {
                guard tableColumn?.identifier.rawValue == "name" else { return nil }
                // Chevron cliquable : replie / déplie la catégorie.
                let collapsed = rows[row].collapsed
                let button = NSButton(title: title, target: self, action: #selector(toggleGroup(_:)))
                button.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .semibold)
                button.contentTintColor = .secondaryLabelColor
                button.toolTip = collapsed ? L("Déplier la catégorie") : L("Replier la catégorie")
                button.setAccessibilityLabel("\(title), \(collapsed ? L("repliée") : L("dépliée"))")
                return centered(button)
            }
            guard let model = rows[row].model else { return nil }
            switch tableColumn?.identifier.rawValue {
            case "name":
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 7
                let status = image("circle.fill", label: model.isActive ? L("En mémoire") : L("Non chargé"))
                status.contentTintColor = model.isActive ? .systemGreen : .quaternaryLabelColor
                status.widthAnchor.constraint(equalToConstant: 6).isActive = true
                status.heightAnchor.constraint(equalToConstant: 6).isActive = true
                let modelIcon = image(ModelIcon.glyph(for: model), label: ModelIcon.isCloud(model) ? L("Modèle cloud") : L("Modèle local"))
                modelIcon.contentTintColor = ModelIcon.isCloud(model) ? .systemBlue : .systemTeal
                modelIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
                modelIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
                let field = text(model.name)
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
                stack.addArrangedSubview(status)
                stack.addArrangedSubview(modelIcon)
                stack.addArrangedSubview(field)
                let cell = CopyHoverCell()
                cell.copyValue = model.id
                let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("Copier le nom du modèle"))!,
                                    target: cell, action: #selector(CopyHoverCell.copyValueToPasteboard))
                copy.isBordered = false
                copy.bezelStyle = .inline
                copy.contentTintColor = .secondaryLabelColor
                copy.toolTip = L("Copier le nom du modèle")
                copy.isHidden = true
                copy.setContentHuggingPriority(.required, for: .horizontal)
                stack.addArrangedSubview(copy)
                cell.copyButton = copy
                _ = centered(stack, fillWidth: true, in: cell)
                cell.textField = field
                return cell
            case "parameters":
                let field = text(model.parameters ?? "—")
                field.toolTip = model.parameterDescription
                return centered(field)
            case "quantization": return centered(text(model.quantization ?? "—"))
            case "size": return centered(text(model.source == .cloud || model.source == .openRouter ? "Cloud" : model.localSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"))
            case "capabilities":
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 6
                for cap in Array(Set(model.capabilities)).sorted() {
                    let symbol = image(CapabilityIcons.glyph(for: cap), label: CapabilityIcons.label(for: cap))
                    symbol.contentTintColor = NSColor(CapabilityIcons.color(for: cap))
                    symbol.widthAnchor.constraint(equalToConstant: 14).isActive = true
                    symbol.heightAnchor.constraint(equalToConstant: 16).isActive = true
                    stack.addArrangedSubview(symbol)
                }
                stack.toolTip = model.capabilities.map { CapabilityIcons.label(for: $0) }.joined(separator: ", ")
                stack.setAccessibilityLabel(stack.toolTip)
                return centered(stack)
            case "modified":
                let field = text(model.modified.map { Date.now.timeIntervalSince($0) < 172800 ? $0.formatted(date: .numeric, time: .shortened) : $0.formatted(.relative(presentation: .named)) } ?? "—")
                field.toolTip = model.modified?.formatted(date: .complete, time: .standard)
                return centered(field)
            default: return nil
            }
        }
        /// NSTableView stretches the cell, not its label. Pin the content's center
        /// explicitly so text, dots and symbols share the same baseline in every column.
        @discardableResult
        private func centered(_ content: NSView, fillWidth: Bool = false, in cell: NSTableCellView = NSTableCellView()) -> NSTableCellView {
            content.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                fillWidth ? content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3)
                          : content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -3)
            ])
            if let field = content as? NSTextField { cell.textField = field }
            return cell
        }
        private func text(_ value: String) -> NSTextField {
            let field = NSTextField(labelWithString: value)
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.toolTip = value
            return field
        }
        private func image(_ name: String, label: String) -> NSImageView {
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            view.contentTintColor = .secondaryLabelColor
            view.imageScaling = .scaleProportionallyDown
            view.toolTip = label
            view.setAccessibilityLabel(label)
            return view
        }
    }
}

/// Name cell: a copy button appears under the pointer and copies the model identifier.
private final class CopyHoverCell: NSTableCellView {
    var copyValue = ""
    var copyButton: NSButton?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { copyButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { copyButton?.isHidden = true; resetIcon() }

    @objc func copyValueToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyValue, forType: .string)
        copyButton?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: L("Copié"))
        copyButton?.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.resetIcon() }
    }

    private func resetIcon() {
        copyButton?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("Copier le nom du modèle"))
        copyButton?.contentTintColor = .secondaryLabelColor
    }
}
