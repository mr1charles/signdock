# SignDock + DockBox

Two iOS apps, built entirely by GitHub Actions (no Mac needed).

## SignDock — batch IPA signer
- Import many IPAs at once, or paste many download links (one per line); failures don't stop the rest.
- Sign any selection with one certificate in a single run; optional bundle-ID suffix.
- History: every run recorded (result, certificate, time taken, error). Re-sign, share, search, filter.
- Certificates: `.p12` + `.mobileprovision`; password kept in the Keychain; revocation check.
- Signing engine: [Zsign](https://github.com/khcrysalis/Zsign-Package) (same as Feather). GPL-3.0.

## DockBox — LiveContainer fork
`DockBox/apply.py` patches a **pinned** upstream LiveContainer (AGPL-3.0) — no vendored copy:
- **JIT provider switch** (Settings → JIT): built-in, or any existing option incl. StikDebug.
  - *Built-in* attaches to the guest from DockBox itself using StikDebug's `idevice` library (pairing file +
    LocalDevVPN, device IP 10.7.0.1). `vAttach` freezes its target, so a debugger can't debug its own
    process: built-in only works for apps in **Multitask** mode. For normal launches it falls back to
    StikDebug (toggle in Settings).
- **Per-app modes** (Standard / Game / Compatibility): one-tap presets over LiveContainer's per-app options.
- Home-screen shortcuts are upstream's existing web-clip feature.

## Build
Actions → *Build* → run. Artifacts: `SignDock.ipa`, `DockBox.ipa` (unsigned; sign with SignDock).

## Cloud backup & restore (SignDock)
Sign in with an **emailed code** (Supabase Auth). Reinstall → sign in → library, history and certificates come back.
- Metadata (library, history, cert labels) is stored per-user behind row-level security.
- Certificates (`.p12` + profile + password) are **encrypted on-device** (AES-GCM, PBKDF2 key from a vault
  passphrase) before upload. Forget the passphrase = re-add certs.
- IPAs: backed up to a private bucket if ≤ 50 MB (free-plan limit); otherwise restored by re-downloading
  from the link you imported them from. Files imported from disk that are too large can't be restored.
- **One-time setup:** Supabase dashboard → Authentication → Email Templates → *Magic Link* and *Confirm signup*:
  include `{{ .Token }}` in the body (e.g. `Your SignDock code: {{ .Token }}`) or no code is ever emailed.
  The built-in mailer is heavily rate-limited; add a custom SMTP provider for real use.
- Backend: project `rxuuqplvjxrrldacrpdy` (schema in `supabase/migrations`).

## Increased memory limit
DockBox (and its Multitask guest process) already declare `com.apple.developer.kernel.increased-memory-limit`
upstream. iOS only honors it if the signing **profile** grants it; Zsign applies the profile's entitlements to
every app it signs. SignDock shows per certificate whether the profile has it, and the sign sheet can
require it (fails with a clear message instead of silently running with normal limits).

## Multiple Apple accounts
Each certificate carries an Apple ID label; the Certificates tab groups by it and tapping selects the active one.
SignDock does not log into Apple IDs to mint certificates (that's SideStore/AltStore territory); you import the
`.p12` + profile for each free developer account. Free-account profiles expire after 7 days.

## Status
Written on Linux and not yet run on a device. See the Actions tab for whether it compiles.
