# Version reporting

- For each user-requested app change, increment CFBundleShortVersionString (normally the patch component) and CFBundleVersion in Rotagivan/Info.plist before building. Multiple implementation edits for the same update share one version.
- Keep version labels sourced from bundle metadata, not hardcoded UI strings.
- Report the version and build in the final response, and explicitly distinguish built from installed. Never imply the user is testing a fix that has not been installed.
- Builds must reuse the persistent Rotagivan Development identity in Keychain via Rotagivan/.signing/certificate.pem. Never use ad-hoc signing, regenerate this identity, or weaken the certificate-pinned designated requirement. Transitioning from old ad-hoc builds requires one new Accessibility grant. Do not reset permissions or modify signing trust without authorization.
