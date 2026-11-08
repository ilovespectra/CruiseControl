#!/usr/bin/env python3
"""Package an exact production commit; explicitly opt into unsigned distribution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = "ilovespectra/CruiseControl"
ROOT = Path(__file__).resolve().parent.parent


def run(*args, cwd=ROOT, capture=False, env=None):
    print("+ " + " ".join(str(arg) for arg in args), flush=True)
    result = subprocess.run(args, cwd=cwd, env=env, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def next_version(releases, baseline):
    published = [release["tag_name"].removeprefix("v") for release in releases
                 if not release["draft"] and not release["prerelease"]]
    versions = [tuple(map(int, version.split("."))) for version in published
                if re.fullmatch(r"\d+\.\d+\.\d+", version)]
    if not versions:
        major, minor, patch = map(int, baseline.split("."))
        return f"{major}.{minor}.{patch + 1}"
    major, minor, patch = max(versions)
    return f"{major}.{minor}.{patch + 1}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true", help="Publish after notarization succeeds")
    parser.add_argument("--preview", action="store_true", help="Build an unsigned local preview, never publish")
    parser.add_argument("--unsigned", action="store_true", help="Explicitly publish without Developer ID; macOS will warn")
    args = parser.parse_args()
    if args.publish == args.preview:
        parser.error("Choose --publish or --preview")
    if os.uname().sysname != "Darwin":
        raise RuntimeError("Repackaging requires macOS, Swift, Python 3 and GitHub CLI.")
    if run("git", "status", "--porcelain", capture=True):
        raise RuntimeError("Commit your changes first. The build must match a clean, pushed production commit.")
    branch = json.loads(run("gh", "repo", "view", REPO, "--json", "defaultBranchRef", capture=True))["defaultBranchRef"]["name"]
    run("git", "fetch", "origin", branch)
    commit = run("git", "rev-parse", f"origin/{branch}", capture=True)
    if run("git", "rev-parse", "HEAD", capture=True) != commit:
        raise RuntimeError(f"Checkout the latest origin/{branch} commit before repackaging; no local changes were altered.")
    releases = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{REPO}/releases?per_page=100", capture=True))
    releases = [release for page in releases for release in page]
    baseline = run("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", "Resources/Info.plist", capture=True)
    version = next_version(releases, baseline)
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise RuntimeError("Invalid release version.")
    tag = f"v{version}"
    if any(release["tag_name"] == tag for release in releases):
        raise RuntimeError(f"{tag} already exists as a draft or prerelease. Resolve it before retrying; versions are not skipped.")
    application_identity = os.environ.get("CC_SIGN_IDENTITY", "")
    installer_identity = os.environ.get("CC_INSTALLER_IDENTITY", "")
    profile = os.environ.get("CC_NOTARY_PROFILE", "CruiseControl")
    signed = args.publish and not args.unsigned
    if signed:
        if not application_identity.startswith("Developer ID Application:") or not installer_identity.startswith("Developer ID Installer:"):
            raise RuntimeError("Publishing requires CC_SIGN_IDENTITY (Developer ID Application) and CC_INSTALLER_IDENTITY (Developer ID Installer). Local signing is not sufficient.")
        run("xcrun", "notarytool", "history", "--keychain-profile", profile)
    output = ROOT / "build" / "releases" / (f"{version}-preview" if args.preview else version)
    if output.exists():
        raise RuntimeError(f"Output already exists: {output}. Preserve or move it before retrying this version.")
    # TemporaryDirectory owns only this invocation's staging directory, never the checkout or outputs.
    with tempfile.TemporaryDirectory(prefix="cruise-release-") as temporary:
        stage = Path(temporary)
        archive = stage / "source.tar"
        run("git", "archive", "--format=tar", f"--output={archive}", commit)
        workspace = stage / "source"
        workspace.mkdir()
        run("tar", "-xf", str(archive), "-C", str(workspace))
        run("swift", "test", cwd=workspace)
        env = dict(os.environ, CC_VERSION=version, CC_BUILD=str(int(version.split(".")[0]) * 1000000
                   + int(version.split(".")[1]) * 1000 + int(version.split(".")[2])),
                   CC_SOURCE_COMMIT=commit, CC_UNIVERSAL="1")
        run("bash", "scripts/build-app.sh", cwd=workspace, env=env)
        app = workspace / "build" / "Cruise Control.app"
        run("codesign", "--verify", "--deep", "--strict", str(app))
        scripts = stage / "installer-scripts"
        scripts.mkdir()
        (scripts / "postinstall").write_text((workspace / "scripts" / "package-postinstall.sh").read_text())
        (scripts / "postinstall").chmod(0o755)
        package = stage / "CruiseControl.pkg"
        command = ["pkgbuild", "--component", str(app), "--install-location", "/Applications",
                   "--identifier", "com.ilovespectra.cruisecontrol", "--version", version,
                   "--scripts", str(scripts), str(package)]
        if signed:
            command[-1:-1] = ["--sign", installer_identity]
        run(*command)
        if signed:
            run("xcrun", "notarytool", "submit", str(package), "--keychain-profile", profile, "--wait")
            run("xcrun", "stapler", "staple", str(package))
            run("xcrun", "stapler", "validate", str(package))
            run("spctl", "--assess", "--type", "install", str(package))
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
        if args.publish:
            # Creating the release is the final operation: failed builds do not advance the published version.
            run("gh", "release", "create", tag, str(saved), str(metadata), str(checksums), "--repo", REPO,
                "--target", commit, "--title", f"Cruise Control {version}",
                "--notes", f"Universal macOS 14+ installer. Production source commit: {commit}. "
                + ("Signed and notarized." if signed else "Unsigned and not notarized: macOS will warn. Review the source and use System Settings > Privacy & Security to approve installation if you trust it."),
                "--latest")
        print(f"{'Published' if args.publish else 'Preview built'} {version} from {commit}\n{saved}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        raise SystemExit(f"Repackaging failed: {error}")
