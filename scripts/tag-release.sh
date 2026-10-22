#!/bin/zsh
# Cut a release. Runs the test suite, bumps the version in Rota/Info.plist,
# commits, tags vX.Y.Z and pushes. GitHub Actions (.github/workflows/release.yml)
# then builds, signs and publishes it to rota.silvermine.dev.
#
#   scripts/tag-release.sh              next patch version (1.1.249 -> 1.1.250), build + 1
#   scripts/tag-release.sh 1.2.0        explicit version, build + 1
#   scripts/tag-release.sh --skip-tests skip zsh Rota/test.sh (CI never runs it: it needs a Mac with Accessibility)
#
# Nothing is built here; the release is whatever CI builds from the tagged commit.
set -euo pipefail

repo=${0:A:h:h}
plist=$repo/Rota/Info.plist
die() { print -u2 -- "tag-release: $*"; exit 1; }
step() { print -P -- "%B==> $*%b"; }

requested= skip_tests=0
for arg in "$@"; do
  case $arg in
    --skip-tests) skip_tests=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    [0-9]*.[0-9]*.[0-9]*) requested=$arg ;;
    *) die "unknown argument: $arg" ;;
  esac
done

cd "$repo"
branch=$(git rev-parse --abbrev-ref HEAD)
[[ $branch == main ]] || die "release from main (currently on $branch)"
[[ -z $(git status --porcelain) ]] || die "the working tree has uncommitted changes; commit or stash them first"
step "Fetching origin"
git fetch --quiet origin main --tags
git merge-base --is-ancestor origin/main HEAD || die "main is behind origin/main; pull first"

current=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")
[[ $current =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && $build =~ '^[0-9]+$' ]] || die "unexpected version/build in Info.plist: $current / $build"
if [[ -n $requested ]]; then
  version=$requested
else
  parts=(${(s:.:)current})
  version="${parts[1]}.${parts[2]}.$((parts[3] + 1))"
fi
next_build=$((build + 1))
tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && die "tag $tag already exists on origin"

if (( ! skip_tests )); then
  step "Running the test suite (zsh Rota/test.sh)"
  zsh "$repo/Rota/test.sh"
fi

step "Releasing Rota $version (build $next_build), was $current ($build)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" "$plist"
git add "$plist"
git commit --quiet -m "Release $version ($next_build)"
git tag -a "$tag" -m "Rota $version ($next_build)"
git push --quiet origin main "$tag"
print -- "Pushed $tag. CI builds and publishes it: https://github.com/bryanwhiting/rotagivan/actions/workflows/release.yml"
if command -v gh >/dev/null; then
  print -- "Follow it with: gh run watch --exit-status"
fi
