# Contributing

Thanks for helping improve Cruise Control. Please keep changes focused, describe how you checked them, and avoid including private task text, credentials, or unredacted logs.

## Set up and test

Cruise Control requires macOS 14 or later. Install Xcode Command Line Tools with `xcode-select --install`, clone the repository, and run the checks relevant to your change:

```sh
git clone https://github.com/ilovespectra/CruiseControl.git
cd CruiseControl
swift test
```

For app changes, build the app bundle with `./scripts/build-app.sh`. It writes `build/Cruise Control.app` without installing it. Add `--install` only when you intend to replace the installed app and register its login agent.

For website or release-link changes, install Node.js and run:

```sh
node --test Tests/site/*.test.mjs
```

The landing page and documentation share `site/brand.css` and `site/theme.js`. Keep all four accents readable in light and dark appearance, retain System appearance and reduced-motion support, and do not use theme color as a substitute for a mode or safety label. Website artwork is cropped from the supplied originals in `marketing/logos/`. Preserve the gauge originals and current Rest sheet in `marketing/logos/all/generated-image-c7ed7adea134.png`; the per-color `rest.png` crops replace the obsolete Rest artwork. Exclude comparison labels from all website crops.

Open a GitHub issue for bugs or feature proposals, or submit a pull request with a concise summary and test results. Update the [user documentation](https://cruise.kolektivkrog.si/docs.html) when behavior or safety guidance changes. Public release creation is maintainer-only; see [Publisher and release safeguards](DEVELOPER_CONSOLE.md).
