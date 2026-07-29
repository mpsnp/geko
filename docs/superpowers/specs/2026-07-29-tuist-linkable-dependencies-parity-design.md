# Tuist Linkable Dependencies Parity Design

## Context

When a source target depends on a cached dynamic external dependency, Geko links only the first cached binary and drops its transitive dynamic dependencies.

The observed graph is:

```text
AutoEnhanceImageModels
  -> ImageSource.framework
    -> AlamofireImage.framework
      -> Alamofire.framework
```

Geko generates a frameworks build phase containing only `ImageSource.framework`. Tuist generates one containing `ImageSource.xcframework`, `AlamofireImage.xcframework`, and `Alamofire.xcframework`.

The cache graph mutation preserves these dependency edges. They are removed later by `GraphTraverser.linkableDependenciesSearch`, which subtracts the complete transitive result behind every dynamic dependency. This also removes dynamic binaries, although only static binaries linked into the dynamic dependency should be excluded.

## Goal

Make Geko's linkable dependency calculation match Tuist's behavior for graph dependency types represented by Geko, while preserving Geko-specific ignored-dependency, platform-condition, test-host, and search-path behavior.

The implementation must restore transitive dynamic dependency linking without introducing duplicate linking of static binaries and without materially degrading project generation performance.

## Scope

The change covers:

- `GraphTraverser.linkableDependencies`
- `GraphTraverser.searchablePathDependencies`
- helper traversal methods required by the Tuist-derived algorithm
- regression tests for dynamic, static, SDK, test-host, ignored-dependency, and search-path behavior
- a generator-level regression test for the frameworks build phase
- debug performance instrumentation around project descriptor generation and linkable dependency calculation

The change does not cover:

- adding `swiftModules` or `moduleMaps` to `GraphDependency.XCFramework`
- porting Tuist's `StaticXCFrameworkModuleMapGraphMapper`
- adding Tuist graph variants such as `packageProduct` or `foreignBuildOutput`
- changing Geko's cache artifact format from `.framework` to `.xcframework`
- running the final Avito validation from the Geko repository workflow

## Architecture

### Linkable dependency calculation

Replace the generalized recursive collect-and-prune algorithm used by `linkableDependencies` with the explicit dependency categories used by Tuist.

For a requested target, build the result from:

1. System SDKs referenced by transitive static dependencies, when the target can link static products.
2. Direct system SDKs.
3. Direct and transitive precompiled dynamic libraries and frameworks.
4. Transitive static target dependencies, when the target can link static products.
5. Dynamic target and precompiled dependencies directly required by those static dependencies.
6. Direct dynamic target dependencies.
7. The required AppClip SDK for AppClip targets.

After constructing the result:

- exclude static products already linked behind a dynamic boundary;
- exclude static dependencies supplied by a unit-test host when calculating the test target's link phase;
- apply `graph.ignoredDependencies` to retain Geko's explicit ignore behavior;
- convert graph dependencies with the existing `dependencyReference(to:from:)` function so platform conditions and linking statuses continue to propagate through the existing mechanism.

The old `linkableDependenciesSearch` cache and lock may be removed after no callers remain. Performance optimization, if required, must cache the final result of the new semantics rather than restore the old pruning behavior.

### Search-path calculation

`searchablePathDependencies` will:

1. Start with `linkableDependencies` without excluding host-application dependencies.
2. Include static precompiled framework dependencies needed for module visibility.
3. Include transitive static dependencies behind direct dynamic framework targets.
4. Preserve Geko's existing inheritance of searchable paths from unit-test and UI-test hosts.

This intentionally differs from blindly copying Tuist because Geko has existing host search-path behavior that is not represented identically in the current Tuist implementation.

### Unsupported Tuist branches

Tuist distinguishes static Swift and Objective-C XCFramework dependencies by inspecting `swiftModules` and `moduleMaps`. Geko's `GraphDependency.XCFramework` does not contain those fields. The implementation must not guess this metadata or treat every static XCFramework as equivalent.

Those Tuist branches remain out of scope until the XCFramework metadata model and its graph mapper are migrated together.

## Required Behavior

| Dependency graph | Linkable result |
| --- | --- |
| target -> dynamic A -> dynamic B -> dynamic C | A, B, C |
| target -> dynamic A -> static B | A |
| target -> static A -> dynamic B | A, B |
| target -> static A -> static B | A, B |
| target -> dynamic A -> SDK | A and only directly required SDKs |
| target -> static A -> SDK | A, SDK |
| unit test -> dependencies already supplied by host app | Host static dependencies are excluded from the test link phase |
| target -> ignored dependency | The ignored dependency is excluded |
| target -> dynamic A -> static B | B is available through searchable paths but is not linked again |

For the original regression, `AutoEnhanceImageModels` must receive `ImageSource`, `AlamofireImage`, and `Alamofire` in its frameworks build phase.

## Performance Instrumentation

Performance instrumentation is added before changing the traversal algorithm so the old and new implementations can be measured with equivalent logging overhead.

### Measurements

Record:

- wall-clock duration of project descriptor generation;
- number of `linkableDependencies` calls;
- number of actual computations;
- number of cache hits when a final-result cache exists;
- accumulated computation time;
- maximum single computation time.

Use a monotonic clock based on `DispatchTime.uptimeNanoseconds` for internal measurements. Do not use `Date`, because wall-clock adjustments can distort short intervals.

Calls may execute concurrently. Protect aggregate counters with a lock. Accumulated computation time is a work metric and may include overlapping intervals. The project descriptor duration is the authoritative wall-time metric.

### Logging

Do not log each invocation. Emit one debug-level summary after concurrent project descriptor generation completes:

```text
Project descriptor generation took: 2.184s
linkableDependencies metrics: calls=1842 computations=922 cache_hits=920 total_compute_time=0.143s max_compute_time=0.004s
```

Normal non-verbose generation output remains unchanged.

### Performance gate

The current full Avito generation baseline is:

```text
Total time taken: 5.018s
```

Compare the median of three equivalent full-generation runs before and after the algorithm change.

A regression of at most 5% is treated as measurement noise. With the current baseline, the initial upper bound is approximately `5.27s`.

If the median full-generation time or project-descriptor phase regresses by more than 5%, the implementation is not complete. Add a thread-safe final-result cache keyed by target identity and the host-exclusion mode, then repeat the measurements. The cache must store results produced by the new algorithm.

The user will perform the final Avito timing and generated-project validation.

## Testing

### Graph traversal tests

Update or add tests covering:

- precompiled dynamic A -> precompiled dynamic B returns A and B;
- precompiled dynamic A -> B -> C returns all three dependencies;
- dynamic -> static returns only the dynamic dependency for linking;
- static -> dynamic returns both dependencies;
- static -> static returns both dependencies;
- system SDK through a static dependency is included;
- system SDK behind a dynamic dependency is not duplicated;
- unit-test host static dependencies are excluded from the test target's link phase;
- ignored direct and transitive dependencies remain excluded;
- platform conditions continue to be propagated;
- a static dependency behind a dynamic target is included in searchable paths but excluded from linkable dependencies.

### Generator test

Add a focused generator-level test with a source target depending on three cached dynamic frameworks in a chain. Verify that the generated `PBXFrameworksBuildPhase` contains all three binaries.

### Verification commands

Run the focused failing tests first, then:

- the complete `GekoCoreTests` target;
- the affected `GekoGeneratorTests` suite;
- formatting or lint checks required for the modified Swift files.

The final Avito validation is external to the automated Geko test suite and will be performed by the user.

## Rollout

The new behavior replaces the old behavior without a feature flag. The existing result is incorrect and causes compilation and linking failures, so retaining it as a selectable mode is not useful.

Implementation order:

1. Add aggregate performance instrumentation.
2. Capture the old-algorithm metrics on the representative project.
3. Add failing traversal and generator regression tests.
4. Port the supported Tuist linkable/searchable dependency semantics.
5. Run the complete affected test suites.
6. Capture new metrics.
7. Add final-result caching only if the performance gate fails.
8. Have the user validate generated Avito projects and full-generation timing.

## Acceptance Criteria

- Transitive precompiled dynamic dependencies are present in linkable results.
- Static dependencies behind dynamic boundaries are not linked a second time.
- Search paths retain modules available through dynamic dependencies.
- Existing ignored-dependency and test-host behavior remains covered and passing.
- The generator regression produces all expected framework build-file entries.
- Debug logs expose aggregate linkable-dependency and project-descriptor timings.
- Normal generation output is unchanged.
- Automated Geko tests pass.
- The user's Avito check confirms correct generated links.
- Median Avito generation time does not regress by more than 5%, or final-result caching brings it back within the accepted threshold.
