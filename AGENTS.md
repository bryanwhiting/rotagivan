# Version reporting

## Delivery

- After each completed, verified change, commit the task's changes and push to `origin/main` without waiting for a separate push request. Do not create a PR unless requested.
- Preserve unrelated user changes, never force-push, and report any verification or push blocker instead of claiming delivery. Report the pushed version/build and commit when applicable.

## Builds

- After every verified app change, build and install the new version locally, then reopen it. Use a Sol subagent for the build/install workflow when available. Do not stop at a built artifact or wait for a separate install request.
- Install using `./launch.sh --keep-accessibility` so existing Accessibility permission is preserved. Never run bare `launch.sh` for routine updates: its default resets Accessibility. Verify the installed bundle version and running executable under `/Applications/Rotagivan.app`; report any build/install blocker explicitly.
- For each user-requested app change, increment CFBundleShortVersionString (normally the patch component) and CFBundleVersion in Rotagivan/Info.plist before building. Multiple implementation edits for the same update share one version.
- Keep version labels sourced from bundle metadata, not hardcoded UI strings.
- Report the version and build in the final response, and explicitly distinguish built from installed. Never imply the user is testing a fix that has not been installed.
- Builds must reuse the persistent Rotagivan Development identity in Keychain via Rotagivan/.signing/certificate.pem. Never use ad-hoc signing, regenerate this identity, or weaken the certificate-pinned designated requirement. Transitioning from old ad-hoc builds requires one new Accessibility grant. Do not reset permissions or modify signing trust without authorization.
