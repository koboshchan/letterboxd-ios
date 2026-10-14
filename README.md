# Letterboxd

An unofficial native SwiftUI client for Letterboxd, for iOS 18 and later. It is not affiliated with or endorsed by Letterboxd, and it does not use the official Letterboxd API. It reads the same public pages and endpoints the website uses.

No screenshots are included yet. They will be added once a real signed-in run has been captured and checked.

## What works

You have to sign in. The app shows only a sign-in screen until the server has confirmed a session in the current launch. The shipped app has no guest, demo or sample-data mode.

- Browse popular, top-rated and anticipated films, and search films.
- Film pages with synopsis, cast and crew, reviews and the lists a film appears in.
- Person pages for cast and crew, with their filmography.
- Your profile: films, diary, reviews, watchlist and lists, plus follower and following lists. Opening another member's profile is read-only and never changes the signed-in identity.
- Native review and list screens, including full review text.
- Add to or remove from your watchlist, and like or unlike a film. The app reads the state back from Letterboxd before it shows the change.

## What does not work yet

Logging a diary entry, rating, writing or deleting a review, creating or editing lists, and editing your profile are not implemented. The film screen shows greyed-out rows for them. No request format has been captured for these, so the app does not guess one.

> [!IMPORTANT]
> Sign-in was verified in the iOS Simulator on commit `e6cb131`: the site's sign-in page, Done, server validation, the tabs, and session restore on a fresh launch all worked. It has not been re-tested on the current revision, and it has not been verified on a physical iPhone at the current revision.

## Sign-in and security

- Sign-in opens Letterboxd's own sign-in page in a non-persistent web view. The app does not read or store your password, and it does not fake the CSRF value or the Cloudflare Turnstile token. If a human check appears, you complete it yourself.
- After you tap Done, the app keeps only cookies that apply to `https://letterboxd.com` and saves them to the Keychain only once the server confirms the account on the homepage.
- A saved session is never trusted on launch. It is revalidated first, and if that fails nothing authenticated is used. Offline launches show a retry screen.
- Requests use an in-memory, server-validated session. Authenticated requests never follow redirects.
- Caches are partitioned by an auth generation that changes on sign-in, sign-out and restore, and late responses from an earlier generation are dropped.
- Signing out returns to the sign-in screen at once.

## Build

You need Xcode with the iOS 18 SDK or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild build -project Letterboxd.xcodeproj -scheme Letterboxd \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The data layer is a Swift package, `LetterboxdKit`, at the repo root. It builds and tests on macOS and Linux with Swift 6:

```sh
swift test
```

Run the UI tests on one simulator at a time:

```sh
xcodebuild test -project Letterboxd.xcodeproj -scheme LetterboxdUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
```

The UI tests run against a mock service in `Tests/UITestHost`, a separate test-only host app with fixture data. It is not part of the shipped app and is not a demo mode. The tests never touch the network. One test that checks redirect handling uses a loopback HTTP server and is skipped on Linux. It is plain HTTP on loopback, not TLS to letterboxd.com.

## Layout

- `Sources/LetterboxdKit`: models, parsers, the validated HTTP transport and the write client.
- `Sources/Letterboxd`: the SwiftUI app.
- `Tests`: package tests, UI tests and the UI test host.
- `Tests/LetterboxdKitTests/Fixtures`: sanitized fixtures derived from real responses. Raw captures are never committed.

## Privacy

Credentials, cookies and raw network captures are never committed. The app reads from Letterboxd's servers only on your behalf and sends nothing elsewhere.

