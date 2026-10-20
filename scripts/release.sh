#!/bin/zsh
# Build, package and publish a Rotagivan release to rota.silvermine.dev.
#
#   scripts/release.sh               build, package, upload, verify
#   scripts/release.sh --skip-build  package the existing Rotagivan/build/Rotagivan.app
#   scripts/release.sh --no-publish  package only (no upload)
#   scripts/release.sh --allow-dirty permit a build made from uncommitted inputs
#
# Output: release/<version>-<build>/Rotagivan-<version>-<build>.{dmg,zip} and
# latest.json. Uploads go to the private R2 bucket served by the
# rotagivan-website Worker (/download/latest, /latest.json, /releases/*).
# latest.json is uploaded last so it never points at a missing file.
#
# Signing:
#   Without DEVELOPER_ID the app keeps the persistent "Rotagivan Development"
#   signature from build.sh. Gatekeeper blocks such downloads on first launch
#   (System Settings -> Privacy & Security -> Open Anyway is needed once).
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" re-signs a copy with
#   hardened runtime + secure timestamp. NOTARY_PROFILE=<profile> (created
#   with `xcrun notarytool store-credentials`) also notarizes and staples.
#
# Credentials: Cloudflare values come from the environment or ~/.env through
# website/scripts/cloudflare.mjs; they are never printed.
set -euo pipefail

repo=${0:A:h:h}
skip_build=0 publish=1 allow_dirty=0
for arg in "$@"; do
  case $arg in
    --skip-build) skip_build=1 ;;
    --no-publish) publish=0 ;;
    --allow-dirty) allow_dirty=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

base_url=${RELEASE_BASE_URL:-https://rota.silvermine.dev}
bucket=${RELEASE_BUCKET:-rotagivan-releases}
app="$repo/Rotagivan/build/Rotagivan.app"
step() { print -P "%B==> $*%b"; }
die() { echo "release: $*" >&2; exit 1; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null || true; }

if (( ! skip_build )); then
  step "Building with Rotagivan/build.sh"
  "$repo/Rotagivan/build.sh"
fi
[[ -d $app ]] || die "missing $app (run without --skip-build)"

version=$(plist_value CFBundleShortVersionString)
build=$(plist_value CFBundleVersion)
minimum_os=$(plist_value LSMinimumSystemVersion)
commit=$(plist_value RotagivanGitCommit)
dirty=$(plist_value RotagivanGitDirty)
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && $build =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || die "invalid version/build: '$version' '$build'"
if [[ $dirty != false ]] && (( ! allow_dirty )); then
  die "the app was built from uncommitted inputs (RotagivanGitDirty=$dirty). Commit first or pass --allow-dirty."
fi
architectures=($(lipo -archs "$app/Contents/MacOS/Rotagivan"))
name="Rotagivan-$version-$build"
out="$repo/release/$version-$build"
step "Packaging $name (${architectures[*]})"
rm -rf "$out"
mkdir -p "$out/stage" "$out/dmg"
staged="$out/stage/Rotagivan.app"
ditto "$app" "$staged"

signing=development notarized=false
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m | tee "$out/notary-${1:t}.log"
  grep -q "status: Accepted" "$out/notary-${1:t}.log" || die "notarization of ${1:t} was not accepted (see $out/notary-${1:t}.log)"
}
if [[ -n ${DEVELOPER_ID:-} ]]; then
  step "Signing with Developer ID"
  security find-identity -v -p codesigning | grep -Fq "$DEVELOPER_ID" || die "Developer ID identity not found in Keychain: $DEVELOPER_ID"
  codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$staged/Contents/Resources/librota_search.dylib"
  codesign --force --timestamp --options runtime --identifier local.rotagivan.mcp --sign "$DEVELOPER_ID" "$staged/Contents/MacOS/rotagivan-mcp"
  codesign --force --timestamp --options runtime --entitlements "$repo/Rotagivan/Release.entitlements" \
    --sign "$DEVELOPER_ID" "$staged"
  signing=developer-id
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$staged" "$out/notarize-app.zip"
    notarize "$out/notarize-app.zip"
    xcrun stapler staple "$staged"
    rm -f "$out/notarize-app.zip"
  fi
fi
codesign --verify --deep --strict "$staged"

zip="$out/$name.zip"
dmg="$out/$name.dmg"
ditto -c -k --sequesterRsrc --keepParent "$staged" "$zip"
ditto "$staged" "$out/dmg/Rotagivan.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -quiet -volname "Rotagivan $version" -srcfolder "$out/dmg" -fs HFS+ -format UDZO -ov "$dmg"
if [[ $signing == developer-id ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$dmg"
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    step "Notarizing the disk image"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    notarized=true
  fi
fi
rm -rf "$out/stage" "$out/dmg"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { stat -f %z "$1"; }
dmg_sha=$(sha "$dmg") zip_sha=$(sha "$zip")
DMG_SHA=$dmg_sha ZIP_SHA=$zip_sha DMG_SIZE=$(size "$dmg") ZIP_SIZE=$(size "$zip") \
VERSION=$version BUILD=$build MINIMUM_OS=$minimum_os COMMIT=$commit NAME=$name BASE=$base_url \
ARCHS="${architectures[*]}" SIGNING=$signing NOTARIZED=$notarized \
python3 - "$out/latest.json" <<'PY'
import datetime, json, os, sys
e = os.environ
base = e["BASE"].rstrip("/")
manifest = {
    "version": e["VERSION"],
    "build": e["BUILD"],
    "url": f"{base}/releases/{e['NAME']}.dmg",
    "sha256": e["DMG_SHA"],
    "size": int(e["DMG_SIZE"]),
    "minimumOS": e["MINIMUM_OS"] or None,
    "architectures": e["ARCHS"].split(),
    "zip": {"url": f"{base}/releases/{e['NAME']}.zip", "sha256": e["ZIP_SHA"], "size": int(e["ZIP_SIZE"])},
    "commit": e["COMMIT"] or None,
    "signing": e["SIGNING"],
    "notarized": e["NOTARIZED"] == "true",
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
}
with open(sys.argv[1], "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
cat "$out/latest.json"

if [[ $signing == development ]]; then
  echo "note: signed with the local development identity, not Developer ID; Gatekeeper will block the first launch of downloaded copies." >&2
fi
(( publish )) || { step "Packaged (not published): $out"; exit 0; }

wrangler() { (cd "$repo/website" && node scripts/cloudflare.mjs "$@"); }
put() { # key file content-type cache-control
  wrangler r2 object put "$bucket/$1" --file "$2" --content-type "$3" --cache-control "$4" --remote >/dev/null
  echo "uploaded $1"
}
step "Uploading to R2 bucket $bucket"
[[ -d $repo/website/node_modules ]] || (cd "$repo/website" && npm ci)
put "releases/$name.dmg" "$dmg" application/x-apple-diskimage "public, max-age=31536000, immutable"
put "releases/$name.zip" "$zip" application/zip "public, max-age=31536000, immutable"
put "releases/$name.json" "$out/latest.json" application/json "public, max-age=31536000, immutable"
put "latest.json" "$out/latest.json" application/json "public, max-age=60, must-revalidate"

step "Verifying $base_url/download/latest"
fetched="$out/verify-download.dmg"
curl -sS -o /dev/null -w "latest -> %{http_code} %{redirect_url}\n" "$base_url/download/latest"
curl -sSfL -o "$fetched" -w "download -> %{http_code} %{size_download} bytes %{url_effective}\n" "$base_url/download/latest"
[[ $(sha "$fetched") == "$dmg_sha" ]] || die "downloaded DMG checksum does not match the upload"
rm -f "$fetched"
curl -sSf "$base_url/latest.json" | python3 -c 'import json,sys; m=json.load(sys.stdin); assert m["sha256"]==sys.argv[1], "latest.json is stale"; print("latest.json ->", m["version"], m["build"])' "$dmg_sha"
step "Published $name: sha256 $dmg_sha"
