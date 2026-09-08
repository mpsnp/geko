# MA-6685 — Full CI cache and consumption without local warming

> For agentic workers: use superpowers:subagent-driven-development or superpowers:executing-plans. Track the checkboxes and preserve unrelated working-tree changes.

**Goal:** CI warms every cacheable target for Avito Debug/Test; local generation downloads valid artifacts and retains source targets on misses without warming.
**Architecture:** Add explicit `geko generate --cache-only` alongside the existing `--cache` warm mode. Reuse graph loading, hashing, safe artifact substitution and final generation. The consume pipeline excludes framework and swiftmodule compilation and the intermediate warmup workspace. Wire opt-in remote-cache profiles in avito-project-gen; CI selects full.
**Tech stack:** Swift/SwiftPM, geko graph pipeline, avito-project-gen, Python CI, TeamCity.
**Spec:** https://jr.avito.ru/browse/MA-6685 (description updated with the approved contract).

## Constraints
- No hand-maintained Core/stable-module allowlist.
- Explicit focus remains sources; safe dependency closure is preserved.
- Missing artifacts remain sources; storage errors remain diagnostic failures without warmup.
- No cache artifact builder or swiftmodule builder in consume mode; later Xcode Build is allowed.
- Preserve current warm mode and source-only generation.
- Do not invent a released geko version or publish a binary as part of an unverified edit.

## Task 1 — geko CLI and pipeline
Files: Sources/GekoKit/Commands/GenerateCommand.swift; Sources/GekoKit/Services/Cache/CacheWarmService.swift; Sources/GekoCache/CachePipeline/Tasks/CacheGraphMutatingTask.swift; Tests/GekoKitTests/Commands/GenerateCommandTests.swift; Tests/GekoKitTests/Services/Cache/CacheWarmServiceTests.swift.
- [x] Add parsing tests for `--cache-only`, focus/profile preservation and rejection alongside `--cache`.
- [x] Add pipeline tests verifying consume mode has no CacheArchivingPipelineTask, SwiftModuleCachingTask or intermediate generation, while warm mode retains them.
- [x] Run targeted Swift tests and observe the missing feature fail.
- [x] Implement the consume branch with full-hash artifact substitution and cache-project cleanup, not the post-warm subset of newly built targets.
- [x] Verify existing artifact-substitution tests for empty/partial caches, focused targets and missing transitive dependencies; add missing coverage.
- [x] Document `geko generate --cache-only --profile Debug --no-open App` and unchanged CI `geko generate --cache --profile Debug --no-open` followed by `geko cache upload`.

## Task 2 — avito-project-gen and CI
Files: Targets/ExternalGenerators/Sources/Engines/Tuist/TuistFlavor.swift; TuistProjectGenerator.swift; Tests/TuistFlavorTests.swift; ci_automation/functional/run_tests/entrypoints/utils/warmup_remote_cache.py and its tests.
- [x] Test `.full` consumption -> `--cache-only --profile Debug`, `.external` -> additionally `--dependencies-only`, `.none`/disabled -> ordinary generation. Preserve Tuist behavior.
- [x] Pass the selected remote-cache profile into command construction; default remains explicit opt-in until compatible geko is available.
- [x] Change CI profile to full; verify Debug/Test both install and warm full, preserving credentials scope and dynamic linking.
- [x] Run targeted generator and Python tests.

## Task 3 — compatibility, end-to-end and rollout
- [x] Build modified geko locally and verify CLI help/flag validation.
- [x] Test a small fixture with full, partial and empty artifact storage; ensure no cache builder starts and resulting project builds.
- [ ] Review diffs, run appropriate targeted tests and record real results.
- [ ] Release a compatible geko binary through the existing reviewed release process before updating the repository version pin (currently 1.0.11-patch.2).
- [ ] Run CI full warming for Debug/Test, measure duration/artifact size, then consume using an isolated empty local cache and build Avito. Current job limit: 120 minutes.
- [ ] Record cache hits, source fallback and any rollout blocker. Do not claim S3/Avito checks passed from unit tests alone.

## Execution record
- Jira description and title updated; no status transition performed.
- Existing geko working-tree edits in LinkGenerator.swift, LinkGeneratorTests.swift and release/bundle.sh are unrelated and must be preserved.

### Local implementation and verification — 2026-09-08
- Added `--cache-only` and exclusive flag validation. The consume pipeline never includes framework or swiftmodule cache builders, uses complete target hashes for fetching, safely substitutes hits and removes the synthetic cache project.
- Added `ai install --remote-cache-profile` with explicit default `none`, forwarding to generator; `--skip-binary-cache` takes precedence.
- CI uses `full` and explicitly `generate_for_ci=False`: CI-only GCC_GENERATE_DEBUGGING_SYMBOLS=NO would otherwise invalidate internal target hashes relative to local consumers. AvitoDebug and AvitoTest both use Geko profile Debug.
- CI and ai install both use online.anero.app; direct avito-project-gen invocation needs an explicit matching --bundle-id.
- Geko: 27 targeted Swift tests passed. ai: 13 InstallCommandLogicTests passed. Python warmup: 2 tests passed. Generator command/profile/CI-settings regression tests: 18 passed. Total targeted tests: 60 passed.
- Five real iOS fixture scenarios passed both generation and subsequent Xcode build: full cache; only leaf cached; only parent cached; focused parent; empty cache. Assertions verified exact source target names and absence of synthetic cache project; generation logs contained no framework warmup. Results: /tmp/ma6685-e2e-summary.json, runner: /tmp/ma6685_e2e.py. Uses isolated fixture cache, not S3.
- Read-only review found CI/local settings mismatch; fixed. Existing unrelated geko changes preserved.
- Initial disposable macOS fixture had an invalid top-level executable source and hit existing XCFramework warmup limitations with explicit-dependency paths. Acceptance was re-run with a representative iOS framework chain using standard generation settings; all five cases passed.
- Release/rollout is still outstanding: the existing 1.0.11-patch.2 pin has no new flag. Do not merge/enable avito integration until a real compatible geko build is released and the pin updated. No binary published, CI run, S3 validation or full Avito build performed.

### Patch release preparation
- User explicitly authorized including all existing uncommitted geko changes because patch.2 was built from this state: LinkGenerator, its tests, and release coverage guard are included with cache-only changes.
- Binary and downstream pin version: 1.0.11-patch.3. Keep ProjectDescription dependency at the current release/1.1.0 revision; this patch retains the existing repository base.
- Produce a local universal macOS ZIP only, for manual Artifactory upload to ios-ci-ai/geko/1.0.11-patch.3/geko.zip. No push or publication.
