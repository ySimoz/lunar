import SwiftUI

/// Left translucent navigation sidebar (`NavigationSplitView` column).
/// Uses a pinned non-scrolling brand header and a full-bleed neutral glass backdrop
/// so content never scrolls behind window controls or exposes an unbacked titlebar strip.
public struct SidebarView: View {
    @Bindable var libraryVM: LibraryViewModel
    @State private var isDecksExpanded = true

    public init(libraryVM: LibraryViewModel) {
        self.libraryVM = libraryVM
    }

    private var activeSelection: SidebarDestination {
        libraryVM.selection ?? .today
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LunarTokens.space2) {
                LunarFolioIcon(size: 20, color: .primary)
                Text("Lunar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, LunarTokens.space4)
            .padding(.top, LunarTokens.space2)
            .padding(.bottom, LunarTokens.space3)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Study", topPadding: LunarTokens.space1)

                    SidebarNavRow(
                        title: "Today",
                        systemImage: "sun.max",
                        count: libraryVM.totalDue,
                        accentCount: libraryVM.totalDue > 0,
                        isSelected: activeSelection == .today
                    ) {
                        libraryVM.selection = .today
                    }

                    SidebarNavRow(
                        title: "Gauntlet",
                        systemImage: "bolt.shield",
                        count: 0,
                        accentCount: false,
                        isSelected: activeSelection == .gauntlet
                    ) {
                        libraryVM.selection = .gauntlet
                    }

                    decksSectionHeader

                    SidebarNavRow(
                        title: "Library",
                        systemImage: "square.grid.2x2",
                        count: libraryVM.decks.count,
                        accentCount: false,
                        isSelected: activeSelection == .library
                    ) {
                        libraryVM.selection = .library
                    }

                    if isDecksExpanded {
                        if libraryVM.decks.isEmpty {
                            Text("No decks yet")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, LunarTokens.space3)
                                .padding(.vertical, LunarTokens.space2)
                        } else {
                            ForEach(libraryVM.decks) { deck in
                                let isDropTarget = libraryVM.dragCoordinator.hoveredDeckId == deck.id
                                SidebarNavRow(
                                    title: deck.title,
                                    systemImage: "folder",
                                    count: deck.dueCount,
                                    accentCount: deck.dueCount > 0,
                                    isSelected: activeSelection == .deck(deck.id)
                                ) {
                                    libraryVM.selection = .deck(deck.id)
                                }
                                .reportWindowFrame { rect in
                                    libraryVM.dragCoordinator.sidebarDeckFrames[deck.id] = rect
                                }
                                .overlay {
                                    if isDropTarget {
                                        RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                                            .strokeBorder(LunarTokens.neutralHighlight, lineWidth: 1.5)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                        }
                    }

                    sectionHeader("Tools", topPadding: LunarTokens.space5)

                    SidebarNavRow(
                        title: "Analytics",
                        systemImage: "chart.line.uptrend.xyaxis",
                        count: 0,
                        accentCount: false,
                        isSelected: activeSelection == .analytics
                    ) {
                        libraryVM.selection = .analytics
                    }

                    SidebarNavRow(
                        title: "Tools",
                        systemImage: "wrench.and.screwdriver",
                        count: 0,
                        accentCount: false,
                        isSelected: activeSelection == .tools
                    ) {
                        libraryVM.selection = .tools
                    }
                }
                .padding(.horizontal, LunarTokens.space2)
                .padding(.bottom, LunarTokens.space4)
            }
            .clipped()
            .lunarSuppressTopScrollEdge()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.76))
            }
            .ignoresSafeArea(.all)
        }
    }

    private func sectionHeader(_ title: String, topPadding: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, LunarTokens.space3)
            .padding(.top, topPadding)
            .padding(.bottom, LunarTokens.space1)
    }

    private var decksSectionHeader: some View {
        Button {
            withAnimation(LunarTokens.hoverAnimation) {
                isDecksExpanded.toggle()
            }
        } label: {
            HStack(spacing: LunarTokens.space2) {
                Text("Decks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: isDecksExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
            }
            .padding(.leading, LunarTokens.space3)
            .padding(.trailing, LunarTokens.space1)
            .padding(.top, LunarTokens.space5)
            .padding(.bottom, LunarTokens.space1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isDecksExpanded ? "Hide Decks" : "Show Decks")
    }
}

private struct SidebarNavRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let accentCount: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)

        Button(action: action) {
            HStack(spacing: LunarTokens.space2) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 18, alignment: .center)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: LunarTokens.space2)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(
                            accentCount
                                ? LunarTokens.neutralHighlight
                                : .secondary
                        )
                }
            }
            .padding(.horizontal, LunarTokens.space3)
            .frame(height: 32)
            .background {
                if isSelected {
                    shape.fill(Color.primary.opacity(0.11))
                } else if isHovered {
                    shape.fill(Color.primary.opacity(LunarTokens.hoverFillOpacity))
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(LunarTokens.hairlineBorder(), lineWidth: LunarTokens.hairlineWidth)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(LunarTokens.hoverAnimation, value: isHovered)
    }
}
