# In-app updates

OOO updates itself from this repository's GitHub releases, through [Sparkle](https://sparkle-project.org) 2.10.0, the same way pitch.dog's Drift, Galileo and Backdrop do. The full guide, with the reasons behind each rule, is [Drift's UPDATES.md](https://github.com/bomkino/pitchdog-drift/blob/main/docs/UPDATES.md). This page is what is specific to OOO.

No Apple Developer account is involved. OOO is signed ad hoc. Updates are trusted because each one carries an EdDSA signature that only pitch.dog's private key can make, and OOO has the matching public key built in.

## How it works

1. Every release carries four files: `OOO-x.y.z-macOS-arm64.dmg` (for people), `OOO-x.y.z-macOS-arm64.zip` (for the updater), `appcast.xml` (the feed) and `SHA256SUMS.txt`.
2. OOO's `Info.plist` names the feed `https://github.com/bomkino/ooo/releases/latest/download/appcast.xml`. GitHub redirects that address to the `appcast.xml` of the release marked **Latest**.
3. Once a day, and whenever someone chooses **OOO › Check for Updates…**, Sparkle reads the feed. If it lists a newer version, OOO shows the release notes and an Install button.
4. Sparkle downloads the ZIP, checks its signature against `SUPublicEDKey`, swaps the app in place and relaunches it. A ZIP that doesn't match is refused.

| | |
|---|---|
| Public key (`SUPublicEDKey`, in `scripts/build-app.sh`) | `P43E8I+FgVyAW3QkS4J9bnDRRhAnsS4y3dT2WDce1lQ=` |
| Private key, for CI | The `SPARKLE_PRIVATE_KEY` secret of this repository's `release` environment, which only `main` may use |
| Private key, on the release Mac | `~/Library/Application Support/pitch.dog/Release Keys/sparkle-ed25519-private.key`, backed up in the team's password manager |
| Sparkle's tools | `~/Library/Application Support/pitch.dog/Sparkle/2.10.0/bin` (setup in Drift's guide) |

**Never commit the private key, paste it into chat, or print it.** It is used only through Sparkle's `--ed-key-file`, by `scripts/sign-release.sh`.

Since 6 October 2026 the release workflow signs every release itself, with the key kept as a GitHub secret, the same way in all five of pitch.dog's app repositories (Deck Beat, OOO, Drift, Galileo, Backdrop). That is a trade: releasing needs nobody at a Mac, and a release goes out already offered to installed copies; but the key, which signs all five apps, now also lives on GitHub. Anyone who could push a workflow to `main` of one of those repositories, or take over the GitHub account, could sign an update for all five. Only a job naming the `release` environment, on `main`, is given the key; the job uses only GitHub's own `actions/checkout`, writes the key to a file only the runner can read, uses it once and deletes it. [Deck Beat's UPDATES.md](https://github.com/bomkino/deck-beat/blob/main/docs/UPDATES.md) has the one-time command that set it up (`scripts/auto-signing-setup.sh`, run on the Mac that holds the key), what to do if the key leaks, and how to go back to signing on the Mac only.

## Making a release

On `main`, raise `VERSION` in `scripts/build-app.sh` (always upwards) and give it a section in `CHANGELOG.md`: its first paragraph becomes the notes' bold opening line, the rest their What's new. Then run **release** from the Actions tab (`.github/workflows/release.yml`) on `main`. It:

1. refuses a version that isn't higher than the Latest release, and stops at once if the `release` environment has no key;
2. runs the tests, builds the app and runs `scripts/test-update.sh`;
3. packs it with `scripts/make-release.sh`, then signs the ZIP into `appcast.xml` with `scripts/sign-release.sh --dir`, which checks the app inside is that version and trusts pitch.dog's key, puts the version's changelog section in the update window, and checks the signature with the public key inside the app, as Sparkle will. A wrong key stops the release here, before anything is published;
4. publishes `vx.y.z`, marked Latest, with the disk image, the ZIP, the signed `appcast.xml`, `SHA256SUMS.txt` and notes in the shape of Drift's, and waits until `releases/latest/download/appcast.xml` names the new version;
5. runs `scripts/test-live-update.sh`: it downloads the release before, opens it against the live feed with `STUDIO_UPDATE_TEST=1`, and waits for it to update itself to the new version, as every installed copy will.

**Rehearse** (a box in Run workflow) does steps 1 to 3 without publishing: the way to check the key and the workflow without releasing anything.

**Sign** (in Run workflow, a version like `v1.0.0`) signs the update of a release that is already out, without rebuilding it: `scripts/sign-release.sh v1.0.0` downloads the release's ZIP, checks it against `SHA256SUMS.txt`, signs it, uploads the feed and waits for the live feed to name it, then the live update test runs. Releases published before automatic signing (1.0.0) carried the previous release's feed and need this once, or simply the next release.

On a Mac that holds the key, Sparkle's tools and a signed-in GitHub CLI, `bash scripts/sign-release.sh vx.y.z` does the same by hand; `SPARKLE_BIN` and `SPARKLE_KEY` point elsewhere. Add `--only` to make it the only release once its update is live: it then deletes every other release (their tags stay).

Things that break updates:

- **The asset must be called exactly `appcast.xml`** and the release must be the **Latest** one (drafts and pre-releases don't count).
- **Versions only go up.** Sparkle compares `CFBundleVersion`, which `build-app.sh` derives from the version: 0.2.0 → 200, 1.4.2 → 10402.
- **Sign the ZIP that is published.** The workflow signs the ZIP it publishes, and `sign-release.sh vx.y.z` downloads the release's own ZIP rather than building one, for that reason.
- Don't delete the newest release, or its `appcast.xml`.

## OOO 0.2.0, the first release with updates

Nothing can update *to* a first release, so 0.2.0's `appcast.xml` only says that 0.2.0 is the newest version, and carries no signature: Sparkle reads it, finds nothing newer than itself, and downloads nothing. Everyone installs 0.2.0 or later by hand once (drag it from the disk image, then **Open Anyway** in System Settings › Privacy & Security). Every version after that arrives by itself.

## Testing

`scripts/test-update.sh` runs in CI for every change and before every release. It makes a throwaway key, builds test copies at 9.0.0 and 9.0.1 under another name and bundle identifier (`OOO Update Test`, `dog.pitch.ooo.updatetest`) that trust only that key, packs and signs 9.0.1 with the release scripts themselves (`make-release.sh`, then `sign-release.sh --dir`), and serves it from a local feed. It passes when 9.0.0 installs 9.0.1 and relaunches on it, and when a ZIP with one changed byte is fetched and refused.

The test hooks are environment variables read only by the app at launch: `STUDIO_UPDATE_TEST` (check now and install as soon as an update is ready) and `STUDIO_UPDATE_FEED` (use another feed). A feed can't install anything unless it is signed with the key the app trusts.
