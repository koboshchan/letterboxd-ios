import Foundation

/// Decoders for JSON endpoints whose responses were recorded from a real session.
/// Provenance: Tests/LetterboxdKitTests/Fixtures/recorded. Only fields observed are modelled.
public struct FilmJSON: Codable, Sendable, Equatable {
    public struct Director: Codable, Sendable, Equatable { public let name: String }
    public let result: Bool
    public let uid: String
    public let id: Int
    public let name: String
    public let slug: String
    public let url: String
    public let releaseYear: Int?
    public let runTime: Int?
    public let image150: String?
    public let image230: String?
    public let watchlistAction: String?
    public let directors: [Director]
    public static func decode(_ d: Data) throws -> FilmJSON { try JSONDecoder().decode(FilmJSON.self, from: d) }
}

public struct PosterJSON: Codable, Sendable, Equatable {
    public let url: URL
    public let url2x: URL
    public let shouldObfuscate: Bool
    public static func decode(_ d: Data) throws -> PosterJSON {
        let p = try JSONDecoder().decode(PosterJSON.self, from: d)
        for u in [p.url, p.url2x] { guard u.scheme == "https", u.host?.hasSuffix("ltrbxd.com") == true else { throw LetterboxdError.invalidInput("poster host") } }
        return p
    }
}

/// Response of POST /user/login.do as recorded. The request schema was not captured, so no client sends it yet.
public struct LoginResponse: Codable, Sendable, Equatable {
    public let result: String
    public let messages: [String]
    public var succeeded: Bool { result == "success" }
    public static func decode(_ d: Data) throws -> LoginResponse { try JSONDecoder().decode(LoginResponse.self, from: d) }
}
