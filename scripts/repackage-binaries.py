#!/usr/bin/env python3
"""Build an exact production commit for local preview or an owner-only GitHub draft."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from release_draft import (
    find_draft_record,
    generate_release_notes,
    is_official_origin,
    resolve_mode,
    verify_draft_record,
    verify_local_artifacts,
)

REPO = "ilovespectra/CruiseControl"
ROOT = Path(__file__).resolve().parent.parent
SUPPORTED_STAGING_FILESYSTEMS = {"apfs", "hfs"}


def run(*args, cwd=ROOT, capture=False, env=None):
    print("+ " + " ".join(str(arg) for arg in args), flush=True)
    result = subprocess.run(args, cwd=cwd, env=env, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def _version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value):
        return None
    return tuple(map(int, value.split(".")))


def _next_rollover(version):
    major, minor, patch = version
    if minor > 9:
        return f"{major + 1}.0.0"
    if patch > 9:
        return f"{major}.{minor + 1}.0" if minor < 9 else f"{major + 1}.0.0"
    if patch < 9:
        return f"{major}.{minor}.{patch + 1}"
    if minor < 9:
        return f"{major}.{minor + 1}.0"
    return f"{major + 1}.0.0"


def next_version(releases, baseline, staged=()):
    published = [release["tag_name"].removeprefix("v") for release in releases
                 if not release["draft"] and not release["prerelease"]]
    versions = [version for value in [*published, baseline, *staged]
                if (version := _version_tuple(value)) is not None]
    if not versions:
        raise RuntimeError("No valid version baseline is available.")
    return _next_rollover(max(versions))


def validate_release_owner(login, metadata, repository=REPO):
    expected_owner, _, expected_name = repository.partition("/")
    actual_owner = str(metadata.get("owner", {}).get("login", ""))
    full_name = str(metadata.get("full_name", ""))
    if not expected_name or full_name.casefold() != repository.casefold():
        raise RuntimeError(f"Release denied: GitHub did not confirm the official repository {repository}.")
    if login.casefold() != expected_owner.casefold() or actual_owner.casefold() != login.casefold():
        raise RuntimeError(f"Release denied: authenticate as the owner of {repository}.")
    if metadata.get("permissions", {}).get("admin") is not True:
        raise RuntimeError(f"Release denied: the authenticated owner needs admin permission on {repository}.")
    return login


def verify_release_owner():
    login = run("gh", "api", "user", "--jq", ".login", capture=True)
    try:
        metadata = json.loads(run("gh", "api", f"repos/{REPO}", capture=True))
    except (json.JSONDecodeError, subprocess.CalledProcessError) as error:
        raise RuntimeError(f"Could not verify official repository owner permissions: {error}") from error
    return validate_release_owner(login, metadata)


def stable_release(releases):
    stable = [release for release in releases
              if not release.get("draft") and not release.get("prerelease")
              and _version_tuple(str(release.get("tag_name", "")).removeprefix("v"))]
    return max(stable, key=lambda item: _version_tuple(item["tag_name"].removeprefix("v")), default=None)


def get_release_metadata():
    pages = json.loads(run("gh", "api", "--paginate", "--slurp",
                           f"repos/{REPO}/releases?per_page=100", capture=True))
    if not isinstance(pages, list):
        raise RuntimeError("GitHub returned invalid release metadata.")
    releases = [release for page in pages for release in page]
    if not all(isinstance(release, dict) for release in releases):
        raise RuntimeError("GitHub returned malformed release metadata.")
    return releases


def staged_versions():
    staged = []
    staged_root = ROOT / "build" / "releases"
    if staged_root.is_dir():
        for manifest_path in staged_root.glob("*/release.json"):
            try:
                staged_version = json.loads(manifest_path.read_text()).get("version")
            except (OSError, json.JSONDecodeError):
                continue
            if _version_tuple(staged_version) is not None:
                staged.append(staged_version)
    return staged


def prepare_staging_root(path=None):
    root = Path(path or tempfile.gettempdir()).expanduser()
    try:
        root.mkdir(parents=True, exist_ok=True)
        root = root.resolve()
        df_output = run("df", "-P", str(root), capture=True)
        rows = [line for line in df_output.splitlines() if line.strip()]
        if len(rows) < 2:
            raise RuntimeError("df did not report the staging volume")
        fields = rows[-1].split(maxsplit=5)
        if len(fields) < 6:
            raise RuntimeError("df returned an incomplete staging-volume row")
        mountpoint = fields[5]
        metadata = plistlib.loads(run("diskutil", "info", "-plist", mountpoint, capture=True).encode("utf-8"))
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException, ValueError) as error:
        raise RuntimeError(f"Could not verify the temporary build volume at {root}: {error}") from error
    filesystem = str(metadata.get("FilesystemType", "")).lower()
    display_name = str(metadata.get("FilesystemName", filesystem or "unknown"))
    if filesystem not in SUPPORTED_STAGING_FILESYSTEMS:
        raise RuntimeError(
            f"Temporary build volume is {display_name}; pkgbuild's package output must be on APFS or HFS+. "
            "Choose an APFS/HFS+ --staging-root (exFAT output triggers BOMStream buffer overflow)."
        )
    return root


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging-root", type=Path,
                        help="Temporary build directory on APFS/HFS+ (for example, an external drive)")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--draft", action="store_true",
                       help="Create an unpublished GitHub draft only when official owner/admin checks pass")
    modes.add_argument("--preview", action="store_true",
                       help="Build an unsigned local preview; never create or publish a GitHub release")
    parser.add_argument("--unsigned", action="store_true",
                        help=argparse.SUPPRESS)  # compatibility with old console invocations
    return parser.parse_args()


def main():
    args = parse_args()
    if os.uname().sysname != "Darwin":
        raise RuntimeError("Repackaging requires macOS, Swift, Python 3 and GitHub CLI.")
    if run("git", "status", "--porcelain", capture=True):
        raise RuntimeError("Commit your changes first. The build must match a clean, pushed production commit.")

    # A draft request must prove the official owner/admin identity before release metadata is read.
    # Any failed check safely downgrades to a local-only preview, never to a direct/public release.
    requested_mode = "preview" if args.preview else "draft"
    mode, login, owner_error = resolve_mode(requested_mode, verify_release_owner)
    if mode == "draft":
        print(f"Owner/admin preflight passed for @{login} on {REPO}.", flush=True)
        origin = run("git", "remote", "get-url", "origin", capture=True)
        if not is_official_origin(origin):
            print(f"Draft denied: origin {origin!r} is not {REPO}; continuing as a local preview only.", flush=True)
            mode = "preview"
    elif owner_error:
        print(f"Owner-only draft unavailable ({owner_error}); continuing as a local preview only.", flush=True)

    branch = json.loads(run("gh", "repo", "view", REPO, "--json", "defaultBranchRef", capture=True))["defaultBranchRef"]["name"]
    run("git", "fetch", "origin", branch)
    commit = run("git", "rev-parse", f"origin/{branch}", capture=True)
    if run("git", "rev-parse", "HEAD", capture=True) != commit:
        raise RuntimeError(f"Checkout the latest origin/{branch} commit before repackaging; no local changes were altered.")

    releases = get_release_metadata()
    baseline = run("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
                   "Resources/Info.plist", capture=True)
    version = next_version(releases, baseline, staged_versions() if mode == "preview" else ())
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise RuntimeError("Invalid release version.")
    tag = f"v{version}"
    if any(release.get("tag_name") == tag for release in releases):
        raise RuntimeError(f"{tag} already exists as a draft or prerelease. Resolve it before retrying; versions are not skipped.")

    signed = False  # Publisher intentionally creates unsigned drafts until notarization is configured.
    output_name = f"{version}-preview" if mode == "preview" else f"{version}-draft"
    output = ROOT / "build" / "releases" / output_name
    if output.exists():
        raise RuntimeError(f"Output already exists: {output}. Preserve or move it before retrying this version.")

    staging_root = prepare_staging_root(args.staging_root)
    print(f"Using verified APFS/HFS+ staging volume: {staging_root}", flush=True)
    stage_env = dict(os.environ, TMPDIR=str(staging_root))

    # TemporaryDirectory owns only this invocation's staging directory, never the checkout or outputs.
    with tempfile.TemporaryDirectory(prefix="cruise-release-", dir=str(staging_root)) as temporary:
        stage = Path(temporary)
        archive = stage / "source.tar"
        run("git", "archive", "--format=tar", f"--output={archive}", commit)
        workspace = stage / "source"
        workspace.mkdir()
        run("tar", "-xf", str(archive), "-C", str(workspace))
        run("swift", "test", cwd=workspace, env=stage_env)
        env = dict(stage_env, CC_VERSION=version, CC_BUILD=str(int(version.split(".")[0]) * 1000000
                   + int(version.split(".")[1]) * 1000 + int(version.split(".")[2])),
                   CC_SOURCE_COMMIT=commit, CC_UNIVERSAL="1")
        run("bash", "scripts/build-app.sh", cwd=workspace, env=env)
        app = workspace / "build" / "Cruise Control.app"
        run("codesign", "--verify", "--deep", "--strict", str(app))
        binary = app / "Contents" / "MacOS" / "CruiseControl"
        architectures = set(run("lipo", "-archs", str(binary), capture=True).split())
        if not {"arm64", "x86_64"}.issubset(architectures):
            raise RuntimeError(f"The installer is not universal; found architectures: {sorted(architectures)}")
        actual_version = run("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
                             str(app / "Contents" / "Info.plist"), capture=True)
        if actual_version != version:
            raise RuntimeError(f"Built app version {actual_version} does not match selected release {version}.")
        scripts = stage / "installer-scripts"
        scripts.mkdir()
        (scripts / "postinstall").write_text((workspace / "scripts" / "package-postinstall.sh").read_text())
        (scripts / "postinstall").chmod(0o755)
        package = stage / "CruiseControl.pkg"
        command = ["pkgbuild", "--component", str(app), "--install-location", "/Applications",
                   "--identifier", "com.ilovespectra.cruisecontrol", "--version", version,
                   "--scripts", str(scripts), str(package)]
        run(*command, env=stage_env)
        print("pkgbuild exited successfully; checking the package payload and installer metadata.", flush=True)
        expanded_package = stage / "expanded-package"
        run("pkgutil", "--expand-full", str(package), str(expanded_package), env=stage_env)
        try:
            package_info = ET.parse(expanded_package / "PackageInfo").getroot()
        except (OSError, ET.ParseError) as error:
            raise RuntimeError(f"Could not read packaged installer metadata: {error}") from error
        expected_payload = expanded_package / "Payload" / "Cruise Control.app" / "Contents" / "MacOS" / "CruiseControl"
        if package_info.attrib.get("identifier") != "com.ilovespectra.cruisecontrol" or package_info.attrib.get("version") != version:
            raise RuntimeError("Installer package identifier or version does not match the selected release.")
        if not expected_payload.is_file() or expected_payload.stat().st_size == 0:
            raise RuntimeError("Installer package is missing the Cruise Control executable payload.")
        if not (expanded_package / "Scripts" / "postinstall").is_file():
            raise RuntimeError("Installer package is missing its postinstall script.")
        manifest = {
            "version": version, "commit": commit, "package": package.name,
            "sha256": hashlib.sha256(package.read_bytes()).hexdigest(),
            "architecture": "universal", "minimumMacOS": "14.0", "notarized": signed,
        }
        output.mkdir(parents=True)
        saved = output / package.name
        saved.write_bytes(package.read_bytes())
        metadata = output / "release.json"
        metadata.write_text(json.dumps(manifest, indent=2) + "\n")
        checksums = output / "SHA256SUMS"
        checksums.write_text(f"{manifest['sha256']}  {package.name}\n")
        facts = verify_local_artifacts(saved, metadata, checksums, version, commit, signed)
        print(f"Verified local package SHA-256 {facts['sha256']} ({facts['size']} bytes), manifest, and checksum.", flush=True)

    if mode == "draft":
        latest = stable_release(releases)
        previous_tag = latest.get("tag_name") if latest else None
        subjects = []
        diffstat = ""
        if previous_tag:
            try:
                run("git", "fetch", "origin", f"refs/tags/{previous_tag}:refs/tags/{previous_tag}")
                subjects = run("git", "log", "--format=%s", f"{previous_tag}..{commit}", capture=True).splitlines()
                diffstat = run("git", "diff", "--stat", f"{previous_tag}..{commit}", capture=True)
            except subprocess.CalledProcessError as error:
                raise RuntimeError(f"Could not verify the change range since {previous_tag}; no GitHub draft was created: {error}") from error
        notes_path = output / "release-notes.md"
        notes = generate_release_notes(version, commit, previous_tag, subjects, diffstat,
                                       notes_path, notarized=signed)
        run("gh", "release", "create", tag, str(saved), str(metadata), str(checksums), "--repo", REPO,
            "--target", commit, "--title", f"Cruise Control {version}",
            "--notes-file", str(notes_path), "--draft")
        # GitHub does not expose an unpublished draft through /releases/tags/{tag};
        # the authenticated, paginated releases list includes it and its asset digests.
        record = find_draft_record(get_release_metadata(), tag)
        link = verify_draft_record(record, tag, commit, [saved, metadata, checksums])
        print(f"Verified unpublished GitHub draft {tag} from {commit}: {link}", flush=True)
        print(f"Assets verified: {saved.name}, {metadata.name}, {checksums.name}.", flush=True)
    else:
        print(f"Local preview built {version} from {commit}; no GitHub release was created.\n{saved}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Repackaging failed: {error}")
