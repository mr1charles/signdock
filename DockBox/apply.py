#!/usr/bin/env python3
"""Turn a pinned LiveContainer checkout into DockBox.

usage: apply.py <livecontainer-dir> <stikdebug-dir> <zsign-package-dir> <zipfoundation-dir>

Every edit asserts that its anchor matches exactly once, so if upstream drifts this fails loudly
instead of silently producing a half-patched app.
"""
import pathlib, re, shutil, sys

lc = pathlib.Path(sys.argv[1])
stik = pathlib.Path(sys.argv[2])
zsign_pkg = pathlib.Path(sys.argv[3])
zipf = pathlib.Path(sys.argv[4])
here = pathlib.Path(__file__).parent


def edit(rel, old, new):
    p = lc / rel
    s = p.read_text()
    n = s.count(old)
    assert n == 1, f"{rel}: expected exactly 1 match, found {n} for:\n{old}"
    p.write_text(s.replace(old, new))


# 1. New JIT provider case + name + settings UI
settings = "LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift"
edit(settings, "    case StosDebugLC = 6\n", "    case StosDebugLC = 6\n    case BuiltIn = 7\n")
edit(settings, '        case .SideJITServer: "SideJITServer/JITStreamer 2.0"\n',
     '        case .SideJITServer: "SideJITServer/JITStreamer 2.0"\n'
     '        case .BuiltIn: "DockBox Built-in (Multitask apps)"\n')
edit(settings,
     '                    } label: {\n                        Text("lc.settings.jitEnabler".loc)\n                    }\n',
     '                    } label: {\n                        Text("lc.settings.jitEnabler".loc)\n                    }\n'
     '                    if JITEnabler == .BuiltIn { DockBoxJITSettingsSection() }\n')

# 2. Multitask launches know the guest PID: attach from this process
edit("LiveContainerSwiftUI/Views/AppList/LCAppListView.swift",
     '            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {\n'
     '                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {\n',
     '            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {\n'
     '                if jitEnabler == .BuiltIn {\n'
     '                    Task {\n'
     '                        do { try await DockBoxJIT.shared.enableJIT(pid: Int32(pid)) }\n'
     '                        catch {\n'
     '                            await MainActor.run { errorInfo = error.localizedDescription; errorShow = true }\n'
     '                        }\n'
     '                    }\n'
     '                    return\n'
     '                }\n'
     '                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {\n')

# 3. Same-process launches can't use it: fall back to StikDebug (or explain)
edit("LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift",
     '              let jitEnabler = JITEnablerType(rawValue: groupUserDefaults.integer(forKey: "LCJITEnablerType")) else {\n'
     '            return false\n        }\n',
     '              let configuredEnabler = JITEnablerType(rawValue: groupUserDefaults.integer(forKey: "LCJITEnablerType")) else {\n'
     '            return false\n        }\n'
     '        guard let jitEnabler = DockBoxJIT.sameProcessEnabler(for: configuredEnabler, onServerMessage: onServerMessage) else {\n'
     '            return false\n        }\n')

# 4. Per-app mode picker above the JIT section
edit("LiveContainerSwiftUI/Views/AppList/AppSettings/LCAppSettingsView.swift",
     '            Section {\n                Toggle(isOn: $model.uiIsJITNeeded) {\n',
     '            DockBoxModeSection(model: model)\n\n'
     '            Section {\n                Toggle(isOn: $model.uiIsJITNeeded) {\n')

# 5. Overlay sources (LiveContainerSwiftUI is a synchronized Xcode group: new files compile automatically)
dest = lc / "LiveContainerSwiftUI/DockBox"
dest.mkdir(exist_ok=True)
for f in (here / "overlay").rglob("*.swift"):   # JIT + modes, and the signing/cloud half under overlay/sign
    shutil.copy(f, dest / f.name)

# 5b. Zip library (pure Swift, MIT): compiled straight into the SwiftUI module
zdest = lc / "LiveContainerSwiftUI/ZIPFoundation"
zdest.mkdir(exist_ok=True)
for f in (zipf / "Sources/ZIPFoundation").glob("*.swift"):
    shutil.copy(f, zdest / f.name)

# 5c. Full Zsign engine (bundle signing, profile embedding, bundle-ID rewrite). Only the files the
# package itself compiles; archive.cpp, zsign.cpp and the third-party zip code are left out.
zb = lc / "DockBoxDeps/zsign"   # outside the Xcode project; compiled by build_zsign.sh
for sub in ("src/common", "swift"):
    (zb / sub).mkdir(parents=True, exist_ok=True)
compiled = ["archo", "bundle", "macho", "openssl", "signing"]
for stem in compiled:
    for ext in (".cpp", ".h"):
        shutil.copy(zsign_pkg / "src" / (stem + ext), zb / "src" / (stem + ext))
for stem in ["base64", "fs", "json", "log", "sha", "timer", "util"]:
    for ext in (".cpp", ".h"):
        shutil.copy(zsign_pkg / "src/common" / (stem + ext), zb / "src/common" / (stem + ext))
for extra in ["common.h", "mach-o.h", "archive.h"]:
    shutil.copy(zsign_pkg / "src/common" / extra, zb / "src/common" / extra)
for name in ("utils.mm", "utils.hpp", "zsign.mm", "zsign.hpp"):
    shutil.copy(zsign_pkg / "swift" / name, zb / "swift" / name)

# 5d. Swift sees the C functions through the existing bridging header
edit("LiveContainerSwiftUI/LiveContainerSwiftUI-Bridging-Header.h",
     '#include "../LiveContainer/FoundationPrivate.h"\n',
     '#include "../LiveContainer/FoundationPrivate.h"\n#include "../DockBoxDeps/zsign/swift/zsign.hpp"\n')

# 5e. New "Sign" tab next to Apps
edit("LiveContainerSwiftUI/Utilities/Shared.swift", "    case apps\n    case tweaks\n", "    case apps\n    case sign\n    case tweaks\n")
edit("LiveContainerSwiftUI/Views/LCTabView.swift",
     "            LCSettingsView()\n                .tabItem {\n",
     "            SignDockHub()\n                .tabItem {\n"
     "                    Label(\"Sign\", systemImage: \"signature\")\n                }\n"
     "                .tag(LCTabIdentifier.sign)\n\n"
     "            LCSettingsView()\n                .tabItem {\n")

# 6. idevice: header + module map + static lib from StikDebug, linked into the SwiftUI target only
deps = lc / "DockBoxDeps/idevice"
deps.mkdir(parents=True, exist_ok=True)
for name in ("idevice.h", "module.modulemap", "libidevice_ffi.a"):
    shutil.copy(stik / "StikDebug/idevice" / name, deps / name)

pbx = lc / "LiveContainer.xcodeproj/project.pbxproj"
text = pbx.read_text()
for cfg in ("17413FBF2D9C0BAE00F3F928", "17413FC02D9C0BAE00F3F928"):
    start = text.index(f"\t\t{cfg} /*")
    end = text.index("\n\t\t};", start)
    block = text[start:end]
    old = 'OTHER_LDFLAGS = "-Wl,-U,_OBJC_CLASS_$_RBSTarget";'
    assert block.count(old) == 1, f"pbxproj {cfg}: OTHER_LDFLAGS anchor not found once"
    for key in ("FRAMEWORK_SEARCH_PATHS",):
        assert key not in block, f"pbxproj {cfg}: {key} already set; merge by hand"
    block = block.replace(
        old,
        'OTHER_LDFLAGS = "-Wl,-U,_OBJC_CLASS_$_RBSTarget -L$(SRCROOT)/DockBoxDeps/idevice -lidevice_ffi -L$(SRCROOT)/DockBoxDeps/zsign -lzsignbundle -lc++ -framework OpenSSL";\n'
        '\t\t\t\tSWIFT_INCLUDE_PATHS = "$(inherited) $(SRCROOT)/DockBoxDeps/idevice";\n'
        '\t\t\t\tFRAMEWORK_SEARCH_PATHS = ("$(inherited)", "$(PROJECT_DIR)/OpenSSL/Frameworks/iphoneos");')
    text = text[:start] + block + text[end:]
pbx.write_text(text)

# 7. Branding + a URL scheme SignDock can detect
info = lc / "LiveContainer/Info.plist"
s = info.read_text()
s, n = re.subn(r"(<key>CFBundleDisplayName</key>\s*<string>)LiveContainer(</string>)", r"\1DockBox\2", s)
assert n == 1, "Info.plist: CFBundleDisplayName"
anchor = "<key>CFBundleURLSchemes</key>\n\t\t\t<array>\n\t\t\t\t<string>livecontainer</string>"
assert s.count(anchor) == 1, "Info.plist: URL scheme anchor"
s = s.replace(anchor, anchor + "\n\t\t\t\t<string>dockbox</string>")
info.write_text(s)
print("DockBox applied.")
