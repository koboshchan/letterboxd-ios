import Foundation
import SwiftSoup

extension Parsers {
    private static func entryDate(_ value: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: String(value.prefix(10)))
    }
    private static func entryRating(_ el: Element) throws -> Double? {
        if let glyph = try el.select("svg.glyph.-rating").first(),
           let value = stars(try glyph.attr("aria-label")) { return value }
        for span in try el.select(".rating") {
            for part in try span.className().split(separator: " ") where part.hasPrefix("rated-") {
                if let n = Int(part.dropFirst(6)), (1...10).contains(n) { return Double(n) / 2 }
            }
        }
        return nil
    }
    private static func entryPoster(_ el: Element) throws -> URL? {
        // Prefer lazy image attributes over the site's empty-poster src.
        let candidates = [try el.attr("data-poster-url")] + (try el.select("img").array()).flatMap {
            [try? $0.attr("data-src"), try? $0.attr("src")].compactMap { $0 }
        }
        return candidates.first(where: { !$0.isEmpty && !$0.contains("empty-poster") })
            .flatMap(avatar)
    }

    /// Diary table rows include unreviewed viewings and repeated watches of the same film.
    /// The day link carries the full date even when the month cell is blank.
    public static func memberDiary(html: String, page: Int) throws -> Page<ActivityEntry> {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        var items: [ActivityEntry] = []
        for row in try doc.select("tr.diary-entry-row") {
            guard let poster = try row.select("[data-item-slug]").first(),
                  let link = Validate.resolve(try poster.attr("data-target-link")),
                  (try? Validate.reviewPage(link)) != nil,
                  let day = try row.select("a.daydate").first() else { continue }
            let parts = try day.attr("href").split(separator: "/")
            guard let at = parts.firstIndex(of: "for"), parts.count > at + 3,
                  let date = entryDate("\(parts[at+1])-\(parts[at+2])-\(parts[at+3])") else { continue }
            let (title, year) = splitTitleYear(try poster.attr("data-item-full-display-name"))
            guard !title.isEmpty else { continue }
            let rewatchCell = try row.select(".col-rewatch").first()
            var rewatch = false
            if let cell = rewatchCell, !cell.hasClass("icon-status-off") {
                rewatch = !(try cell.select(".icon-rewatch").isEmpty())
            }
            items.append(ActivityEntry(link: link, filmTitle: title, filmYear: year,
                rating: try entryRating(row), watchedDate: date, rewatch: rewatch,
                review: nil, posterURL: try entryPoster(poster)))
        }
        return Page(items: items, page: page, hasNext: !(try doc.select("a.next").isEmpty()))
    }

    /// Reviews come from the member reviews page, never from RSS poster/description markup.
    public static func memberReviews(html: String, page: Int) throws -> Page<ActivityEntry> {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        var items: [ActivityEntry] = []
        for row in try doc.select("article.production-viewing") {
            guard let poster = try row.select("[data-item-slug]").first(),
                  let context = try row.select("a.context").first(),
                  let link = Validate.resolve(try context.attr("href")),
                  (try? Validate.reviewPage(link)) != nil,
                  let body = try row.select(".js-review-body").first() else { continue }
            let text = try body.select("p").array().map { try $0.text() }.joined(separator: "\n\n")
            guard !text.isEmpty else { continue }
            let (title, year) = splitTitleYear(try poster.attr("data-item-full-display-name"))
            guard !title.isEmpty else { continue }
            let date = try row.select("time.timestamp").first().flatMap { entryDate(try $0.attr("datetime")) }
            items.append(ActivityEntry(link: link, filmTitle: title, filmYear: year,
                rating: try entryRating(row), watchedDate: date,
                rewatch: try context.text().lowercased().contains("rewatched"),
                review: text, posterURL: try entryPoster(poster)))
        }
        return Page(items: items, page: page, hasNext: !(try doc.select("a.next").isEmpty()))
    }
}
