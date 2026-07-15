# Mute Cue code-signing policy

Public releases require a trusted Authenticode code-signing certificate installed for the release Windows user under `CurrentUser\My`. The certificate must have an accessible private key, the Code Signing EKU (`1.3.6.1.5.5.7.3.3`), and at least seven days of remaining validity. The release checklist requires 30 days at the start of a normal release window.

Run the local readiness check before building:

```powershell
.\Overlay\Test-MuteCueSigningReadiness.ps1
```

Use the timestamp URL issued or documented by the certificate authority. Public builds require HTTPS timestamping so a signature remains verifiable after the leaf certificate expires:

```powershell
.\Overlay\Build-MuteCueRelease.ps1 `
  -RequireSigning `
  -SigningCertificateThumbprint <thumbprint> `
  -TimestampServer <CA HTTPS timestamp URL>
```

The build signs the accessibility DLL before recording its digest, signs every packaged PowerShell and VBScript entry point, verifies the signer and timestamp after signing, indexes the signed bytes, creates the archive, extracts that exact archive, verifies every signature again, and performs a clean installation.

`Test-MuteCueDevelopmentSigningPipeline.ps1` creates a non-exportable, self-signed certificate in the personal store without adding it to any trusted-root store. It signs copies of the compiled provider and installer, archives and extracts them, verifies that the signature bytes and signer survive, confirms that the public-release validator rejects the untrusted signer, then removes the certificate, archive, and copied files in a `finally` block. It never mutates the working release component or Windows trusted roots. Passing that test proves the cryptographic and fail-closed paths work; only a genuinely trusted certificate can prove the public-release path.

Never commit `.pfx`, `.p12`, private keys, certificate passwords, hardware-token secrets, or timestamp-service credentials. A public release certificate must be obtained from a trusted provider or managed signing service and kept outside the repository.
