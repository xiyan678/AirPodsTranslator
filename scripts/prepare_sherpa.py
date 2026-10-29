"""Wrap ONNX's static library as a framework to isolate its module map from Sherpa's.

Runs before XcodeGen. The static archive is unchanged; only bundle layout changes.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "ThirdParty/SherpaOnnx/Artifacts/onnxruntime.xcframework"
DIGEST = "5a18cf7abd25800d77e7365f7f05dc8322d2deed8bde8daa57ba2c282fec4ea5"
URL = "https://github.com/willwade/sherpa-onnx-spm/releases/download/1.13.8/onnxruntime.xcframework.zip"


def convert(source: Path, destination: Path):
    metadata = plistlib.loads((source / "Info.plist").read_bytes())
    for entry in metadata["AvailableLibraries"]:
        identifier = entry["LibraryIdentifier"]
        original = source / identifier
        framework = destination / identifier / "onnxruntime.framework"
        framework.mkdir(parents=True)
        shutil.copy2(original / entry["LibraryPath"], framework / "onnxruntime")
        shutil.copytree(original / entry["HeadersPath"], framework / "Headers")
        (framework / "Headers/module.modulemap").unlink(missing_ok=True)
        (framework / "Modules").mkdir()
        (framework / "Modules/module.modulemap").write_text(
            'framework module onnxruntime { header "onnxruntime_c_api.h" export * }\n')
        (framework / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "onnxruntime", "CFBundleIdentifier": "org.onnxruntime.static",
            "CFBundleName": "onnxruntime", "CFBundlePackageType": "FMWK",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        }))
        entry["LibraryPath"] = "onnxruntime.framework"
        entry["BinaryPath"] = "onnxruntime.framework/onnxruntime"
        entry.pop("HeadersPath", None)
    (destination / "Info.plist").write_bytes(plistlib.dumps(metadata))


def main():
    marker = OUTPUT / "prepared.json"
    if marker.exists() and json.loads(marker.read_text()) == {"sha256": DIGEST, "layout": 1}:
        return
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sherpa-prepare-") as temp:
        temp = Path(temp)
        archive = temp / "onnx.zip"
        with urllib.request.urlopen(URL, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        with archive.open("rb") as data:
            digest = hashlib.sha256()
            for block in iter(lambda: data.read(1024 * 1024), b""):
                digest.update(block)
            actual = digest.hexdigest()
        if actual != DIGEST:
            raise RuntimeError("ONNX artifact SHA256 mismatch")
        with zipfile.ZipFile(archive) as bundle:
            for item in bundle.infolist():
                resolved = (temp / "unpacked" / item.filename).resolve()
                if not resolved.is_relative_to((temp / "unpacked").resolve()):
                    raise RuntimeError("Unsafe archive path")
            bundle.extractall(temp / "unpacked")
        source = next((temp / "unpacked").rglob("onnxruntime.xcframework"))
        prepared = temp / "prepared"
        convert(source, prepared)
        (prepared / "prepared.json").write_text(json.dumps({"sha256": DIGEST, "layout": 1}))
        if OUTPUT.exists():
            if OUTPUT.resolve().parent != (ROOT / "ThirdParty/SherpaOnnx/Artifacts").resolve():
                raise RuntimeError("Unexpected artifact output path")
            shutil.rmtree(OUTPUT)
        shutil.move(str(prepared), str(OUTPUT))
    print("Verified ONNX static framework prepared; module maps have separate output paths")


if __name__ == "__main__":
    main()
