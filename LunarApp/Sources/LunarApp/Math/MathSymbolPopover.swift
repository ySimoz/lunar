import SwiftUI

/// Categories for mathematical symbol templates, matching `MathSymbolModal.tsx`.
public enum MathSymbolCategory: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case calculus = "Calculus"
    case algebra = "Algebra"
    case logicAndSets = "Logic & Sets"
    case greek = "Greek"
    case operators = "Operators"

    public var id: String { rawValue }
}

/// A single insertable LaTeX symbol or matrix template.
public struct MathSymbolTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let latex: String
    public let preview: String
    public let category: MathSymbolCategory

    public init(name: String, latex: String, preview: String, category: MathSymbolCategory) {
        self.id = "\(category.rawValue)-\(name)"
        self.name = name
        self.latex = latex
        self.preview = preview
        self.category = category
    }

    /// Formats markup for insertion into a card text field (`$...$` unless already wrapped or `\begin`).
    public var insertionText: String {
        if latex.hasPrefix("$") || latex.hasPrefix("\\begin") {
            return latex
        }
        return "$\(latex)$"
    }
}

/// Complete catalog of 53 LaTeX symbol templates across 5 categories.
public enum MathSymbolCatalog {
    public static let all: [MathSymbolTemplate] = [
        // Calculus & Analysis (9)
        MathSymbolTemplate(name: "Limit", latex: "\\lim_{x \\to c} f(x)", preview: "lim f(x)", category: .calculus),
        MathSymbolTemplate(name: "Definite Integral", latex: "\\int_{a}^{b} f(x)\\,dx", preview: "∫ₐᵇ f(x) dx", category: .calculus),
        MathSymbolTemplate(name: "Indefinite Integral", latex: "\\int f(x)\\,dx", preview: "∫ f(x) dx", category: .calculus),
        MathSymbolTemplate(name: "Summation", latex: "\\sum_{n=1}^{\\infty} a_n", preview: "∑ aₙ", category: .calculus),
        MathSymbolTemplate(name: "Partial Derivative", latex: "\\frac{\\partial f}{\\partial x}", preview: "∂f / ∂x", category: .calculus),
        MathSymbolTemplate(name: "Derivative", latex: "\\frac{df}{dx}", preview: "df / dx", category: .calculus),
        MathSymbolTemplate(name: "Epsilon-Delta", latex: "\\forall \\epsilon > 0, \\; \\exists \\delta > 0 \\text{ s.t. } |x - c| < \\delta \\implies |f(x) - L| < \\epsilon", preview: "∀ε, ∃δ", category: .calculus),
        MathSymbolTemplate(name: "Sequence", latex: "(x_n)_{n=1}^{\\infty}", preview: "(xₙ)ₙ₌₁^∞", category: .calculus),
        MathSymbolTemplate(name: "Supremum / Infimum", latex: "\\sup_{x \\in S} f(x)", preview: "sup f(x)", category: .calculus),

        // Algebra & Matrices (14)
        MathSymbolTemplate(name: "2x2 Matrix", latex: "$$\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}$$", preview: "(a b / c d)", category: .algebra),
        MathSymbolTemplate(name: "Column Vector", latex: "$$\\begin{pmatrix} x_1 \\\\ x_2 \\\\ \\vdots \\\\ x_n \\end{pmatrix}$$", preview: "(x₁ ⋮ xₙ)ᵀ", category: .algebra),
        MathSymbolTemplate(name: "Bracket Matrix [A]", latex: "$$\\begin{bmatrix} a & b \\\\ c & d \\end{bmatrix}$$", preview: "[a b / c d]", category: .algebra),
        MathSymbolTemplate(name: "Determinant |A|", latex: "$$\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}$$", preview: "|a b / c d|", category: .algebra),
        MathSymbolTemplate(name: "3x3 Matrix", latex: "$$\\begin{pmatrix} a & b & c \\\\ d & e & f \\\\ g & h & i \\end{pmatrix}$$", preview: "3×3 Matrix", category: .algebra),
        MathSymbolTemplate(name: "Identity Matrix I", latex: "$$\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}$$", preview: "(1 0 / 0 1)", category: .algebra),
        MathSymbolTemplate(name: "Norm / Length", latex: "\\|x\\|", preview: "‖x‖", category: .algebra),
        MathSymbolTemplate(name: "Inner Product", latex: "\\langle u, v \\rangle", preview: "⟨u, v⟩", category: .algebra),
        MathSymbolTemplate(name: "Subgroup", latex: "H \\le G", preview: "H ≤ G", category: .algebra),
        MathSymbolTemplate(name: "Normal Subgroup", latex: "N \\triangleleft G", preview: "N ◁ G", category: .algebra),
        MathSymbolTemplate(name: "Isomorphism", latex: "G \\cong H", preview: "G ≅ H", category: .algebra),
        MathSymbolTemplate(name: "Quotient Group", latex: "G / N", preview: "G / N", category: .algebra),
        MathSymbolTemplate(name: "Direct Sum", latex: "V \\oplus W", preview: "V ⊕ W", category: .algebra),
        MathSymbolTemplate(name: "Tensor Product", latex: "V \\otimes W", preview: "V ⊗ W", category: .algebra),

        // Logic & Sets (12)
        MathSymbolTemplate(name: "Implies", latex: "\\implies", preview: "⟹", category: .logicAndSets),
        MathSymbolTemplate(name: "If and Only If", latex: "\\iff", preview: "⟺", category: .logicAndSets),
        MathSymbolTemplate(name: "For All", latex: "\\forall", preview: "∀", category: .logicAndSets),
        MathSymbolTemplate(name: "There Exists", latex: "\\exists", preview: "∃", category: .logicAndSets),
        MathSymbolTemplate(name: "Element Of", latex: "\\in", preview: "∈", category: .logicAndSets),
        MathSymbolTemplate(name: "Subset Of", latex: "\\subseteq", preview: "⊆", category: .logicAndSets),
        MathSymbolTemplate(name: "Union / Intersection", latex: "A \\cup B, \\; A \\cap B", preview: "A ∪ B, A ∩ B", category: .logicAndSets),
        MathSymbolTemplate(name: "Empty Set", latex: "\\emptyset", preview: "∅", category: .logicAndSets),
        MathSymbolTemplate(name: "Real Numbers", latex: "\\mathbb{R}", preview: "ℝ", category: .logicAndSets),
        MathSymbolTemplate(name: "Complex Numbers", latex: "\\mathbb{C}", preview: "ℂ", category: .logicAndSets),
        MathSymbolTemplate(name: "Integers", latex: "\\mathbb{Z}", preview: "ℤ", category: .logicAndSets),
        MathSymbolTemplate(name: "Naturals", latex: "\\mathbb{N}", preview: "ℕ", category: .logicAndSets),

        // Greek Alphabet (9)
        MathSymbolTemplate(name: "Epsilon", latex: "\\epsilon", preview: "ε", category: .greek),
        MathSymbolTemplate(name: "Delta", latex: "\\delta, \\; \\Delta", preview: "δ, Δ", category: .greek),
        MathSymbolTemplate(name: "Lambda", latex: "\\lambda, \\; \\Lambda", preview: "λ, Λ", category: .greek),
        MathSymbolTemplate(name: "Alpha / Beta", latex: "\\alpha, \\; \\beta", preview: "α, β", category: .greek),
        MathSymbolTemplate(name: "Sigma", latex: "\\sigma, \\; \\Sigma", preview: "σ, Σ", category: .greek),
        MathSymbolTemplate(name: "Omega", latex: "\\omega, \\; \\Omega", preview: "ω, Ω", category: .greek),
        MathSymbolTemplate(name: "Theta", latex: "\\theta, \\; \\Theta", preview: "θ, Θ", category: .greek),
        MathSymbolTemplate(name: "Phi", latex: "\\phi, \\; \\Phi", preview: "φ, Φ", category: .greek),
        MathSymbolTemplate(name: "Pi", latex: "\\pi, \\; \\Pi", preview: "π, Π", category: .greek),

        // Operators & Formatting (9)
        MathSymbolTemplate(name: "Fraction", latex: "\\frac{a}{b}", preview: "a / b", category: .operators),
        MathSymbolTemplate(name: "Square Root", latex: "\\sqrt{x}", preview: "√x", category: .operators),
        MathSymbolTemplate(name: "N-th Root", latex: "\\sqrt[n]{x}", preview: "ⁿ√x", category: .operators),
        MathSymbolTemplate(name: "Plus-Minus", latex: "\\pm", preview: "±", category: .operators),
        MathSymbolTemplate(name: "Not Equal", latex: "\\neq", preview: "≠", category: .operators),
        MathSymbolTemplate(name: "Less/Greater Equal", latex: "\\le, \\; \\ge", preview: "≤, ≥", category: .operators),
        MathSymbolTemplate(name: "Infinity", latex: "\\infty", preview: "∞", category: .operators),
        MathSymbolTemplate(name: "Centered Dot", latex: "\\cdot", preview: "·", category: .operators),
        MathSymbolTemplate(name: "Equivalence", latex: "\\equiv", preview: "≡", category: .operators)
    ]

    public static func filter(category: MathSymbolCategory, query: String) -> [MathSymbolTemplate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { item in
            let matchesCategory = (category == .all || item.category == category)
            guard matchesCategory else { return false }
            guard !trimmed.isEmpty else { return true }
            return item.name.lowercased().contains(trimmed)
                || item.latex.lowercased().contains(trimmed)
                || item.preview.lowercased().contains(trimmed)
        }
    }
}

/// Clean toolbar `.popover` (`⌘K`) for inserting mathematical LaTeX templates into the active card field.
public struct MathSymbolPopover: View {
    public let activeFieldLabel: String
    public let onInsert: (String) -> Void

    @State private var selectedCategory: MathSymbolCategory = .all
    @State private var searchQuery: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: LunarTokens.space2),
        GridItem(.flexible(), spacing: LunarTokens.space2),
        GridItem(.flexible(), spacing: LunarTokens.space2)
    ]

    public init(activeFieldLabel: String, onInsert: @escaping (String) -> Void) {
        self.activeFieldLabel = activeFieldLabel
        self.onInsert = onInsert
    }

    public var body: some View {
        let items = MathSymbolCatalog.filter(category: selectedCategory, query: searchQuery)

        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            HStack {
                Text("Insert Symbol")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Into \(activeFieldLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: LunarTokens.space2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search symbols", text: $searchQuery, prompt: Text("Filter by name or LaTeX"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focusEffectDisabled()
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, LunarTokens.space2)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                    .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LunarTokens.space1) {
                    ForEach(MathSymbolCategory.allCases) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Text(category.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, LunarTokens.space2)
                                .padding(.vertical, 4)
                                .background(
                                    selectedCategory == category
                                        ? Color.primary.opacity(0.12)
                                        : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                                .foregroundStyle(
                                    selectedCategory == category
                                        ? .primary
                                        : .secondary
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            ScrollView {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Matching Symbols",
                        systemImage: "function",
                        description: Text("Try another keyword or category.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVGrid(columns: columns, spacing: LunarTokens.space2) {
                        ForEach(items) { item in
                            SymbolTemplateCell(item: item) {
                                onInsert(item.insertionText)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .frame(height: 280)
        }
        .padding(LunarTokens.space4)
        .frame(width: 420)
    }
}

private struct SymbolTemplateCell: View {
    let item: MathSymbolTemplate
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: LunarTokens.space1) {
                Text(item.preview)
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(height: 24)

                Text(item.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, LunarTokens.space2)
            .padding(.vertical, LunarTokens.space2)
            .frame(maxWidth: .infinity)
            .background(
                Color.primary.opacity(isHovered ? 0.08 : 0.03),
                in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                    .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
            }
        }
        .buttonStyle(QuietPressButtonStyle())
        .onHover { isHovered = $0 }
        .help(item.latex)
    }
}
