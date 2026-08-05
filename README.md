# Ship

A small macOS app that archives, signs, validates and uploads an iOS build
using **only an App Store Connect API key**.

## Why it exists

Shipping an iOS app normally means signing an Apple ID into Xcode. For a
contractor that is a problem: Apple flags Apple IDs signed in across shared
hardware, and an account owner who is careful about that will not hand over a
login — nor should they.

An App Store Connect API key solves it. It is a JWT credential, not a login.
Nothing signs in, no Apple ID touches the machine, and the owner can revoke it
in one click. This app does the whole pipeline with one.

## What "nothing local" means here

The constraint is enforced, not merely intended:

| Concern | How it is handled |
|---|---|
| Apple ID | Never used. Every signing asset comes from the API key |
| Signing identity | Imported into a **temporary keychain created per run and deleted afterwards**, never the login keychain |
| Certificate private key | Generated locally per run, discarded with the temp directory. Apple only ever sees the CSR's public half |
| `xcode-select` | Untouched. `DEVELOPER_DIR` is set per process instead, so nothing system-wide changes |
| The `.p8` file | Never copied or stored. Only its *path* is remembered; the file is read at the moment a token is signed |
| Default keychain | Untouched. The temp keychain is appended to the search list, not made default |

The temp keychain is removed on every exit path, including a failed build — so
a broken archive does not leave someone else's distribution certificate sitting
on your machine.

## Setup

Fill in the form once; it is remembered.

- **Xcode project** — your `.xcodeproj`
- **Scheme** — the shared scheme to build
- **Bundle ID** — the app's identifier
- **Extension bundle IDs** — optional, comma separated. Each app extension
  needs its own App ID and profile; omitting them fails at export with "No
  profiles for …"
- **API key (.p8)** — from App Store Connect → Users and Access → Integrations
- **Key ID / Issuer ID** — shown on the same page. The Key ID is filled in
  automatically from the conventional `AuthKey_XXXXXXXXXX.p8` filename

The key needs the **App Manager** role. Admin is not required — despite
appearances, App Manager can create both distribution certificates and App
Store profiles through the API.

## Using it

**Build IPA** archives, signs and exports, then reveals the `.ipa` in Finder.
Works for Debug or Release.

**Build & Upload** does the same, then validates and uploads. Release only —
a Debug build is signed for devices and App Store Connect rejects it.

Validation always runs before upload, because an upload permanently consumes a
build number. Each upload needs a build number higher than the last.

## Things that will bite you

**The app record must already exist** in App Store Connect. The API cannot
create one; that is a web-UI step for the account owner.

**Push must be enabled on the App ID.** The tool enables it automatically
before requesting the profile, because a profile issued from an App ID without
push silently omits `aps-environment` — the build uploads fine and push is
simply dead, with nothing to explain why.

**Automatic signing does not work with an API key.** Xcode's *cloud signing*
service refuses these keys with "Cloud signing permission error", which reads
like a permissions problem with the key itself. It is not — the same key can
create the certificate and profiles directly. This tool always signs manually
for that reason.

**A new certificate is issued per run.** An existing certificate on the account
is useless without its private key, which lives on whichever machine created
it. Distribution certificate slots are limited, so revoke stale ones in the
developer portal occasionally.

## Building it

```
xcodegen generate
xcodebuild -project MailBoxShip.xcodeproj -scheme MailBoxShip -configuration Release build
```

Universal (arm64 + x86_64) and ad-hoc signed — it deliberately has no identity
of its own, since giving a tool that manages someone else's signing assets an
account of its own would be the exact coupling it exists to avoid.
