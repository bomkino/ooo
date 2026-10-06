# In-app updates

OOO updates itself from this repository's GitHub releases, through [Sparkle](https://sparkle-project.org) 2.10.0, the same way pitch.dog's Drift, Galileo and Backdrop do. The full guide, with the reasons behind each rule, is [Drift's UPDATES.md](https://github.com/bomkino/pitchdog-drift/blob/main/docs/UPDATES.md). This page is what is specific to OOO.

No Apple Developer account is involved. OOO is signed ad hoc. Updates are trusted because each one carries an EdDSA signature that only pitch.dog's private key can make, and OOO has the matching public key built in.

## How it works

1. Every release carries four files: `OOO-x.y.z-macOS-arm64.dmg` (for people), `OOO-x.y.z-macOS-arm64.zip` (for the updater), `appcast.xml` and `SHA256SUMS.txt`.
2. OOO's `Info.plist` names the feed `https://github.com/bomkino/ooo/releases/latest/download/appcast.xml`. GitHub redirects that address to the `appcast.xml` of the release marked **Latest**.
3. Once a day, and whenever someone chooses **OOO › Check for Updates…**, Sparkle reads the feed. If it lists a newer version, OOO shows the release notes and an Install button.
4. Sparkle downloads the ZIP, checks its signature against `SUPublicEDKey`, swaps the app in place and relaunches it. A ZIP that doesn't match is refused.

| | |
|---|---|
| Public key (`SUPublicEDKey`, in `scripts/build-app.sh`) | `P43E8I+FgVyAW3QkS4J9bnDRRhAnsS4y3dT2WDce1lQ=` |
| Private key | `~/Library/Application Support/pitch.dog/Release Keys/sparkle-ed25519-private.key` on the release Mac, backed up in the team's password manager |
| Sparkle's tools | `~/Library/Application Support/pitch.dog/Sparkle/2.10.0/bin` (setup in Drift's guide) |

**Never commit the private key, paste it into chat, or put it in a GitHub secret.** Use it only through Sparkle's `--ed-key-file`, as `scripts/make-release.sh` does.

## Making a release

On the release Mac, from this repository on `main`:

```bash
# 1. Raise the version in scripts/build-app.sh (VERSION, always upwards) and
#    give it a section in CHANGELOG.md. Write notes.md: a few lines for the
#    update window.
bash scripts/build-app.sh release
bash scripts/test-update.sh                 # a signed update installs, a tampered one is refused
bash scripts/make-release.sh ../release/ooo notes.md
#    → OOO-x.y.z-macOS-arm64.dmg, OOO-x.y.z-macOS-arm64.zip, appcast.xml, SHA256SUMS.txt
# 2. Publish all four on the release tagged vx.y.z, marked Latest, with the
#    changelog's section as the notes:
gh release create vx.y.z -R bomkino/ooo --target "$(git rev-parse HEAD)" --latest \
  --title "OOO x.y.z · Apple silicon Mac" --notes-file release-notes.md ../release/ooo/*
# 3. Check the feed now points at it:
curl -sL https://github.com/bomkino/ooo/releases/latest/download/appcast.xml | grep shortVersionString
```

Things that break updates:

- **The asset must be called exactly `appcast.xml`** and the release must be the **Latest** one (drafts and pre-releases don't count).
- **Versions only go up.** Sparkle compares `CFBundleVersion`, which `build-app.sh` derives from the version: 0.2.0 → 200, 1.4.2 → 10402.
- **Upload the ZIP that was signed.** If the app is rebuilt, run `make-release.sh` again.
- Don't delete the newest release, or its `appcast.xml`.

## OOO 0.2.0, the first release with updates

OOO 0.2.0 was published from CI by `.github/workflows/release.yml`, run by hand on `main`. Nothing can update *to* a first release, so its `appcast.xml` only has to say that 0.2.0 is the newest version, and it carries no signature: Sparkle reads it, finds nothing newer than itself, and downloads nothing. That workflow refuses to run once a release exists, because every later release needs an appcast signed with the private key, which only the release Mac holds.

Everyone installs 0.2.0 by hand once (drag it from the disk image, then **Open Anyway** in System Settings › Privacy & Security). Every version after it arrives by itself.

## Testing

`scripts/test-update.sh` runs in CI for every change, and on a Mac before a release. It makes a throwaway key, builds test copies at 9.0.0 and 9.0.1 under another name and bundle identifier (`OOO Update Test`, `dog.pitch.ooo.updatetest`) that trust only that key, and serves 9.0.1 from a local feed. It passes when 9.0.0 installs 9.0.1 and relaunches on it, and when a ZIP with one changed byte is fetched and refused.

The test hooks are environment variables read only by the app at launch: `STUDIO_UPDATE_TEST` (check now and install as soon as an update is ready) and `STUDIO_UPDATE_FEED` (use another feed). A feed can't install anything unless it is signed with the key the app trusts.
