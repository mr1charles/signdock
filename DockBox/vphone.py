#!/usr/bin/env python3
"""Turns a tree already patched by apply.py into VPhone, a separate app that installs beside DockBox.
usage: vphone.py <livecontainer-dir>"""
import pathlib, shutil, sys

lc = pathlib.Path(sys.argv[1])
here = pathlib.Path(__file__).parent

def edit(rel, old, new):
    p = lc / rel
    s = p.read_text()
    assert s.count(old) == 1, f"{rel}: {old!r}"
    p.write_text(s.replace(old, new))

edit("xcconfigs/Global.xcconfig", "com.kdt.livecontainer$", "com.dockbox.vphone$")
edit("LiveContainer/Info.plist", "<string>DockBox</string>", "<string>VPhone</string>")
edit("LiveContainer/Info.plist", "<string>livecontainer</string>\n\t\t\t\t<string>dockbox</string>", "<string>vphone</string>")
# Its only scheme isn't "livecontainer", which would otherwise mark it a secondary copy with tabs hidden.
edit("LiveContainerSwiftUI/Utilities/Shared.swift", 'LCUtils.appUrlScheme()?.lowercased() != "livecontainer"', 'LCUtils.appUrlScheme()?.lowercased() != "vphone"')
edit("LiveContainerSwiftUI/Utilities/Shared.swift", "public enum LCTabIdentifier: Hashable {\n", "public enum LCTabIdentifier: Hashable {\n    case vphone\n")
edit("LiveContainerSwiftUI/Utilities/Shared.swift", "@Published var selectedTab: LCTabIdentifier = .apps", "@Published var selectedTab: LCTabIdentifier = .vphone")
edit("LiveContainerSwiftUI/Views/LCTabView.swift", "TabView(selection: $sharedModel.selectedTab) {\n",
     'TabView(selection: $sharedModel.selectedTab) {\n'
     '            VPhoneHomeView()\n'
     '                .tabItem { Label("Phone", systemImage: "iphone") }\n'
     '                .tag(LCTabIdentifier.vphone)\n')
shutil.copy(here / "vphone/VPhoneHome.swift", lc / "LiveContainerSwiftUI/DockBox/VPhoneHome.swift")
def set_icon(lc, here, name):
    """Writes the light, dark and tinted icons over the file names AppIcon's Contents.json lists."""
    import json, shutil
    folder = lc / "Resources/Assets.xcassets/AppIcon.appiconset"
    for image in json.loads((folder / "Contents.json").read_text())["images"]:
        if "filename" not in image:
            continue
        look = next((a["value"] for a in image.get("appearances", []) if a["appearance"] == "luminosity"), None)
        suffix = {"dark": "-dark", "tinted": "-tinted"}.get(look, "")
        shutil.copy(here / f"icons/{name}{suffix}.png", folder / image["filename"])

set_icon(lc, here, "vphone")
print("VPhone applied.")
