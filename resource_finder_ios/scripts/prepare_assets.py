"""Reuse the exact established Android launcher art; no generated redesign."""
import base64
import json
import pathlib
import struct
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
# Render Apple's 1024px opaque icon from the shared Android launcher artwork.
source = root / "Generated/launcher_art.png"
source.parent.mkdir(parents=True, exist_ok=True)
source.write_bytes(base64.b64decode((root / "Resources/launcher_art.png.b64").read_bytes(), validate=False))
assert source.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "Invalid launcher artwork"
assets = root / "Sources/UI/Assets.xcassets"
icon = assets / "AppIcon.appiconset"
icon.mkdir(parents=True, exist_ok=True)
(assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
subprocess.run(["swift", str(root / "scripts/PrepareIcon.swift"), str(source), str(icon / "icon.png")], check=True)
data = (icon / "icon.png").read_bytes()
assert struct.unpack(">II", data[16:24]) == (1024, 1024)
(icon / "Contents.json").write_text(json.dumps({"images": [{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}))
