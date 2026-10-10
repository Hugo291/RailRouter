import SwiftUI
import AppKit

/// Native AppKit group rows keep one scroll surface, resizable columns and sortable headers.
struct ModelLibraryTable: NSViewRepresentable {
    let models: [LLMModel]
    let grouping: ModelGrouping
    @Binding var selection: String?
    @Binding var sortOrder: [KeyPathComparator<LLMModel>]
    @Binding var collapsedGroups: Set<String>
    /// nil : pas de Codex piloté, colonne masquée.
    var codex: CodexSelection? = nil

    struct Row: Equatable {
        var title: String? = nil
        var groupKey: String? = nil
        var collapsed = false
        var model: LLMModel? = nil
        var moreKey: String? = nil   // ligne « Afficher plus » de la catégorie
        var remaining = 0
    }

    /// Lignes affichées d'abord par catégorie ; chaque clic sur « Afficher plus » en révèle `pageSize` de plus.
    static let pageSize = 15

    static func rows(_ models: [LLMModel], grouping: ModelGrouping, sortOrder: [KeyPathComparator<LLMModel>], collapsed: Set<String> = [], extra: [String: Int] = [:]) -> [Row] {
        var sorted = models.sorted(using: sortOrder)
        // Unknown metadata is not zero: keep it last in either direction.
        if let key = sortOrder.first?.keyPath {
            let known: (LLMModel) -> Bool = { model in
                if key == \LLMModel.parametersSortKey { return model.parameterCount != nil }
                if key == \LLMModel.quantizationSortKey { return model.quantizationBits != nil }
                if key == \LLMModel.sizeSortKey { return model.localSize != nil }
                if key == \LLMModel.modifiedSortKey { return model.modified != nil }
                if key == \LLMModel.priceSortKey { return model.price != nil || model.isFree }
                return true
            }
            sorted = sorted.filter(known) + sorted.filter { !known($0) }
        }
        func page(_ items: [LLMModel], _ key: String) -> [Row] {
            let shown = min(items.count, pageSize + (extra[key] ?? 0))
            let rows = items.prefix(shown).map { Row(model: $0) }
            return shown < items.count ? rows + [Row(moreKey: key, remaining: items.count - shown)] : rows
        }
        if grouping == .none { return page(sorted, "all") }
        let groups = Dictionary(grouping: sorted, by: { grouping.key($0) })
        return groups.keys.sorted().flatMap { key -> [Row] in
            let items = groups[key] ?? []
            guard let first = items.first else { return [] }
            let groupKey = "\(grouping.rawValue)|\(key)"
            let isCollapsed = collapsed.contains(groupKey)
            return [Row(title: "\(grouping.label(first))  ·  \(items.count)", groupKey: groupKey, collapsed: isCollapsed)]
                + (isCollapsed ? [] : page(items, groupKey))
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
            ("capabilities", L("Capacités"), 112, 108), ("price", L("Prix"), 150, 60), ("modified", L("Date"), 130, 115),
            ("compat", L("Compat."), 104, 86), ("codex", "Codex", 52, 46)
        ]
        for (key, title, width, minimum) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            column.minWidth = minimum
            column.resizingMask = key == "name" ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
            if key == "codex", let icon = ProviderLogo.image("codex") {
                let header = IconHeaderCell(textCell: title)
                header.image = icon
                column.headerCell = header
            }
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("codex"))?.sortDescriptorPrototype = nil
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("codex"))?.headerToolTip = L("Proposer le modèle dans le sélecteur de Codex")
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("compat"))?.sortDescriptorPrototype = nil
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("compat"))?.headerToolTip = L("Le modèle fonctionne-t-il dans Codex ? Test réel d’une requête Responses (modèles Alibaba).")
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let rows = Self.rows(models, grouping: grouping, sortOrder: sortOrder, collapsed: collapsedGroups, extra: coordinator.extra)
        coordinator.updating = true
        coordinator.table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("codex"))?.isHidden = codex == nil
        coordinator.table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("compat"))?.isHidden = codex == nil
        let codexIDs = Set(models.filter { codex?.contains($0) == true }.map(\.id))
        let compat = Dictionary(models.compactMap { model in codex.map { (model.id, $0.compat(model)) } }, uniquingKeysWith: { first, _ in first })
        if coordinator.rows != rows || coordinator.codexIDs != codexIDs || coordinator.compat != compat {
            coordinator.codexIDs = codexIDs
            coordinator.compat = compat
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
        var extra: [String: Int] = [:]
        var codexIDs: Set<String> = []
        var compat: [String: CodexCompat] = [:]
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
        @objc func showMore(_ sender: NSButton) {
            guard let table, case let row = table.row(for: sender), rows.indices.contains(row), let key = rows[row].moreKey else { return }
            extra[key, default: 0] += ModelLibraryTable.pageSize
            rows = ModelLibraryTable.rows(parent.models, grouping: parent.grouping, sortOrder: parent.sortOrder, collapsed: parent.collapsedGroups, extra: extra)
            table.reloadData()
        }
        @MainActor @objc func toggleCodex(_ sender: NSButton) {
            guard let table, case let row = table.row(for: sender), rows.indices.contains(row), let model = rows[row].model else { return }
            parent.codex?.set(model, included: sender.state == .on)
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
            case "price": comparator = KeyPathComparator(\.priceSortKey, order: order)
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
            if rows[row].moreKey != nil {
                guard tableColumn?.identifier.rawValue == "name" else { return nil }
                let button = NSButton(title: L("Afficher plus · %lld restants", rows[row].remaining), target: self, action: #selector(showMore(_:)))
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.contentTintColor = .controlAccentColor
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
                if let id = ProviderLogo.id(for: model), let logo = ProviderLogo.image(id) {
                    modelIcon.image = logo
                    modelIcon.contentTintColor = logo.isTemplate ? .labelColor : nil
                }
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
            case "price":
                guard let price = model.price else {
                    guard model.isFree else { return centered(text("—")) }
                    let field = text("Free")
                    field.textColor = .systemGreen
                    field.font = .systemFont(ofSize: 12, weight: .semibold)
                    return centered(field)
                }
                // « $ » à « $$$ » (seuls les symboles du niveau), puis les tarifs : « $ in 0.2$/out 0.4$ ».
                let tier = String(repeating: "$", count: price.tier)
                let detail = " " + TokenPrice.compact(price)
                let label = NSMutableAttributedString(string: tier, attributes: [.foregroundColor: NSColor.systemGreen, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)])
                label.append(NSAttributedString(string: detail, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]))
                let field = text("")
                field.attributedStringValue = label
                field.lineBreakMode = .byTruncatingTail
                field.toolTip = TokenPrice.summary(price)
                return centered(field)
            case "compat":
                let state = compat[model.id] ?? .notTestable
                let field = text(state.label)
                switch state {
                case .compatible: field.textColor = .systemGreen; field.font = .systemFont(ofSize: 12, weight: .semibold)
                case .incompatible(let reason):
                    field.textColor = .systemRed; field.font = .systemFont(ofSize: 12, weight: .semibold)
                    field.toolTip = reason.map { L("Refusé par Alibaba : %@", $0) } ?? L("Refusé par Alibaba")
                case .untested, .testing, .notTestable: field.textColor = .secondaryLabelColor
                }
                if case .notTestable = state { field.toolTip = L("Test automatique réservé aux modèles Alibaba.") }
                return centered(field)
            case "codex":
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCodex(_:)))
                box.state = codexIDs.contains(model.id) ? .on : .off
                box.toolTip = L("Proposer dans Codex")
                box.setAccessibilityLabel(L("Proposer %@ dans Codex", model.name))
                return centered(box)
            case "parameters":
                let field = text(model.parameters ?? "—")
                field.toolTip = model.parameterDescription
                return centered(field)
            case "quantization": return centered(text(model.quantization ?? "—"))
            case "size": return centered(text(model.isCloudHosted ? "Cloud" : model.localSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"))
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

/// En-tête de colonne qui montre `image` à la place du titre (le titre reste lu par VoiceOver).
/// Aucune propriété stockée : AppKit copie la cellule sans initialiser les champs Swift d'une sous-classe.
private final class IconHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let icon = image else { return super.drawInterior(withFrame: cellFrame, in: controlView) }
        let side: CGFloat = 16
        let frame = NSRect(x: cellFrame.midX - side / 2, y: cellFrame.midY - side / 2, width: side, height: side)
        icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
