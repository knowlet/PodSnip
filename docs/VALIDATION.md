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

## Executed fixture validation

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

The new optional `Snip.aiError` field was exercised in fresh and in-memory stores. Migration of an existing persisted store from the previous model schema has not been tested with an authored legacy-store fixture; no private store was inspected. Legacy plain-text and JSON note display are covered by synthetic value fixtures.
