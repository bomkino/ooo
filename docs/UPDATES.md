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
| Private key | `~/Library/Application Support/pitch.dog/Release Keys/sparkle-ed25519-private.key` on the release Mac, backed up in the team's password manager |
| Sparkle's tools | `~/Library/Application Support/pitch.dog/Sparkle/2.10.0/bin` (setup in Drift's guide) |

**Never commit the private key, paste it into chat, or put it in a GitHub secret.** It is used only through Sparkle's `--ed-key-file`, by `scripts/sign-release.sh`, on the release Mac. CI never sees it.

## Making a release

A release is made in two steps: CI publishes it, then the release Mac signs its update.

**1. Publish, from anywhere.** On `main`, raise `VERSION` in `scripts/build-app.sh` (always upwards) and give it a section in `CHANGELOG.md`: its first paragraph becomes the notes' bold opening line, the rest their What's new. Then run **release** from the Actions tab (`.github/workflows/release.yml`) on `main`. It refuses a version that isn't higher than the Latest release, runs the tests and `scripts/test-update.sh`, packs the app with `scripts/make-release.sh` and publishes `vx.y.z`, marked Latest, with the disk image, the ZIP, `SHA256SUMS.txt` and notes in the shape of Drift's.

It also carries the previous release's `appcast.xml` over unchanged, after checking it names an older version whose ZIP still downloads. So every installed copy, old and new, keeps reading "up to date" until the next step. People can already download the new version by hand.

**2. Sign the update, on the release Mac.** From this repository on `main`:

```bash
bash scripts/sign-release.sh vx.y.z
```

It downloads the release's ZIP and checks it against `SHA256SUMS.txt`, checks the app inside is that version and trusts pitch.dog's key, signs the ZIP into a new `appcast.xml` (with the version's changelog section for the update window), checks the signature with the public key inside the app, uploads the feed to the release, replacing the carried one, and waits until `releases/latest/download/appcast.xml` names the new version. From then on, installed copies offer it. Nothing is rebuilt, so the ZIP people download by hand and the one the updater installs are the same file.

It needs the GitHub CLI signed in (`gh auth login`) and Sparkle's tools and the key in their usual places; `SPARKLE_BIN` and `SPARKLE_KEY` point elsewhere.

Things that break updates:

- **The asset must be called exactly `appcast.xml`** and the release must be the **Latest** one (drafts and pre-releases don't count).
- **Versions only go up.** Sparkle compares `CFBundleVersion`, which `build-app.sh` derives from the version: 0.2.0 → 200, 1.4.2 → 10402.
- **Sign the ZIP that was published.** `sign-release.sh` downloads it rather than building one, for that reason.
- Don't delete the newest release, or its `appcast.xml`.

## OOO 0.2.0, the first release with updates

Nothing can update *to* a first release, so 0.2.0's `appcast.xml` only says that 0.2.0 is the newest version, and carries no signature: Sparkle reads it, finds nothing newer than itself, and downloads nothing. Everyone installs 0.2.0 or later by hand once (drag it from the disk image, then **Open Anyway** in System Settings › Privacy & Security). Every version after that arrives by itself.

## Testing

`scripts/test-update.sh` runs in CI for every change and before every release. It makes a throwaway key, builds test copies at 9.0.0 and 9.0.1 under another name and bundle identifier (`OOO Update Test`, `dog.pitch.ooo.updatetest`) that trust only that key, packs and signs 9.0.1 with the release scripts themselves (`make-release.sh`, then `sign-release.sh --dir`), and serves it from a local feed. It passes when 9.0.0 installs 9.0.1 and relaunches on it, and when a ZIP with one changed byte is fetched and refused.

The test hooks are environment variables read only by the app at launch: `STUDIO_UPDATE_TEST` (check now and install as soon as an update is ready) and `STUDIO_UPDATE_FEED` (use another feed). A feed can't install anything unless it is signed with the key the app trusts.
