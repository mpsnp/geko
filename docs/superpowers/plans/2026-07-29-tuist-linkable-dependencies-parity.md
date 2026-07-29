# Tuist Linkable Dependencies Parity Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Geko generate the same linkable and searchable dependency sets as Tuist for dependency kinds supported by Geko, while preserving Geko-specific ignored dependencies, test-host handling, and generation performance.

**Architecture:** Replace the recursive “discover then subtract everything behind dynamic nodes” algorithm with Tuist’s explicit dependency-category unions. Add thread-safe aggregate timing around `linkableDependencies` and one outer project-descriptor phase timer. Keep XCFramework Swift-module metadata parity out of scope because Geko’s model does not expose the required metadata.

**Tech Stack:** Swift, Swift Package Manager, XCTest, XcodeProj, Dispatch monotonic clock.

---

## Scope and acceptance criteria

- `dynamic target -> dynamic target -> dynamic precompiled framework/library` remains linkable all the way through.
- `dynamic target -> static target` does not leak the static implementation dependency into the consumer’s link phase.
- Static dependency chains retain their existing link behavior.
- Search paths include static precompiled frameworks and static dependencies reachable behind dynamic framework targets, matching Tuist.
- `ignoredDependencies`, App Clip handling, SDK dependencies, and test-host exclusions continue to work.
- Normal CLI output is unchanged; aggregate metrics appear only at debug/verbose logging level.
- Median full Avito generation time over three runs is no more than 5% above the recorded `5.018s` baseline (`5.269s` threshold). If it exceeds that threshold, execute the conditional cache task before completion.
- The user will perform the final Avito project/Xcode validation; repository tests and focused generated-project evidence remain our responsibility.

## Task 1: Add deterministic aggregate metrics primitives

**Files:**

- Create: `Sources/GekoCore/Graph/LinkableDependenciesMetrics.swift`
- Create: `Tests/GekoCoreTests/Graph/LinkableDependenciesMetricsTests.swift`

- [ ] **Step 1: Write failing metrics tests**

Add tests that do not depend on wall-clock scheduling:

```swift
final class LinkableDependenciesMetricsTests: XCTestCase {
    func test_snapshotAggregatesCallsComputationsAndCacheHits() {
        let subject = LinkableDependenciesMetrics()

        subject.recordCall()
        subject.recordCall()
        subject.recordComputation(durationNanoseconds: 10)
        subject.recordComputation(durationNanoseconds: 25)
        subject.recordCacheHit()

        XCTAssertEqual(
            subject.snapshot(),
            LinkableDependenciesMetricsSnapshot(
                calls: 2,
                computations: 2,
                cacheHits: 1,
                totalComputationNanoseconds: 35,
                maximumComputationNanoseconds: 25
            )
        )
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter LinkableDependenciesMetricsTests
```

Expected: compilation fails because `LinkableDependenciesMetrics` and its snapshot do not exist.

- [ ] **Step 3: Implement the thread-safe accumulator**

Use an `NSLock`, integer nanosecond counters, and a value snapshot:

```swift
struct LinkableDependenciesMetricsSnapshot: Equatable {
    let calls: Int
    let computations: Int
    let cacheHits: Int
    let totalComputationNanoseconds: UInt64
    let maximumComputationNanoseconds: UInt64
}

final class LinkableDependenciesMetrics {
    private let lock = NSLock()
    private var calls = 0
    private var computations = 0
    private var cacheHits = 0
    private var totalComputationNanoseconds: UInt64 = 0
    private var maximumComputationNanoseconds: UInt64 = 0

    func recordCall() { /* mutate under lock */ }
    func recordCacheHit() { /* mutate under lock */ }
    func recordComputation(durationNanoseconds: UInt64) {
        /* increment computation count, total, and max under lock */
    }
    func snapshot() -> LinkableDependenciesMetricsSnapshot { /* copy under lock */ }
}
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
swift test --filter LinkableDependenciesMetricsTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GekoCore/Graph/LinkableDependenciesMetrics.swift Tests/GekoCoreTests/Graph/LinkableDependenciesMetricsTests.swift
git commit -m "test: add linkable dependency metrics"
```

## Task 2: Instrument traversal and the outer project-generation phase

**Files:**

- Modify: `Sources/GekoCore/GraphTraverser/GraphTraversing.swift`
- Modify: `Sources/GekoCore/Graph/GraphTraverser.swift`
- Modify: `Sources/GekoGenerator/Generator/WorkspaceDescriptorGenerator.swift`
- Modify: `Tests/GekoCoreTests/Graph/LinkableDependenciesMetricsTests.swift`

- [ ] **Step 1: Add formatting coverage**

Extend metrics tests to assert a stable single-line summary, including zero-safe average calculation:

```swift
XCTAssertEqual(
    snapshot.debugDescription,
    "calls=2 computations=2 cacheHits=1 total=0.000000035s average=0.000000018s max=0.000000025s"
)
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter LinkableDependenciesMetricsTests
```

Expected: FAIL because the summary formatter is absent.

- [ ] **Step 3: Add traversal instrumentation**

In `GraphTraversing`, add an optional hook with a no-op default so existing mocks and alternate implementations do not need boilerplate:

```swift
func logLinkableDependenciesMetrics()

extension GraphTraversing {
    public func logLinkableDependenciesMetrics() {}
}
```

In `GraphTraverser`:

- store one `LinkableDependenciesMetrics`;
- call `recordCall()` at entry to public `linkableDependencies`;
- measure only actual traversal computation with `DispatchTime.now().uptimeNanoseconds`;
- record elapsed time in a `defer`;
- emit exactly one debug line from `logLinkableDependenciesMetrics()`.

Use monotonic elapsed time:

```swift
let start = DispatchTime.now().uptimeNanoseconds
defer {
    linkableDependenciesMetrics.recordComputation(
        durationNanoseconds: DispatchTime.now().uptimeNanoseconds - start
    )
}
```

- [ ] **Step 4: Add the outer phase timer**

In `WorkspaceDescriptorGenerator.generate(graphTraverser:)`, measure only the concurrent project descriptor creation block:

```swift
let projectGenerationStart = DispatchTime.now().uptimeNanoseconds
let projects = try await /* existing concurrent/serial generation */
let projectGenerationNanoseconds =
    DispatchTime.now().uptimeNanoseconds - projectGenerationStart

logger.debug(
    "Project descriptor generation took: \(seconds(projectGenerationNanoseconds))s"
)
graphTraverser.logLinkableDependenciesMetrics()
```

Keep these at debug level so non-verbose generation output is unchanged.

- [ ] **Step 5: Run focused suites**

Run:

```bash
swift test --filter LinkableDependenciesMetricsTests
swift test --filter WorkspaceDescriptorGeneratorTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/GekoCore/GraphTraverser/GraphTraversing.swift Sources/GekoCore/Graph/GraphTraverser.swift Sources/GekoGenerator/Generator/WorkspaceDescriptorGenerator.swift Tests/GekoCoreTests/Graph/LinkableDependenciesMetricsTests.swift
git commit -m "feat: log linkable dependency performance"
```

## Task 3: Port Tuist linkable-dependency semantics

**Files:**

- Modify: `Tests/GekoCoreTests/Graph/GraphTraverserTests.swift`
- Modify: `Sources/GekoCore/Graph/GraphTraverser.swift`

- [ ] **Step 1: Update and extend regression tests**

Change the existing dynamic-to-dynamic expectation from only the first dependency to both dependencies:

```swift
// subject -> dynamicA -> dynamicB
XCTAssertEqual(
    try subject.linkableDependencies(path: subjectPath),
    [
        GraphDependencyReference(product: dynamicA, condition: nil),
        GraphDependencyReference(product: dynamicB, condition: nil),
    ]
)
```

Add a three-level regression matching the Avito failure shape:

```swift
// AutoEnhanceImageModels -> ImageSource -> AlamofireImage -> Alamofire
// all products are dynamic/linkable
XCTAssertEqual(
    try subject.linkableDependencies(path: modelsPath),
    references(for: [imageSource, alamofireImage, alamofire])
)
```

Retain explicit tests for:

- dynamic target -> static target: only the dynamic target is linked;
- static target -> dynamic target: both are linked;
- ignored transitive dynamic dependency: it is removed from the final set;
- test-host dependency exclusion: existing behavior is unchanged.

- [ ] **Step 2: Run graph traversal tests and verify the regression fails**

Run:

```bash
swift test --filter GraphTraverserTests
```

Expected: the dynamic-to-dynamic and three-level tests FAIL because the current subtraction algorithm removes dependencies behind dynamic nodes.

- [ ] **Step 3: Replace subtraction with explicit Tuist-style unions**

Remove `linkableDependenciesSearchCache`, its lock, and `linkableDependenciesSearch`. Build the result from explicit categories:

```swift
var references = Set<GraphDependencyReference>()

let transitiveStaticDependencies = try transitiveLinkableStaticDependencies(path: path)
references.formUnion(
    try transitiveStaticDependencies
        .flatMap { try systemLibraries(path: $0) }
        .map(dependencyReference)
)

// Preserve App Clip and direct SDK handling.

let precompiledDynamics = try filterDependencies(
    from: path,
    test: or(isDependencyDynamicLibrary, isDependencyFramework)
).filter(\.isPrecompiled)
references.formUnion(precompiledDynamics.map(dependencyReference))

if target.canLinkStaticProducts {
    // Add transitive linkable static products.
    // Preserve host-app subtraction.
    // Add dynamic target dependencies and direct precompiled linkables
    // reachable from the static dependency closure.
}

let directDynamicDependencies = try directDependencies(path: path)
    .filter(or(isDependencyDynamicLibrary, isDependencyFramework))
references.formUnion(directDynamicDependencies.map(dependencyReference))

return references.filter { !ignoredDependencies.contains($0.product) }
```

Important implementation constraints:

- use Geko’s existing `transitiveLinkableStaticDependencies`, whose skip rule already matches Tuist’s “do not traverse through dynamic products” behavior;
- preserve `dependencyReference` condition mapping;
- preserve `ignoredDependencies` as the final filter;
- do not add Tuist-only package-product or foreign-build cases;
- do not port XCFramework `swiftModules/moduleMaps` logic because those fields are absent in Geko.

- [ ] **Step 4: Run graph traversal tests and verify they pass**

Run:

```bash
swift test --filter GraphTraverserTests
```

Expected: PASS, including old static, SDK, App Clip, ignored dependency, and test-host cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/GekoCore/Graph/GraphTraverser.swift Tests/GekoCoreTests/Graph/GraphTraverserTests.swift
git commit -m "fix: retain transitive dynamic linkable dependencies"
```

## Task 4: Port Tuist searchable-path semantics

**Files:**

- Modify: `Tests/GekoCoreTests/Graph/GraphTraverserTests.swift`
- Modify: `Sources/GekoCore/Graph/GraphTraverser.swift`

- [ ] **Step 1: Add failing searchable-path regressions**

Add focused tests for:

1. a static precompiled framework reachable from the target is included;
2. a static target reachable behind a dynamic framework target is included;
3. existing test-host searchable-path recursion remains included.

Example graph:

```swift
// consumer -> dynamicFrameworkTarget -> staticImplementationTarget
XCTAssertTrue(
    try subject.searchablePathDependencies(path: consumerPath)
        .contains(staticImplementationTarget)
)
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
swift test --filter GraphTraverserTests
```

Expected: at least the “static behind dynamic framework target” case FAILS under the current searchable-path union.

- [ ] **Step 3: Add the two Tuist-derived helper queries**

Implement Geko-compatible variants:

```swift
private func staticPrecompiledFrameworksDependencies(
    path: GraphDependency
) throws -> Set<GraphDependency> {
    try filterDependencies(
        from: path,
        test: and(isDependencyFramework, not(isDependencyDynamicFramework))
    ).filter(\.isPrecompiled)
}

private func transitiveStaticDependenciesOfDynamicFrameworkDependencies(
    path: GraphDependency
) throws -> Set<GraphDependency> {
    let dynamicFrameworkTargets = try directDependencies(path: path)
        .filter(and(\.isTarget, isDependencyDynamicFramework))

    return try dynamicFrameworkTargets.reduce(into: Set<GraphDependency>()) {
        $0.formUnion(try transitiveStaticDependencies(path: $1))
    }
}
```

Update `searchablePathDependencies` to union:

- linkable dependencies;
- static precompiled framework dependencies;
- static dependencies behind direct dynamic framework targets;
- test-host searchable paths, as today.

- [ ] **Step 4: Run graph traversal tests and verify they pass**

Run:

```bash
swift test --filter GraphTraverserTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GekoCore/Graph/GraphTraverser.swift Tests/GekoCoreTests/Graph/GraphTraverserTests.swift
git commit -m "fix: align searchable dependency paths with Tuist"
```

## Task 5: Add a generator-level linking contract test

**Files:**

- Modify: `Tests/GekoGeneratorTests/Generator/LinkGeneratorTests.swift`

- [ ] **Step 1: Add the contract test**

Stub the traverser with three dynamic framework references analogous to `ImageSource`, `AlamofireImage`, and `Alamofire`, create the corresponding PBX file references, generate the linking phase, and assert all three build files exist:

```swift
mockGraphTraverser.stubbedLinkableDependenciesResult = [
    .testFramework(path: "/ImageSource.framework"),
    .testFramework(path: "/AlamofireImage.framework"),
    .testFramework(path: "/Alamofire.framework"),
]

let buildPhase = try subject.generateLinkingPhase(/* existing fixture */)

XCTAssertEqual(
    Set(buildPhase.files?.compactMap(\.file?.path) ?? []),
    [
        "ImageSource.framework",
        "AlamofireImage.framework",
        "Alamofire.framework",
    ]
)
```

This verifies that the graph result is not lost between `GraphTraverser` and the PBX frameworks build phase.

- [ ] **Step 2: Run the focused generator tests**

Run:

```bash
swift test --filter LinkGeneratorTests
```

Expected: PASS. If it fails, fix only the propagation defect exposed by the test; do not broaden graph behavior here.

- [ ] **Step 3: Commit**

```bash
git add Tests/GekoGeneratorTests/Generator/LinkGeneratorTests.swift
git commit -m "test: cover transitive dynamic framework linking"
```

## Task 6: Measure performance against the Avito baseline

**Files:**

- No source changes unless the threshold is exceeded.

- [ ] **Step 1: Build a release binary once**

Run:

```bash
swift build -c release
```

Expected: PASS. Reuse the same binary for all measurements to exclude compilation time.

- [ ] **Step 2: Run one verbose warm-up generation**

Run the existing Avito full-generation command with Geko’s verbose/debug flag and capture:

- outer `Project descriptor generation took`;
- linkable summary: calls, computations, cache hits, total, average, max;
- existing `Total time taken`.

Do not include this warm-up in the median.

- [ ] **Step 3: Run three measured generations**

Use the same checkout, configuration, caches, command, and release binary. Record all three total times and compute the median.

- [ ] **Step 4: Apply the threshold**

- If median `<= 5.269s`: skip Task 7 and proceed to Task 8.
- If median `> 5.269s`: execute Task 7 before proceeding.

The user may run this checkpoint locally if the Avito workspace cannot be mutated or generated safely from this environment.

## Task 7: Conditional final-result cache

**Execute only if Task 6 exceeds the 5% threshold.**

**Files:**

- Modify: `Sources/GekoCore/Graph/GraphTraverser.swift`
- Modify: `Tests/GekoCoreTests/Graph/GraphTraverserTests.swift`
- Modify: `Tests/GekoCoreTests/Graph/LinkableDependenciesMetricsTests.swift`

- [ ] **Step 1: Add a cache-hit regression**

Call `linkableDependencies(path:shouldExcludeHostAppDependencies:)` twice for the same key and assert:

- both returned sets are equal;
- calls are `2`;
- computations are `1`;
- cache hits are `1`.

Expose an internal metrics snapshot only as needed for `@testable` tests.

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter GraphTraverserTests
```

Expected: FAIL because both calls currently compute.

- [ ] **Step 3: Implement a lock-protected final-result cache**

Key by both inputs:

```swift
private struct LinkableDependenciesCacheKey: Hashable {
    let path: GraphDependency
    let shouldExcludeHostAppDependencies: Bool
}
```

On every call:

1. record the call;
2. read the cache under lock;
3. on hit, record a cache hit and return;
4. compute without holding the cache lock;
5. store the final set under lock;
6. record computation time.

Concurrent duplicate misses are acceptable; never serialize the whole graph computation behind the cache lock.

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter GraphTraverserTests
swift test --filter LinkableDependenciesMetricsTests
```

Expected: PASS.

- [ ] **Step 5: Repeat Task 6 measurement**

Expected: median returns to `<= 5.269s`. If not, use the aggregate totals/max values to identify whether traversal is actually the regression before introducing any broader cache.

- [ ] **Step 6: Commit**

```bash
git add Sources/GekoCore/Graph/GraphTraverser.swift Tests/GekoCoreTests/Graph/GraphTraverserTests.swift Tests/GekoCoreTests/Graph/LinkableDependenciesMetricsTests.swift
git commit -m "perf: cache final linkable dependency results"
```

## Task 8: Full verification and handoff

**Files:**

- Review all changed source and test files.

- [ ] **Step 1: Run core and generator suites**

Run:

```bash
swift test --filter GekoCoreTests
swift test --filter GekoGeneratorTests
```

Expected: PASS with zero failures.

- [ ] **Step 2: Run the full package test suite**

Run:

```bash
swift test
```

Expected: PASS with zero failures.

- [ ] **Step 3: Inspect the final diff**

Run:

```bash
git diff --check
git status --short
git log --oneline --decorate -8
```

Expected:

- `git diff --check` produces no output;
- no unintended files are modified;
- commits map to the tasks above.

- [ ] **Step 4: Self-review against the design**

Confirm:

- every supported Tuist dependency category is represented;
- every Geko-specific behavior named in the acceptance criteria remains covered;
- no XCFramework metadata expansion slipped into scope;
- instrumentation remains aggregate-only and debug-only;
- no measured performance claim is made without recorded output.

- [ ] **Step 5: Prepare the user handoff**

Report:

- branch name and commits;
- focused/full test results;
- recorded metrics and median, or an explicit note that the user-owned Avito measurement remains;
- the exact `AutoEnhanceImage/AutoEnhanceImage.xcodeproj` / `AutoEnhanceImageModels` check the user should perform;
- whether conditional caching was required.

