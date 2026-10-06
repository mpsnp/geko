---
title: Setup
order: 2
---

# Setup 

## Local Cache 

Geko uses a profile-based approach to warming up your project. Profiles allow Geko to know which configurations and targets to warm up the cache with. By default, there are two profiles: `Debug` and `Release`, which build the cache for iOS and the ARM architecture. To start using the cache locally in its basic configuration, you don't need to do anything extra. To get started, you can use one of the following commands:

```bash
geko generate --cache # All cachable modules will be cached 
geko generate App Auth --cache # Cache with focus on module App and Auth. All other modules will be pruned or cached
geko generate App Auth --cache --profile MyCustomProfile # Geko will use MyCustomProfile to warmup the cache
```

### Profiles 

You can create multiple [Cache.Profile](../../../projectdescription/structs/Cache.Profile) so that Geko knows which configurations and targets to use for cache warmup. To do this, you need to define all the parameters required for your build in the `Config.swift` manifest.

```swift
let config = Config(
    cache: .cache(
        profiles: [
            .profile(
                name: "Default", // Custom profile name. You can override Default profile with the same name and don't need to specify it in the command line
                configuration: "Debug", // Configuration to use for cache warmup
                platforms: [
                    .iOS: .options(arch: .arm64, os: "26.0", device: "iPhone 11") // Platforms and options to use for cache warmup
                ],
                scripts: [
                    .script(name: "SwiftGen", envKeys: ["SRCROOT"]) // List of build phase scripts to run before hashing
                ],
                options: .options() // Additional options for cache warmup
            )
        ]
    )
)
```

> [!NOTE]
> Geko supports building caches for multiple platforms simultaneously. In this case, you'll use xcframeworks instead of frameworks. However, using multiple platforms can significantly impact warm-up time. Therefore, we recommend separating different platforms into different profiles.

### Shared framework search paths

During workspace generation, Geko indexes searchable precompiled frameworks from the current dependency graph in `<workspace-root>/.geko/FrameworkSearchPaths`. This is not an index of every historical artifact in the build cache.

Searchable dependency results are cached by project path and target name for the lifetime of the graph traverser. The shared index is generated after parallel project generation and reuses those results, preserving dependency conditions, ignored dependencies, and test-host dependencies without a second transitive graph traversal.

Standalone `.framework` bundles are symlinked directly into this directory. Framework slices inside XCFrameworks are symlinked into platform-specific subdirectories, such as `iphoneos`, `iphonesimulator`, `macosx`, and `maccatalyst`. When a platform has separate architecture slices, these use additional architecture subdirectories. Links use the actual framework product name, which may differ from the target or XCFramework name. Generated framework, library, and Swift include search paths select the matching SDK, architecture, and Catalyst variant.

The generated `.manifest.json` tracks owned links. Subsequent generation updates changed destinations and removes stale owned links without replacing unrelated files or user-modified links. Distinct artifacts with the same framework name in the same platform/architecture namespace cause generation to fail. A standalone framework cannot shadow a different platform-specific framework with the same name.

Shared search paths expose frameworks from other targets in the same namespace, but declared linking and embedding dependencies remain target-specific. Cache artifacts and cache hashing are unchanged.

### Native XCFramework slice references

Generated Xcode projects reference the framework, static archive, or dynamic library inside an XCFramework instead of the XCFramework container. Project-level `GEKO_XCFRAMEWORK_<digest>` build settings select the native product path by SDK and, where needed, architecture. macOS and Mac Catalyst are selected independently using `IS_MACCATALYST`. The generated project therefore remains usable for different build destinations without regenerating it.

Native references retain dependency platform conditions and required, weak, or disabled linking status. Dynamic frameworks use native embedding phases. Optional XCFramework dSYM and bitcode symbol-map directories are selected by the same destination settings and copied by a dedicated symbols phase; that phase runs only for targets consuming symbol-bearing dependencies and is always out of date because symbol directories can be absent for a destination. Ambiguous or inconsistent slice metadata fails generation rather than selecting an arbitrary library.

This removes XCFramework container references from linking and embedding and avoids the corresponding `ProcessXCFramework` work. It does not reduce the number of declared target dependencies, and destination-selection settings can increase project-file size.

## Remote Cache 

Geko makes it very easy to set up your own remote cache. To do this, you need to set up your own S3 server using AWS or use any other S3 API-compatible service.

Once you have configured your S3, you need to specify information about it in your `Config.swift` file with [Config.cloud](../../../projectdescription/structs/Config#cloud).

```swift 
let confisg = Config(
    cloud: .cloud(
        bucket: "my-bucket-name",
        url: "my-url-to-s3"
    )
)
```

After this, Geko will start accessing your S3 server to download the pre-built modules when generating a project. If a module isn't found in S3, Geko will warm it up and save it only in the local cache.

If you require authentication to access your S3 server, you can declare access keys in your local ENV variables or in private variables within your repository. If your S3 server is only accessible within your private network, you can configure S3 to allow access to artifacts without authentication.

To provide Geko with authorization keys, you can use these ENV variables: 

```bash
export GEKO_CLOUD_ACCESS_KEY="your_access_key"
export GEKO_CLOUD_SECRET_KEY="your_secret_key"
```

### Upload cache artifacts

To save time during the project generation phase, Geko doesn't immediately upload completed artifacts to your cloud storage. They are first saved locally on your machine, and then you can decide whether to upload them.

To upload to cloud storage, use the following command: 

```bash 
geko cache upload 
``` 

Before upload you should declare ENV variables to access your s3 storage:


After each `geko generate --cache` command, the `.geko/Cache/BuildCache/latest_build` file is created, which contains information about the last warmup of the local cache. Using this file, the `upload` command determines which modules need to be loaded into the remote cache. This file is overwritten after each warmup.
