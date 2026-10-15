# Native validation

All fixture tests use authored text, synthetic chunk files, or injected fake AI providers. They do not establish Apple on-device, Private Cloud Compute, or OpenAI-compatible inference success.

## Installed tools checked on 2026-10-14

- Xcode **27.0**, build **27A266a** at `/Applications/Xcode.app`.
- Apple Swift **6.4**, `swiftlang-6.4.0.34.1`, clang `2100.3.34.1`.
- iOS and iOS Simulator SDK **27.0** installed under the corresponding Xcode platform SDK directories.
- Installed available iOS simulator runtimes include 17.0, 17.2, 18.6, 26.0, 26.2, and 27.0. No SDK or runtime was installed for this work.
- The project retains iOS **17.0** deployment and Swift **5.0** language mode. The baseline built app's `MinimumOSVersion` is `17.0`.

The installed FoundationModels declarations were inspected before migration. A separate real-SDK schema/error probe on macOS 27 encoded all six schemas and constructed quota, network, service, and context errors without creating a model session or performing inference. Encoded schema sizes were:

| Output | JSON-encoded schema bytes |
| --- | ---: |
| Overview | 294 |
| Takeaways | 482 |
| Chapters | 487 |
| Mind map | 684 |
| Insights | 544 |
| Snip note | 140 |

All fit the conservative 1,536-byte schema budget reserve. The hosted iOS suite also checks these schemas and the actual SDK error constructors when the runtime supports them.

## Baseline

The existing PR head `b842b39497c9d54ec10586d05b705cdc9bfc15bc` passed a native simulator build before the AI service migration:

```sh
xcodebuild -project PodSnip.xcodeproj -scheme PodSnip \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/baseline CODE_SIGNING_ALLOWED=NO build
```

The initial restricted execution could not communicate with CoreSimulator and prevented SwiftData compiler macro plugins from responding. The same authorized build with access to those installed local services completed with `BUILD SUCCEEDED`. No license, account, signing, entitlement, or device permission settings were changed.

## Executed fixture validation (historical AI change)

The following results belong to the 2026-10-14 work through `0774679bd091ce7ade63ebc9776f84688f104a1a`. They are not a native test result for the later persistence-regression changes.

The migrated app passed a native generic iOS 27 simulator build for both simulator architectures with signing disabled. The complete suite contains **35 unit/contract tests** (23 service, 8 intercepted HTTP transport, and 4 regression tests), plus **1 UI navigation test**. Runtime-specific tests skip explicitly when their SDK APIs cannot run:

| Simulator runtime | Unit/contract result | UI result |
| --- | --- | --- |
| iOS 17.0.1 | 35 recorded, 3 expected skips, 0 failures | 1 passed |
| iOS 26.0 | 35 recorded, 1 expected skip, 0 failures | 1 passed |
| iOS 27.0 | 35 passed, 0 skips, 0 failures | 1 passed |

The iOS 17 skips are real FoundationModels schema construction, iOS 26 generation-error constructors, and iOS 27 PCC/context-error constructors. This run confirms the app and test host launch on the retained deployment target without loading unavailable APIs. All 8 operations and all 3 route choices are exercised through injected providers on every runtime.

On iOS 26, schema construction and legacy generation-error mapping executed successfully; only the iOS 27 PCC/context-error fixture was skipped. On its first empty-database launch, SwiftData logged a missing persistent-store parent directory and then explicitly reported successful automatic recovery. Both the hosted suite and UI launch completed successfully.

On iOS 27, the complete fixture suite passed, including schemas, iOS 26/27 SDK error constructors, and all intercepted HTTP transport cases. Live generation remains outside these tests.

## Reproduce fixture tests

`project.yml` is the source of truth. The generated project contains a hosted `PodSnipTests` unit-test target and a `PodSnipUITests` target in the shared `PodSnip` scheme:

```sh
xcodegen generate
xcodebuild -project PodSnip.xcodeproj -scheme PodSnip \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,id=YOUR_TEST_SIMULATOR_UUID' \
  -destination-timeout 60 -derivedDataPath .build/validation \
  -parallel-testing-enabled NO -jobs 2 CODE_SIGNING_ALLOWED=NO test
```

Use a fresh simulator with an already installed runtime to keep the app database and Keychain empty. The UI smoke test only navigates the empty library, Snips, and settings; it does not press connection testing, request Speech access, open audio, or invoke a model.

## Previous PR regressions

- **Timestamp offset:** the production segment-grouping helper has synthetic second- and third-chunk assertions at offsets 240 and 480 seconds. Each offset is added once; sentence/duration boundaries keep absolute times.
- **Temporary files:** the production working-directory helper is exercised with overlapping invocations and identically named synthetic chunk files; removing one directory preserves the other's file, and removing both leaves the parent empty.
- **Transcription busy state:** `PlayerView.doTranscribe()` still uses a `defer` that clears busy/progress on exit. A Speech authorization/recognition failure was not induced because device permissions and audio input are outside this validation.
- **Remote commands:** `AudioPlayer` retains the one-time `remoteCommandsConfigured` guard. Lock-screen/headphone delivery and background playback require device acceptance; playback and remote controls were not exercised here.

The Speech usage description and `UIBackgroundModes: [audio]` are declared in `project.yml`, generated into `Info.plist`, and checked in the hosted fixture suite. These declarations do not grant Speech or microphone access.

## Runtime acceptance still required

Apple model inference remains unverified until tested on an eligible device with Apple Intelligence enabled and the model ready. PCC additionally requires the managed `com.apple.developer.private-cloud-compute` entitlement and Apple eligibility, which are unknown. No entitlement was requested and no live provider inference or stored API credential was used for this work.

The new optional `Snip.aiError` field was previously exercised in fresh and in-memory stores. Authored legacy-store generation and four persistence regression tests are now implemented below, but have not run natively in the 2026-10-15 environment. Successful persisted migration and startup remain unverified; no private store was inspected. Legacy plain-text and JSON note display remain covered by the earlier synthetic value fixtures.


## Persisted-store upgrade regression (2026-10-15)

### Schema review and fixture provenance

Reviewed old `PodSnip/Models.swift` at `8d72603772330660f12638c75691656e597a5fc2` against PR head `0774679bd091ce7ade63ebc9776f84688f104a1a`. The only model-source changes are `Snip.aiError: String?` and `self.aiError = nil`. PodcastFeed/EpisodeItem properties, UUID uniqueness, the cascade relationship, transcript JSON storage, and existing Snip fields are unchanged. An optional addition is a candidate for automatic lightweight migration; source review is not proof that an installed OS successfully migrates the store.

`Tests/RegressionTests.swift` includes `LegacyPodSnipV1`: the frozen historical source wrapped in a namespace, with the same model names, types, optionality, uniqueness, and relationship annotations. It deliberately uses an ordinary `Schema`, not a newly invented `VersionedSchema` or current-model typealiases: the old app used an unversioned schema. Removing the wrapper and restoring the two imports reproduces Git blob `5bac94f227dfeddbcd40831335c1312ffb6c5284` exactly. `scripts/check_legacy_schema.py` checks that hash and the strictly additive current-model diff.

The native fixture generator inserts only old-model instances into a unique temporary on-disk `default.store`, explicitly saves, releases its container/context, verifies the SQLite header and public Core Data model-version metadata, and reopens with the old schema to check 2 feeds, 3 episodes and 4 Snips. It then closes that scope before opening the identical URL with the production factory. No live-container file copy is made, so SQLite WAL/SHM data cannot be accidentally omitted. Cleanup removes only the test-owned temporary directory, after all open scopes finish.

The fixture contains authored Unicode, fractional/long timestamps, all seven optional Episode payload fields, raw transcript JSON, Markdown summaries, takeaways/chapters/mind-map/insights JSON, JSON and plain-text AI notes, nil versus empty values, an empty feed, an unattached episode, and a Snip without an episode ID. Reserved `.invalid` URLs and the explicitly synthetic local audio path are never read or fetched. No private database, media, API key, model provider or CloudKit account is used.

### Implemented native cases — not yet executed

`PersistenceMigrationTests` is in the existing compiled `RegressionTests.swift`, so both the tracked project and XcodeGen definition include it without project regeneration. Four additional tests bring the authored unit/contract count to 39; the historical 35-test results above do not cover them.

| Test | Required assertions |
| --- | --- |
| Populated legacy store | Same UUID sets/counts, feed relationships, every persisted field, exact UTF-8 payloads and decoded transcript times/text; all existing aiError values are nil; only Snip's stored schema hash changes. |
| Reopen and error updates | Upgrade, save an aiError, release/reopen, verify all old data, clear it, release/reopen again; old JSON/plain-text notes and transcript bytes remain unchanged. |
| Empty legacy store | Open a real empty old-schema SQLite store, observe the Snip hash transition, insert/save a new Snip with nil aiError, and fetch it after another reopen. |
| Invalid existing store | The shared throwing factory reports failure instead of returning an empty/in-memory container, and the authored invalid file remains byte-identical. |

`PodSnipPersistence.makeContainer()` is now shared by app startup and these tests. With no URL, it preserves the original persistent default configuration/location; test URLs explicitly disable CloudKit and point only to disposable storage. No new versioned migration plan, store reset or fallback was introduced without evidence of a migration defect. The app's existing fatalError policy for unrelated initialization failures is unchanged; valid-upgrade tests exercise the same throwing initializer without having XCTest itself abort via fatalError.

### Actual execution status of this change

Environment: Linux x86_64, Swift 6.2.1; no Xcode, iOS SDK, CoreSimulator, or SwiftData module is available in this execution environment.

| Check | Result for this change |
| --- | --- |
| Frozen historical source hash / allowed model delta / shared factory guard | PASS (Python static source checks) |
| Swift 5 language-mode syntax parse of Models.swift, PodSnipApp.swift and RegressionTests.swift | PASS (Linux compiler frontend; not type-checking or macro expansion) |
| Native runner shell syntax | PASS (`bash -n`) |
| Native runner preflight | Correctly refused with exit 2 / NOT RUN on Linux |
| iOS 17, 26 and 27 migration tests | NOT RUN |
| SwiftData-generated SQLite fixture artifact in this environment | NOT GENERATED; generation is implemented inside the native tests |
| Successful production ModelContainer initialization against a legacy store | NOT VERIFIED |

No migration failure was reproduced and no successful migration is claimed. The tests can expose native model-identity, macro, API or migration issues that a Linux syntax parser cannot. Runtime-generated fixtures exercise a same-runtime old-schema-to-new-schema transition; they are not historical OS-generated binary fixtures and do not yet prove an iOS 17-created database upgrades under iOS 27.

### Reproduce safely on Xcode 27+

Run the provenance guard, then select already-installed runtime/device-type IDs. The runner creates and deletes its own fresh simulator instead of reusing a real device or existing simulator. It does not install runtimes, accept licenses, enroll accounts, change signing, grant permissions, or call model providers.

```sh
python3 scripts/check_legacy_schema.py
xcrun simctl list runtimes
xcrun simctl list devicetypes
bash scripts/test_persistence_migration.sh \
  com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
  com.apple.CoreSimulator.SimDeviceType.iPhone-15
```

The IDs above are examples; both must exist locally and be compatible. Repeat with the installed iOS 17 and 26 runtime IDs and a supported device type. The script runs only `PodSnipTests/PersistenceMigrationTests`, disables signing and parallel tests, and saves the source SHA, working-tree diff summary, destination, build log and `.xcresult` under a unique `.build/migration-*` directory. Before changing any NOT RUN entry, inspect the bundle and confirm all four tests actually executed (zero skips/failures), then record the exact tested SHA, Xcode build, runtime and results. Re-run the complete unit/UI suite afterward; keep the PR Draft until its remaining acceptance gates are met.
