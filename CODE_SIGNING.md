# Mute Cue code-signing policy

Mute Cue community beta installers are currently unsigned. GitHub release notes and the README must disclose the resulting unknown-publisher or SmartScreen warning, and every release must include a SHA-256 checksum.

Authenticode signing should be enabled only after a trusted code-signing identity or managed signing service is available. Never store a certificate, private key, password, hardware-token secret, or signing-service credential in this repository.

## Future signing requirements

- Sign the final `MuteCue.exe` and generated installer, not an intermediate payload.
- Use a certificate with the Code Signing EKU and a trusted timestamp service over HTTPS.
- Verify the signature and timestamp after packaging.
- Download the published installer and verify its signature again before promotion.
- Keep signing credentials in a protected GitHub environment or external managed service.
- Fail closed when signing is required but unavailable or invalid.

The legacy signing scripts under `Overlay` remain regression and design reference material. They are not part of the v0.6.0 native installer workflow.
