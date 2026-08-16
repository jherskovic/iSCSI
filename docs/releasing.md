# Releasing

## Cutting a release

```sh
# 1. Bump BOTH numbers in apps/project.yml.
#    MARKETING_VERSION is what humans read. CURRENT_PROJECT_VERSION is what
#    Sparkle compares — forget it and the new release either replaces the old
#    one in the feed or is never offered. scripts/update-appcast.py refuses
#    both mistakes, but it refuses them late, after a build and two
#    notarizations have already run.
$EDITOR apps/project.yml

cd apps && xcodegen generate && cd ..     # keep the .pbxproj in step
git commit -am "Version 0.3.3"
git push

# 2. Tag it. That is the whole release.
git tag v0.3.3
git push origin v0.3.3
```

`.github/workflows/release.yml` then archives, exports a Developer ID build,
notarizes and staples the app, builds and notarizes the DMG, signs it for
Sparkle, creates the GitHub release, and commits the appcast entry to `main` —
in that order, because the feed must never promise a file that is not there yet.

Watch it in the Actions tab. It takes 20–40 minutes, nearly all of it waiting on
Apple's notary service.

Release notes come from `docs/release-notes/<version>.md` if that file exists,
and otherwise from GitHub's summary of the commits since the last tag.

### Before trusting a tag

The first time — and after rotating any credential — run the workflow by hand
from the Actions tab with **Publish** left off. That builds, signs and notarizes
exactly as a real release would, publishes nothing, and leaves the DMG as a
workflow artifact. It is the only cheap way to find out whether the runner can
resolve the FSKit provisioning profile, which is the step most likely to break
and the one whose failure is worst: an export that silently omits the filesystem
extension produces a DMG that installs fine and cannot mount anything.

## The secrets

Six repository secrets, under Settings → Secrets and variables → Actions. All
six live on the runner for the length of one job, in `$RUNNER_TEMP` and a
throwaway keychain, and are deleted in a step that runs even when the build
fails. The workflow checks for all six before it does anything else and names
every one that is missing, so a repository with none configured says so in
twenty seconds rather than failing on the first one it happens to need.

Every command below pipes into `gh secret set` rather than through the
clipboard, so no key material lands in a paste buffer. For the short values, run
`gh secret set NAME` with nothing piped in and paste at its hidden prompt —
that keeps them out of shell history too.

```sh
base64 < DeveloperID.p12          | gh secret set DEVELOPER_ID_CERT_P12
base64 < AuthKey_XXXXXXXX.p8      | gh secret set ASC_KEY_P8
gh secret set DEVELOPER_ID_CERT_PASSWORD   # paste at the prompt
gh secret set ASC_KEY_ID                   # paste at the prompt
gh secret set ASC_ISSUER_ID                # paste at the prompt
```

### `DEVELOPER_ID_CERT_P12` and `DEVELOPER_ID_CERT_PASSWORD`

Keychain Access → login → My Certificates → **Developer ID Application: Jorge
Herskovic (4A27X5PJP3)** → right-click → Export. Choose `.p12` and set a strong
password; that password is the second secret.

```sh
base64 < DeveloperID.p12 | pbcopy      # paste as DEVELOPER_ID_CERT_P12
rm DeveloperID.p12
```

Export the row with the disclosure triangle — the *identity*, certificate plus
private key. Exporting the certificate alone produces a `.p12` that imports
without error and then cannot sign anything.

If this leaks: revoke the certificate in the developer portal and issue a new
one. Builds already notarized keep working, because notarization tickets outlive
the certificate that produced them.

### `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`

App Store Connect → Users and Access → Integrations → App Store Connect API →
generate a team key with the **Developer** role. The `.p8` downloads exactly
once.

```sh
base64 < AuthKey_XXXXXXXX.p8 | pbcopy   # paste as ASC_KEY_P8
```

`ASC_KEY_ID` is the `XXXXXXXX` in the filename. `ASC_ISSUER_ID` is the UUID shown
above the key list.

This key authenticates the notary submissions. It does **not** get the app its
provisioning profiles, though this document used to claim it did: an App Store
Connect key cannot create a Developer ID profile, and asking it to is a hard
failure —

    error: exportArchive Team "..." does not have permission to create
           "Developer ID" provisioning profiles.

The profiles are committed in `packaging/profiles/` instead, and the workflow
installs them before building. They are not secret: a `.provisionprofile` holds
entitlements and *public* certificates, and the same bytes already ship inside
every DMG on the Releases page. They expire in 2044, so nothing needs rotating
on a schedule.

What does invalidate them is changing entitlements. Xcode re-mints on the next
local build; copy the fresh ones back out of the built app and commit them:

```sh
cp "build/export/iSCSI Initiator.app/Contents/embedded.provisionprofile" \
   packaging/profiles/me.herko.iSCSIInitiator.provisionprofile
cp "build/export/iSCSI Initiator.app/Contents/Extensions/iSCSIFSExtension.appex/Contents/embedded.provisionprofile" \
   packaging/profiles/me.herko.iSCSIInitiator.fsext.provisionprofile
```

Get this wrong and the app builds, signs, notarizes and ships with a filesystem
extension macOS will not load.

If this leaks: revoke the key in App Store Connect and generate another.

### `SPARKLE_ED_PRIVATE_KEY`

```sh
"$(find ~/Library/Developer/Xcode/DerivedData \
    -path '*/artifacts/sparkle/Sparkle/bin/generate_keys' -type f | head -1)" \
    -x "$TMPDIR/sparkle_key"
gh secret set SPARKLE_ED_PRIVATE_KEY < "$TMPDIR/sparkle_key"
rm -P "$TMPDIR/sparkle_key"
```

Signing from an exported key file was checked against signing from the keychain
and produces a byte-identical signature, so this transfer cannot quietly change
what the app will accept.

**This is the most dangerous secret in the project, and the only one that cannot
be revoked.** Its public half is compiled into `SUPublicEDKey` in every copy of
the app that has ever shipped. Anyone holding the private half can sign an
update that every installed copy will accept as genuine, and the only remedy is
to reach every user out of band and ask them to download a fresh build by hand.
It is here because releases are meant to be one `git push`; the alternative is
signing on a Mac and giving up unattended releases.

Keep an offline backup. Losing it is the same failure from the other side: no
existing installation can ever be updated again.

## Releasing from a Mac instead

`scripts/release.sh` is what CI runs — there is no second implementation — so it
works standalone:

```sh
scripts/release.sh --publish          # build, notarize, publish, write the feed
git commit -m "Release 0.3.3" appcast.xml && git push
```

Without `--publish` it stops after writing `appcast.xml` and prints the two
commands to finish by hand. Do not commit that appcast before the release
exists: the feed is a promise that a file is at a URL, and every installed copy
that checks in between gets a failed download.

`--skip-notarize` exists only for changing `release.sh` itself. Its output is
named `…-UNNOTARIZED.dmg` so it cannot be confused with or overwrite a real
release, and it must never be installed anywhere — macOS behaves differently
around notarization, so an unnotarized build predicts nothing about the shipping
one.

## When it goes wrong

The steps are ordered so that a failure leaves the *quiet* kind of damage.

**Failed before the release was created.** Nothing happened. Delete the tag,
fix, tag again:

```sh
git push --delete origin v0.3.3 && git tag -d v0.3.3
```

**Failed after publishing but before the appcast landed.** The release exists
and no user has been told about it — this is the safe direction, and it is
deliberate. Download `build/release-metadata.env` from the workflow artifacts,
or read it from the log, and finish by hand:

```sh
. release-metadata.env
scripts/update-appcast.py --version "$VERSION" --build "$BUILD_NUMBER" \
    --signature "$ED_SIGNATURE" --length "$ED_LENGTH" \
    --url "$ASSET_URL" --min-system "$MIN_SYSTEM"
git commit -m "Release $VERSION" appcast.xml && git push
```

The signature covers bytes that already exist on the Releases page, so this
needs no rebuild. Rebuilding would in fact be wrong: a second build of the same
source produces a different DMG, and the signature would stop matching.

**The final check failed.** It compares the feed's newest enclosure against the
file GitHub actually serves. If those disagree, the feed is lying to users;
treat it as an outage, not a flake. The known cause is a URL that does not
resolve — GitHub rewrites spaces in asset filenames to periods, which is why the
DMG is called `iSCSI-Initiator-0.3.3.dmg` and not `iSCSI Initiator-0.3.3.dmg`.

**Never re-upload an asset to an existing release.** The appcast signature
covers the exact bytes, so replacing the file breaks updates for everyone who
has not downloaded it yet, and does it silently. Cut a new version instead.
`--publish` refuses to touch a version that already has a release.
