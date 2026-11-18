import SwiftUI

/// Two-tab Tools workspace (`Focus Timer` | `2D Grapher`) backed by session-scoped state.
public struct ToolsView: View {
    @Bindable var pomodoroVM: PomodoroViewModel
    @Bindable var grapherVM: GrapherViewModel

    public init(
        pomodoroVM: PomodoroViewModel,
        grapherVM: GrapherViewModel
    ) {
        self.pomodoroVM = pomodoroVM
        self.grapherVM = grapherVM
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                LunarSegmentedControl(
                    selection: $grapherVM.activeToolTab,
                    options: ToolsTab.allCases.map { ($0, $0.rawValue) }
                )

                Spacer()
            }
            .padding(.horizontal, LunarTokens.space6)
            .padding(.vertical, LunarTokens.space3)

            switch grapherVM.activeToolTab {
            case .focusTimer:
                PomodoroView(pomodoroVM: pomodoroVM)
            case .grapher:
                GrapherView(grapherVM: grapherVM)
            }
        }
        .navigationTitle("Tools")
    }
}
