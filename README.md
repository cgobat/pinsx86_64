# pinsx64

Debian x64 build and install automation for the PINS stack.

## Repo Contents

- `.github/workflows/`: GitHub Actions workflows for building Debian amd64 packages (including PINS components and related dependencies).
- `build-scripts/build-and-install-pins-x64.sh`: local all-in-one build and install script.
- `build-scripts/install-trixie-x64-from-release.sh`: Debian Trixie x64 installer that pulls release `.deb` assets, installs OpenCV 4.11, verifies INDI 2.1.9.x, installs ASTAP, and sets up FramingAssistant cache.

## Quick Install (copy/paste)

Run the installer directly from this repository:

```bash
curl -fsSL https://raw.githubusercontent.com/acocalypso/pinsx64/main/build-scripts/install-trixie-x64-from-release.sh | sudo bash
```

## Notes

- Target OS: Debian Trixie x64.
- Default release tag used by the installer: `v08052026-8`.
