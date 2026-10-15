import Foundation

/// Which account writes the client can really perform. A feature is .supported only if its exact request AND its
/// authoritative readback were captured from the real site. Everything else is .unverified and the UI shows it
/// disabled with this reason; nothing is sent, nothing is faked.
public enum WriteFeature: String, CaseIterable, Sendable {
    case watchlist, like, watched, logDiary, rate, review, createList, addToList, editProfile
    public enum Status: Equatable, Sendable { case supported, unverified(reason: String) }
    public var status: Status {
        switch self {
        case .watchlist, .like, .watched, .rate, .createList, .editProfile: .supported
        default: .unverified(reason: "Not available yet. Letterboxd’s request for this hasn’t been verified, so the app doesn’t send it.")
        }
    }
    public var title: String {
        switch self {
        case .watchlist: "Watchlist"; case .like: "Like"; case .watched: "Watched"; case .logDiary: "Log to diary"; case .rate: "Rate"
        case .review: "Write a review"; case .createList: "New list"; case .addToList: "Add to list"; case .editProfile: "Edit profile"
        }
    }
    public var symbol: String {
        switch self {
        case .watchlist: "plus.circle"; case .like: "heart"; case .watched: "eye"; case .logDiary: "calendar.badge.plus"; case .rate: "star"
        case .review: "square.and.pencil"; case .createList: "list.bullet.rectangle"; case .addToList: "text.badge.plus"; case .editProfile: "person.crop.circle"
        }
    }
}
