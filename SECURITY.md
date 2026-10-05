# Security policy

OOO opens private slides and voice recordings and writes video. A security report deserves a channel that does not expose the reporter's files or a working exploit in a public issue.

## Reporting a vulnerability

Do not attach confidential slides, recordings, crash logs containing file names, or a weaponised `.ooo` package to a public issue.

Send a minimal report to `hello@pitch.dog` with **OOO SECURITY** in the subject, or use GitHub's private vulnerability reporting. Include the affected commit or version, your macOS version and Mac, the smallest steps that reproduce it, what you expected and what happened, and a synthetic file where possible. Never send real client material just because it reproduces the bug.

The maintainers aim to acknowledge a report within 5 business days and to agree on disclosure timing once the impact and a safe fix are understood. These are targets, not guarantees. There is no bug bounty.

## What OOO does and does not do

- Everything runs locally. OOO makes no network requests: no account, analytics, updater or cloud service.
- Speech recognition runs on this Mac (`requiresOnDeviceRecognition` where the language supports it). macOS asks for permission the first time.
- OOO runs with normal user permissions and is **not sandboxed**. Builds are ad-hoc signed and not notarized; ad-hoc signing is not Developer ID signing.
- A document is a package holding `project.json` and copies of the slide and voiceover. Parsing flaws in PDF, image or audio files are handled by macOS frameworks (Core Graphics, Image I/O, AVFoundation).

Security fixes target `main`. Please allow reasonable time to fix and ship before public disclosure.
