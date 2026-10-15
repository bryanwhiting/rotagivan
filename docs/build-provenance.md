# Build provenance

The build reads Git once, before compiling, and stamps the **built bundle**, never
the tracked `Rotagivan/Info.plist`. Numeric macOS version/build fields stay separate
from labels such as `v1.1.203-abcd-dirty`.

The first four lowercase SHA characters are a convenient label, not a unique
identifier. **About Rotagivan** and version-label tooltips show the full commit,
source state, build-input SHA-256, and UTC build time. The signed app also includes
these values in its Info.plist and `Contents/Resources/BuildProvenance.json`.

A clean label means the declared app source/build inputs match that commit.
`-dirty` means at least one compiled source, resource, build script, or YAML package
input differs; the commit then identifies the **base revision**, not the exact
uncommitted source. Keep or commit that source and retain the input manifest to
identify it precisely. The fingerprint distinguishes different dirty input sets;
it does not make a dirty build recoverable from Git alone or promise reproducible
binaries across different toolchains and environments.

The input list is shared with the compiler. Generated app bundles, icon output,
SwiftPM caches, signing material, unrelated docs and tests are not app source
inputs and cannot make repeated builds dirty. Build-input bytes and file modes
are compared to HEAD, including untracked inputs. HEAD and all input hashes are
checked again before signing; concurrent source changes abort the build.

Build from the actual Git checkout with `zsh Rotagivan/build.sh`. Missing Git/HEAD
is an explicit build error, rather than guessed provenance. Unstamped development
bundles display `unknown`. No running app queries Git or the current checkout.

Run `zsh Rotagivan/test-provenance.sh` for isolated clean/dirty/hash tests. Pass an
installed `Contents/Info.plist` path to also validate its rendered version string.
