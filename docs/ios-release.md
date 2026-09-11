# iOS release

The `iOS TestFlight` workflow builds a signed iOS binary on a GitHub-hosted
macOS runner and uploads it to TestFlight. It needs no EAS Build, no Mac, and no
local Xcode. It runs on demand from the Actions tab, with an optional tag to
build. There is no tag trigger; see "Overlap with EAS" below.

Signing uses fastlane match. One Apple Distribution certificate and one App
Store profile live encrypted in a private repo, so the runner stays stateless
and renewal is a re-run instead of a rescue operation.

## Jobs

Building and uploading are separate jobs so a rejected upload does not cost
another 18-minute archive.

- `build` prebuilds the Xcode project, signs with match, and runs the
  `build_ipa` lane, which writes `packages/app/build/rambla.ipa` and
  `rambla.app.dSYM.zip`. Both go up as the `ios-build` artifact. That step runs
  even when the build step failed, so whatever was produced is still downloadable.
- `upload` downloads the artifact and runs `upload_ipa`. That lane calls neither
  match nor `build_app`, so this job gets no SSH deploy key, no `MATCH_PASSWORD`,
  and no `MATCH_REPO_URL` — the App Store Connect API key is all an upload needs.
  Re-run this job alone to retry a failed upload against the same binary.
- `submit-review` runs after `upload`.

Untick `upload_to_testflight` on dispatch to produce the artifact without
sending it to Apple.

The lane paths are fixed rather than fastlane's default location because the
workflow has to name the file in a later job. `build_ipa` passes
`output_directory` and `output_name` to `build_app`; the `beta` lane still
exists and calls both lanes back to back.

## Secrets

All of these are repo secrets, except `GOOGLE_SERVICE_INFO_PLIST_PROD_BASE64`,
which is not set.

- `APPLE_TEAM_ID` — the ten-character Apple Developer team ID.
- `ASC_KEY_ID`, `ASC_ISSUER_ID` — App Store Connect API team key with the Admin
  role. App Manager cannot create signing certificates.
- `ASC_KEY_P8_BASE64` — `base64 -w0` of the downloaded `AuthKey_XXXX.p8`. The
  file is PEM text; the base64 only protects it in transit. Apple offers the
  download once.
- `MATCH_REPO_URL` — `git@github.com:getrambla/ios-certificates.git`. SSH, not
  HTTPS.
- `MATCH_GIT_PRIVATE_KEY` — ed25519 private key with write access to that repo.
  Both workflows load it into an ssh-agent before any fastlane step.
- `MATCH_PASSWORD` — the passphrase that encrypts the certificate repo. Nothing
  can recover it; losing it means revoking the certificate and bootstrapping
  again.
- `GOOGLE_SERVICE_INFO_PLIST_PROD_BASE64` — optional. When unset, the build
  omits Firebase and still succeeds.

## Bootstrap

Run `iOS Signing Bootstrap` once from the Actions tab. It calls the
`sync_signing` lane with `readonly:false`, which creates the certificate and the
`sh.rambla` App Store profile through the App Store Connect API and commits them
encrypted to the match repo. It is green when `certs/distribution/` and
`profiles/appstore/` exist there.

Every build run uses `readonly: true`, so a build can never mint a new
certificate. Apple caps distribution certificates at two or three per account,
and per-run `cert`/`sigh` burns through that cap.

## Renewal

Provisioning profiles expire after one year and certificates after three.
Builds fail once the profile expires. Re-run `iOS Signing Bootstrap`; it
replaces the expired asset in the match repo and nothing else changes.

## Build numbers

CFBundleVersion comes from `packages/app/package.json` through
`packages/app/native-release-version.js`, described in
[release.md](release.md#mobile-builds-eas). Prebuild writes it into
`Info.plist`, so CI never bumps anything. Re-running the same tag re-uploads the
same CFBundleVersion and App Store Connect rejects it with ITMS-4238; cut the
next beta rather than patching the workflow.

## App Store review

Dispatch the workflow with `submit_for_review: true`. The `submit-review` job
reuses the `submit_review` lane, which polls App Store Connect until the build reaches
`VALID` and then submits it. It runs only when you tick that box.

## Overlap with EAS

Upstream's EAS workflows still declare tag triggers:
`release-ios-beta.yml` on `v*-beta.*` and `release-mobile.yml` on `v*` excluding
beta and rc, which also submits for App Store review. They cannot run while the
Expo project is disconnected from the repo, and they are left untouched to keep
upstream merges clean. This workflow has no tag trigger so that connecting Expo
later cannot produce two builds racing to upload the same CFBundleVersion.

## Gems

`packages/app/Gemfile.lock` is not committed, so both workflows run
`bundle install` with `bundler-cache: false`. Committing the lockfile enables
gem caching.
