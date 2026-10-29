"""Prepare a matched official Sherpa/ONNX iOS distribution, preserving runtime ABI."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import tempfile
import urllib.request
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "ThirdParty/SherpaOnnx/Artifacts/paired-ios"
DIGEST = "63572187c200d70e1b09b47f1bf4e3435ea1c9ced4ca656268fa7d0b94e12610"
URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.3/sherpa-onnx-v1.13.3-ios-no-tts.tar.bz2"


def prepare_pair(unpacked: Path, prepared: Path):
    prepared.mkdir()
    for name in ["sherpa-onnx", "onnxruntime"]:
        source = next(unpacked.rglob(name + ".xcframework"))
        target = prepared / (name + ".xcframework")
        shutil.copytree(source, target)
        metadata = plistlib.loads((target / "Info.plist").read_bytes())
        for entry in metadata["AvailableLibraries"]:
            variant = target / entry["LibraryIdentifier"]
            if name == "sherpa-onnx":
                headers = variant / "Headers"
                shutil.copytree(target / "Headers", headers)
                (headers / "module.modulemap").write_text(
                    'module sherpa_onnx { header "sherpa-onnx/c-api/c-api.h" export * }\n')
                entry["HeadersPath"] = "Headers"
            else:
                framework = variant / entry["LibraryPath"]
                modules = framework / "Modules"
                modules.mkdir(exist_ok=True)
                (modules / "module.modulemap").write_text(
                    'framework module onnxruntime { header "onnxruntime_c_api.h" export * }\n')
                header = (framework / "Headers/onnxruntime_c_api.h").read_text()
                if "#define ORT_API_VERSION 26" not in header:
                    raise RuntimeError("Unexpected ONNX Runtime ABI")
        (target / "Info.plist").write_bytes(plistlib.dumps(metadata))
    (prepared / "Info.plist").write_bytes(plistlib.dumps({"Release": "v1.13.3", "ORT_API_VERSION": 26}))


def file_digests(directory: Path):
    if os.name == "nt" and not str(directory).startswith("\\\\?\\"):
        directory = Path("\\\\?\\" + str(directory.resolve()))
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_file() and path.name != "prepared.json":
            digest = hashlib.sha256()
            with path.open("rb") as data:
                for block in iter(lambda: data.read(1024 * 1024), b""):
                    digest.update(block)
            result[path.relative_to(directory).as_posix()] = digest.hexdigest()
    return result


def cache_valid(directory: Path):
    try:
        marker = json.loads((directory / "prepared.json").read_text())
        if marker.get("sha256") != DIGEST or marker.get("layout") != 2:
            return False
        expected = marker.get("files")
        return isinstance(expected, dict) and "Info.plist" in expected and expected == file_digests(directory)
    except (OSError, ValueError, AttributeError):
        return False


def main():
    if cache_valid(OUTPUT):
        return
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sherpa-prepare-") as temp:
        temp = Path(temp)
        archive = temp / "official-ios.tar.bz2"
        with urllib.request.urlopen(URL, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        digest = hashlib.sha256()
        with archive.open("rb") as data:
            for block in iter(lambda: data.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != DIGEST:
            raise RuntimeError("Official iOS bundle SHA256 mismatch")
        unpacked = temp / "unpacked"
        with tarfile.open(archive) as bundle:
            members = []
            for member in bundle.getmembers():
                if not (unpacked / member.name).resolve().is_relative_to(unpacked.resolve()):
                    raise RuntimeError("Unsafe archive path")
                if member.issym():
                    # Convenience aliases only; metadata names the actual archive.
                    continue
                if not member.isfile() and not member.isdir():
                    raise RuntimeError("Unsupported archive entry")
                members.append(member)
            bundle.extractall(unpacked, members=members)
        prepared = temp / "prepared"
        prepare_pair(unpacked, prepared)
        (prepared / "prepared.json").write_text(json.dumps({
            "sha256": DIGEST, "layout": 2, "files": file_digests(prepared)
        }))
        if OUTPUT.exists():
            if OUTPUT.resolve().parent != (ROOT / "ThirdParty/SherpaOnnx/Artifacts").resolve():
                raise RuntimeError("Unexpected artifact output path")
            delete_path = "\\\\?\\" + str(OUTPUT.resolve()) if os.name == "nt" else OUTPUT
            shutil.rmtree(delete_path)
        shutil.move(str(prepared), str(OUTPUT))
    print("Verified matched official Sherpa/ONNX iOS bundle prepared (Runtime API 26)")


if __name__ == "__main__":
    main()
