import Foundation

/// Errors returned by `CoreClient` when communicating with `lunar-core`.
public enum CoreClientError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case unexpectedResponse
    case serverError(statusCode: Int, message: String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid lunar-core server address."
        case .unexpectedResponse:
            return "Unexpected response from lunar-core."
        case .serverError(let code, let message):
            return message.isEmpty ? "Server returned status \(code)." : message
        case .decodingError(let details):
            return "Failed to decode response: \(details)"
        }
    }
}

/// REST API surface for `lunar-core`.
public protocol CoreClientProtocol: Sendable {
    func health() async throws -> Bool
    func listDecks() async throws -> [Deck]
    func createDeck(_ deck: Deck) async throws -> Deck
    func updateDeck(id: String, _ deck: Deck) async throws -> Deck
    func deleteDeck(id: String) async throws
    func reorderDecks(deckIds: [String]) async throws
    func listDeckCards(deckId: String) async throws -> [Flashcard]
    func listCards(deckId: String?) async throws -> [Flashcard]
    func createCard(_ card: Flashcard) async throws -> Flashcard
    func updateCard(id: String, _ card: Flashcard) async throws -> Flashcard
    func deleteCard(id: String) async throws
    func reorderCards(deckId: String, cardIds: [String]) async throws
    func reviewCard(id: String, rating: Int, durationMs: Int64?) async throws -> Flashcard
    func undoReview(cardID: String) async throws -> Flashcard
    func predictCard(id: String) async throws -> [String: IntervalPrediction]
    func listSessions() async throws -> [StudySessionRecord]
    func createSession(_ session: StudySessionRecord) async throws -> StudySessionRecord
    func getActiveSession() async throws -> ActiveSessionState?
    func saveActiveSession(_ state: ActiveSessionState) async throws -> ActiveSessionState
    func clearActiveSession() async throws
    func getPreferences() async throws -> UserPreferences
    func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences
    func exportDeck(deckId: String, format: IOFormat) async throws -> ExportResult
    func importCards(_ request: ImportRequest) async throws -> ImportResult
    func importAPKG(
        _ data: Data,
        deckId: String?,
        deckName: String?,
        skipDuplicates: Bool
    ) async throws -> ImportResult
    func backupDatabase() async throws -> Data
    func restoreDatabase(_ data: Data) async throws -> RestoreResult
    func getStats(days: Int) async throws -> StatsSummary
    @discardableResult
    func transferCards(
        cardIds: [String],
        targetDeckId: String,
        targetTopic: String?,
        targetIndex: Int?
    ) async throws -> Int
}

public extension CoreClientProtocol {
    func undoReview(cardID: String) async throws -> Flashcard {
        throw CoreClientError.unexpectedResponse
    }
}

private struct ServerErrorPayload: Decodable {
    let error: String?
}

private struct HealthPayload: Decodable {
    let status: String
}

private struct ReorderRequest: Encodable {
    let cardIds: [String]
}

private struct ReorderDecksRequest: Encodable {
    let deckIds: [String]
}

private struct ReviewRequest: Encodable {
    let rating: Int
    let durationMs: Int64?
}

private struct TransferResponse: Decodable {
    let moved: Int
}

/// Async URLSession JSON client for the local `lunar-core` HTTP API.
public actor CoreClient: CoreClientProtocol {
    public let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    public func health() async throws -> Bool {
        let payload: HealthPayload = try await request("GET", path: "/health")
        return payload.status == "ok"
    }

    public func listDecks() async throws -> [Deck] {
        try await request("GET", path: "/api/decks")
    }

    public func createDeck(_ deck: Deck) async throws -> Deck {
        try await request("POST", path: "/api/decks", body: deck)
    }

    public func updateDeck(id: String, _ deck: Deck) async throws -> Deck {
        try await request("PUT", path: "/api/decks/\(escaped(id))", body: deck)
    }

    public func deleteDeck(id: String) async throws {
        try await requestNoContent("DELETE", path: "/api/decks/\(escaped(id))")
    }

    public func reorderDecks(deckIds: [String]) async throws {
        let _: [String: Bool] = try await request(
            "POST",
            path: "/api/decks/reorder",
            body: ReorderDecksRequest(deckIds: deckIds)
        )
    }

    public func listDeckCards(deckId: String) async throws -> [Flashcard] {
        try await request("GET", path: "/api/decks/\(escaped(deckId))/cards")
    }

    public func listCards(deckId: String? = nil) async throws -> [Flashcard] {
        if let deckId, !deckId.isEmpty {
            return try await request("GET", path: "/api/cards", queryItems: [URLQueryItem(name: "deckId", value: deckId)])
        }
        return try await request("GET", path: "/api/cards")
    }

    public func createCard(_ card: Flashcard) async throws -> Flashcard {
        try await request("POST", path: "/api/cards", body: card)
    }

    public func updateCard(id: String, _ card: Flashcard) async throws -> Flashcard {
        try await request("PUT", path: "/api/cards/\(escaped(id))", body: card)
    }

    public func deleteCard(id: String) async throws {
        try await requestNoContent("DELETE", path: "/api/cards/\(escaped(id))")
    }

    public func reorderCards(deckId: String, cardIds: [String]) async throws {
        let _: [String: Bool] = try await request(
            "POST",
            path: "/api/decks/\(escaped(deckId))/reorder",
            body: ReorderRequest(cardIds: cardIds)
        )
    }

    public func reviewCard(id: String, rating: Int, durationMs: Int64? = nil) async throws -> Flashcard {
        try await request(
            "POST",
            path: "/api/cards/\(escaped(id))/review",
            body: ReviewRequest(rating: rating, durationMs: durationMs)
        )
    }

    public func undoReview(cardID: String) async throws -> Flashcard {
        try await request("POST", path: "/api/cards/\(escaped(cardID))/undo")
    }

    public func predictCard(id: String) async throws -> [String: IntervalPrediction] {
        try await request("GET", path: "/api/cards/\(escaped(id))/predict")
    }

    public func listSessions() async throws -> [StudySessionRecord] {
        try await request("GET", path: "/api/sessions")
    }

    public func createSession(_ session: StudySessionRecord) async throws -> StudySessionRecord {
        try await request("POST", path: "/api/sessions", body: session)
    }

    public func getActiveSession() async throws -> ActiveSessionState? {
        do {
            let state: ActiveSessionState = try await request("GET", path: "/api/active-session")
            return state
        } catch CoreClientError.serverError(let statusCode, _) where statusCode == 404 {
            return nil
        }
    }

    public func saveActiveSession(_ state: ActiveSessionState) async throws -> ActiveSessionState {
        try await request("PUT", path: "/api/active-session", body: state)
    }

    public func clearActiveSession() async throws {
        try await requestNoContent("DELETE", path: "/api/active-session")
    }

    public func getPreferences() async throws -> UserPreferences {
        try await request("GET", path: "/api/preferences")
    }

    public func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences {
        try await request("PUT", path: "/api/preferences", body: preferences)
    }

    public func exportDeck(deckId: String, format: IOFormat) async throws -> ExportResult {
        try await request(
            "GET",
            path: "/api/decks/\(escaped(deckId))/export",
            queryItems: [URLQueryItem(name: "format", value: format.rawValue)]
        )
    }

    public func importCards(_ body: ImportRequest) async throws -> ImportResult {
        try await request("POST", path: "/api/import", body: body)
    }

    public func importAPKG(
        _ data: Data,
        deckId: String? = nil,
        deckName: String? = nil,
        skipDuplicates: Bool = true
    ) async throws -> ImportResult {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "skip_duplicates", value: skipDuplicates ? "true" : "false")
        ]
        if let deckId, !deckId.isEmpty {
            queryItems.append(URLQueryItem(name: "deck_id", value: deckId))
        }
        if let deckName, !deckName.isEmpty {
            queryItems.append(URLQueryItem(name: "deck_name", value: deckName))
        }
        return try await uploadBinary(
            "POST",
            path: "/api/io/import/apkg",
            queryItems: queryItems,
            data: data
        )
    }

    public func backupDatabase() async throws -> Data {
        let url = try buildURL(path: "/api/backup")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        try validateResponse(response, data: data)
        return data
    }

    public func restoreDatabase(_ data: Data) async throws -> RestoreResult {
        try await uploadBinary("POST", path: "/api/restore", data: data)
    }

    public func getStats(days: Int = 30) async throws -> StatsSummary {
        try await request(
            "GET",
            path: "/api/stats",
            queryItems: [URLQueryItem(name: "days", value: String(days))]
        )
    }

    @discardableResult
    public func transferCards(
        cardIds: [String],
        targetDeckId: String,
        targetTopic: String? = nil,
        targetIndex: Int? = nil
    ) async throws -> Int {
        let payload = TransferCardsRequest(
            cardIds: cardIds,
            targetDeckId: targetDeckId,
            targetTopic: targetTopic,
            targetIndex: targetIndex
        )
        let response: TransferResponse = try await request(
            "POST",
            path: "/api/cards/transfer",
            body: payload
        )
        return response.moved
    }

    // MARK: - Helpers

    private func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func buildURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CoreClientError.invalidURL
        }
        let normalizedBasePath = components.path == "/" ? "" : components.path
        components.path = normalizedBasePath + path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw CoreClientError.invalidURL
        }
        return url
    }

    private func request<Response: Decodable>(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        let url = try buildURL(path: path, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await execute(req)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ method: String,
        path: String,
        body: Body
    ) async throws -> Response {
        let url = try buildURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        return try await execute(req)
    }

    private func requestNoContent(_ method: String, path: String) async throws {
        let url = try buildURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        let (data, response) = try await session.data(for: req)
        try validateResponse(response, data: data)
    }

    private func uploadBinary<Response: Decodable>(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        data: Data
    ) async throws -> Response {
        let url = try buildURL(path: path, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        return try await execute(req)
    }

    private func execute<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw CoreClientError.decodingError(error.localizedDescription)
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CoreClientError.unexpectedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let decoded = try? decoder.decode(ServerErrorPayload.self, from: data)
            let message = decoded?.error ?? String(data: data, encoding: .utf8) ?? ""
            throw CoreClientError.serverError(statusCode: http.statusCode, message: message)
        }
    }
}
