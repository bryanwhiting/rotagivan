# Customer distribution

The development install and the customer install are separate workflows.

## Customer experience

1. Explore the website and browser demo; view published pricing and terms.
2. Purchase/activate only once an actual licensing and payment model is chosen, or download if a free release is chosen.
3. Download a release signed by the publisher with Apple Developer ID, notarized by Apple, and stapled before distribution.
4. Move Rotagivan into Applications and open it. Grant Accessibility and any applicable Input Monitoring permissions through macOS. Microphone permission and provider configuration are needed only for optional voice features.
5. Configure a first action, test it, then build up profiles, gestures, and macros.

Customers do not install Xcode, compile source, create a signing identity, or trust a development certificate. Signing and notarization do not grant privacy permissions automatically.

## Publisher release path

The current `Rotagivan/build.sh` / `launch.sh` intentionally use a persistent local development identity and certificate pin. Preserve that path for local updates. Do not replace or weaken it to ship a download.

A future distribution workflow should:

- Use an Apple Developer Program account and its Developer ID Application certificate/private key in an authorized signing environment. The new local Rotagivan Development identity does not qualify.
- Build into a separate release directory, for explicitly tested architectures and macOS deployment targets. Verify the actual Mach-O deployment target and minimum framework/API availability, not just Info.plist. The bundle currently declares macOS 13+, but that alone is not a verified support promise.
- Sign the distribution copy with Developer ID, secure timestamp, and hardened runtime. Review necessary entitlements, nested code, privacy usage descriptions, and the release designated requirement. Keep the development certificate-pinned copy unchanged.
- Package the signed app, submit it using `xcrun notarytool`, inspect the accepted result, staple the ticket to the app/disk image, and validate the staple and Gatekeeper assessment before hosting it.
- Test a quarantined download on clean supported Macs: first launch, permissions, enabled gestures, optional voice, normal quit, update, and settings migration. Test both hardware architectures only if both are advertised.
- Host a versioned downloadable artifact over HTTPS with a checksum, release notes, exact supported platforms, and clear support instructions. Add a verified download URL to the site only after these gates pass.
- Implement and verify any paid licensing/activation and update mechanisms separately. A pricing page alone does not implement billing or entitlements. Automatic updating is not currently established by this change.

## Current website behavior

The Astro site shows **Pricing coming soon** and **Public download coming soon**. Its HUD is explicitly a browser simulation; it requests no microphone or Mac control. App marketing distinguishes experimental Apple trackpad support and optional cloud voice services. No unverified testimonials, speed benchmarks, purchase promises, or customer download are published.

## Official references

- [Apple: Signing Mac software with Developer ID](https://developer.apple.com/developer-id/)
- [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Cloudflare: Astro on Workers](https://developers.cloudflare.com/workers/framework-guides/web-apps/astro/)
