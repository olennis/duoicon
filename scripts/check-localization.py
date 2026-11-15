"""Run after swift build -c release; no app permissions or preferences are changed."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = "DuoIcon" if (ROOT / "Sources/DuoIcon").exists() else "Unmouse"
SOURCE = ROOT / "Sources" / APP
RESOURCES = SOURCE / "Resources"


def read_strings(path):
    return json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(path)
    ]))


en = read_strings(RESOURCES / "en.lproj/Localizable.strings")
ko = read_strings(RESOURCES / "ko.lproj/Localizable.strings")
assert en.keys() == ko.keys(), "English and Korean translation keys differ"
for key in en:
    def placeholders(value):
        return sorted(re.findall(r"%(?:\d+\$)?[@df]", value.replace("%%", "")))
    assert placeholders(en[key]) == placeholders(ko[key]), f"Format mismatch: {key}"

for path in SOURCE.glob("*.swift"):
    for literal in re.findall(r'L10n\.(?:text|format)\(("(?:[^"\\]|\\.)*")', path.read_text()):
        key = json.loads(literal)
        assert key in en, f"Missing translation in {path.name}: {key}"

accessors = list((ROOT / ".build").glob("**/release/*build/DerivedSources/resource_bundle_accessor.swift"))
assert accessors, "Run swift build -c release first"
resource_bundle = (ROOT / ".build/release" / f"{APP}_{APP}.bundle").resolve()
assert resource_bundle.exists(), "Built resource bundle is missing"

# Compile the real localization implementation; only the entry point is a probe.
probe_source = '''import Foundation
let expected = CommandLine.arguments[1]
precondition(L10n.text("Settings…") == expected, "Unexpected language: \\(L10n.text("Settings…"))")
precondition(L10n.text("missing.translation.key") == "missing.translation.key")
let korean = expected == "설정…"
APP_CHECKS
print("PASS: " + expected)
'''
if APP == "DuoIcon":
    checks = '''precondition(L10n.format("Connected: %@", "Cafe 100%") == (korean ? "연결됨: Cafe 100%" : "Connected: Cafe 100%"))
precondition(L10n.format("%d%% - %@", 42, L10n.text("Charging")) == (korean ? "42% - 충전 중" : "42% - Charging"))
precondition(L10n.format("%@, %@, Volume %d%%", "battery", "wifi", 75) == (korean ? "battery, wifi, 음량 75%" : "battery, wifi, Volume 75%"))'''
else:
    checks = '''precondition(L10n.format("Desktop %d", 2) == (korean ? "데스크탑 2" : "Desktop 2"))
precondition(L10n.format("No Results for “%@”", "100% test") == (korean ? "“100% test” 검색 결과 없음" : "No Results for “100% test”"))
precondition(L10n.format("Windows: %d", 1) == (korean ? "1개" : "Windows: 1"))
precondition(L10n.format("Open Settings  ⌘%@", "2") == (korean ? "설정 열기  ⌘2" : "Open Settings  ⌘2"))'''
probe_source = probe_source.replace("APP_CHECKS", checks)
cases = [
    ("(ko-KR)", "설정…"), ("(en-GB)", "Settings…"),
    ("(fr-FR)", "Settings…"), ("(ja-JP, fr-FR)", "Settings…"),
    ("(fr-FR, ko-KR, en-US)", "설정…"), ("(en-US, ko-KR)", "Settings…"),
]
with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    main = temp / "main.swift"
    main.write_text(probe_source)
    executable = temp / "probe"
    subprocess.run(["swiftc", str(SOURCE / "Localization.swift"), str(accessors[0]), str(main), "-o", str(executable)], check=True)
    for preferences, expected in cases:
        subprocess.run([str(executable), expected, "-AppleLanguages", preferences], check=True)

    # A relocated app must load its own resources, without using the checkout.
    app = temp / "Relocated.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "Resources").mkdir()
    info = ROOT / ("Info.plist" if APP == "DuoIcon" else "Resources/Info.plist")
    shutil.copy2(info, app / "Info.plist")
    shutil.copytree(resource_bundle, app / "Resources" / resource_bundle.name)
    no_fallback = temp / "NoBuildFallback.swift"
    no_fallback.write_text('import Foundation\nextension Bundle { static var module: Bundle { fatalError("Used build-directory fallback") } }\n')
    installed = app / "MacOS" / APP
    subprocess.run(["swiftc", str(SOURCE / "Localization.swift"), str(no_fallback), str(main), "-o", str(installed)], check=True)
    for preferences, expected in cases:
        subprocess.run([str(installed), expected, "-AppleLanguages", preferences], check=True)
print(f"PASS: {APP}: {len(en)} translations, placeholders, source coverage, formatting, 12 CLI/relocated-app language cases")
