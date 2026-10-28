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

## Status
Nothing here has been compiled or run yet — written on Linux. First CI run will show compile errors.
Not built yet: account sign-in and cloud restore.
