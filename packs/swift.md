# Swift Guidelines

**Target version**: Swift 5.9+
**Formatter**: [swift-format](https://github.com/swiftlang/swift-format)
**Linter**: [SwiftLint](https://github.com/realm/SwiftLint)
**Build system**: Swift Package Manager (SPM)

---

## Naming Conventions (MUST)

```swift
// Types, protocols, enums: PascalCase
struct NetworkClient { ... }
protocol Cacheable { ... }
enum LoadingState { ... }

// Variables, functions, parameters: camelCase
let maxRetryCount = 3
func fetchUser(byID id: Int) -> User { ... }

// Boolean properties: is/has/should prefix
var isLoading: Bool
var hasPermission: Bool

// Constants: camelCase (NOT UPPER_SNAKE_CASE — Swift convention)
let defaultTimeout: TimeInterval = 30
```

## Value Semantics & Type Choice (MUST)

- **MUST** prefer `struct` by default — use `class` only when reference semantics or inheritance is required
- **MUST** conform value types to `Equatable` and `Hashable` when they represent data/identity
- **SHOULD** use `enum` with associated values instead of type codes or tagged unions

```swift
// MUST: struct for data models
struct UserProfile: Equatable, Codable {
    let id: UUID
    var displayName: String
    var avatarURL: URL?
}

// class only when reference semantics needed
class NetworkSession { ... }
```

## Error Handling (MUST)

```swift
// MUST: define domain-specific error types
enum NetworkError: Error, LocalizedError {
    case timeout(after: TimeInterval)
    case invalidResponse(statusCode: Int)
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .timeout(let duration):
            return "Request timed out after \(duration)s"
        case .invalidResponse(let code):
            return "Invalid response: HTTP \(code)"
        case .decodingFailed(let error):
            return "Decoding failed: \(error.localizedDescription)"
        }
    }
}

// MUST: use do-catch with specific error matching
do {
    let user = try await client.fetchUser(byID: 42)
} catch let error as NetworkError {
    logger.error("Network error: \(error)")
} catch {
    logger.error("Unexpected error: \(error)")
}
```

**MUST NOT:**

- Use `try!` — will crash at runtime on failure
- Use `try?` to silently discard error information without logging
- Throw untyped `NSError` from Swift code

## Optional Handling (MUST)

```swift
// MUST: guard let for early exit
guard let user = fetchedUser else {
    logger.warning("User not found")
    return
}

// if let for conditional binding
if let cached = cache[key] {
    return cached
}

// Nil coalescing for defaults
let name = user.displayName ?? "Anonymous"
```

**MUST NOT:**

- Force unwrap (`!`) without a documented invariant explaining why it is safe
- Use implicitly unwrapped optionals (`T!`) except for `@IBOutlet` or delayed initialization with clear lifecycle guarantees

## Concurrency (SHOULD)

```swift
// SHOULD: use async/await over callbacks
func fetchProfile(for userID: Int) async throws -> UserProfile {
    let data = try await networkClient.get("/users/\(userID)")
    return try decoder.decode(UserProfile.self, from: data)
}

// SHOULD: use structured concurrency for parallel work
func fetchDashboard() async throws -> Dashboard {
    async let profile = fetchProfile(for: currentUserID)
    async let notifications = fetchNotifications()
    return try await Dashboard(profile: profile, notifications: notifications)
}

// SHOULD: use actor for shared mutable state
actor ImageCache {
    private var storage: [URL: Image] = [:]

    func image(for url: URL) -> Image? { storage[url] }
    func store(_ image: Image, for url: URL) { storage[url] = image }
}
```

- **SHOULD** mark closures crossing isolation boundaries as `@Sendable`
- **SHOULD** prefer `TaskGroup` over spawning unstructured `Task` instances
- **MUST NOT** use `DispatchQueue` for new concurrency code — use Swift Concurrency

## Protocol-Oriented Design (SHOULD)

```swift
// SHOULD: define focused protocols, provide defaults via extensions
// Prefer standard library Identifiable when it fits your model.
protocol EntityIdentifiable {
    associatedtype ID: Hashable
    var id: ID { get }
}

protocol Displayable {
    var displayTitle: String { get }
}

extension Displayable where Self: EntityIdentifiable {
    var debugLabel: String { "\(displayTitle) (\(id))" }
}
```

- **SHOULD** compose behavior via protocol conformance rather than class inheritance
- **SHOULD** use generic constraints with `where` clauses for flexible APIs

## Access Control (SHOULD)

- **SHOULD** default to most restrictive access: `private` > `fileprivate` > `internal` > `public`
- **MUST** mark module API boundaries explicitly with `public` / `package`
- **SHOULD** use `private(set)` for read-only properties with internal mutation

## Testing (MUST for new features)

- Framework: Swift Testing (`@Test`, `#expect`) or XCTest
- **MUST** test both success and error paths
- **SHOULD** use parameterized tests for multiple input variations
- **SHOULD** mock dependencies via protocols, not concrete types

```swift
@Test("fetchProfile returns decoded user for valid ID")
func testFetchProfile() async throws {
    let client = MockNetworkClient(responseData: validUserJSON)
    let service = UserService(client: client)
    let profile = try await service.fetchProfile(for: 1)
    #expect(profile.displayName == "Alice")
}

@Test("fetchProfile throws on invalid response", arguments: [400, 404, 500])
func testFetchProfileErrors(statusCode: Int) async {
    let client = MockNetworkClient(statusCode: statusCode)
    let service = UserService(client: client)
    await #expect(throws: NetworkError.self) {
        try await service.fetchProfile(for: 1)
    }
}
```

## Common Pitfalls (MUST NOT)

- **MUST NOT** ignore compiler warnings — treat as errors in CI
- **MUST NOT** overuse `Any` / `AnyObject` — use generics or protocols with associated types
- **MUST NOT** retain `self` strongly in closures that outlive the object — use `[weak self]`
- **SHOULD NOT** use stringly-typed APIs when the compiler can enforce type safety
