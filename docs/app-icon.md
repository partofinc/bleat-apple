# The app icon (20 Sept 2026)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

A wool-cream block cursor wearing a sheep's ears, on near-black, with a coral
bar where a terminal's cursor sits on its line. One mark that reads two ways: a
face at any size, and a block cursor once you know the name. It ships as a
**layered Icon Composer document**, `App/AppIcon.icon`.

- **The palette is Herdr's, deliberately.** herdr.dev is near-black with a coral
  accent and a monospace, CLI-minimal tone, and — despite the name — carries no
  animal mark at all. So the character is unclaimed and Bleat can take it, while
  sharing the ground and the accent is what makes "Bleat for Herdr" read as a
  companion rather than a clone. Cream `#F4EADF`, coral `#FF6B4A`, ground
  `#1F1E25`.
- **The caret is *inside* the head, and the alternative was rendered rather than
  argued about.** A coral bar floating below the chin reads as a mouth at 220pt
  and as a smudge at 29pt — at that size a detached element is indistinguishable
  from a shadow. Compared at 230/120/60/29, which is the only size that decides
  anything, and re-checked against the document once it existed: **the first
  comparison was of flat stand-ins the script drew itself**, on a different
  ground and with none of the shadow or specular the icon actually has. It held,
  but it was luck rather than method, which is why the sheet is rendered from
  the product now.
- **`Design/icon.swift` is the source; the PNGs are output.** The mark is
  rounded rects and two rotated capsules, so it is generated. `swift
  Design/icon.swift` rewrites the two layers in place and reproduces the
  committed files byte for byte, then renders the contact sheet **from
  `App/AppIcon.icon` via `ictool`** — the icon as it ships, not an impression of
  it. It sits outside `App/`, so the target's synchronized group does not try to
  compile it.
  - **Its paths resolve against `#filePath`, never the working directory.** A
    relative default plus `withIntermediateDirectories` builds a whole
    `App/AppIcon.icon/Assets` tree wherever it is run from, writes the layers
    into it, and prints where they went — a confident success over files it
    never touched, which is the failure this repo keeps a list of.
  - **Every write is checked, `CGImageDestinationFinalize` included.** That call
    is where a full disk or an unwritable file surfaces; dropping its `Bool` is
    the same lie one layer down. A failed directory create reports the path and
    the reason rather than dying on a nil unwrap forty frames later.
  - **The sheet is skipped when the layers were written elsewhere**, since it
    renders the committed document and would otherwise show an icon that does
    not contain them.
- **The eyes are punched through the wool, not filled.** The ground then shows
  through them in every appearance the system derives — including the clear
  ones, where a filled eye would be a flat blob sitting on glass.

## Authoring a `.icon` by hand, since Icon Composer has no CLI for it

Icon Composer is GUI-only and Apple publishes no schema, so the document was
reverse-engineered and every claim below was checked by rendering. Worth keeping
— none of it is findable in the docs.

- **`ictool` renders a document headlessly, and it is not the `ictool` on your
  PATH.** That one is actool-family and answers `Unknown argument
  '--export-image'` in an XML plist. The one that works is
  `/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`.
  Its sibling `icrtool` is the worker and says so — invoked directly it exits 0
  in silence.

  ```sh
  "$IC/ictool" AppIcon.icon --export-image --output-file out.png \
      --platform iOS --rendition Default --width 512 --height 512 --scale 1
  ```

  Renditions are exactly `Default`, `Dark`, `TintedLight`, `TintedDark`,
  `ClearLight`, `ClearDark`; anything else is refused by name.
- **Start from Apple's own template**, which is the only authored document on
  the disk: `Templates/File Templates/MultiPlatform/Resource/Icon Composer
  Icon.xctemplate/___FILEBASENAME___.icon`. It gives the envelope — `fill`,
  `groups`, `supported-platforms` — and renders as-is, which is what makes it a
  usable bisection baseline.
- **The schema, as bisected against `ictool`:**

  | where | keys |
  |---|---|
  | document | `fill`, `groups`, `supported-platforms`, `features`, `languages` |
  | group | `name`, `layers`, `specular` (bool), `shadow`, `translucency`, `refractivity`, `blend-mode`, `lighting`, `position`, `blur-material` (number) |
  | layer | `image-name`, `name`, `hidden`, `glass`, `fill` |

  `shadow` is `{kind, opacity}` with kind one of `neutral`, `layer-color`,
  `none`; `translucency` is `{enabled, value}`; `refractivity` is
  `{enabled, strength, depth}`; `position` is
  `{scale, translation-in-points}`; `lighting` is `individual` or `combined`;
  `blend-mode` is one of `normal`, `multiply`, `overlay`, `soft-light`,
  `hard-light`, `darken`, `lighten`, `plus-lighter`, `plus-darker`.
- **A partial sub-object is a hard decode failure, not a default.** `"shadow":
  {"kind": "neutral"}` fails with *The data couldn't be read because it is
  missing* — every key of the object is required once the object is present.
  Omitting the object entirely is fine. Same for `translucency` and
  `refractivity`. The error names nothing, so bisect.
- **`layers[0]` is the topmost layer**, which is the one thing a render settles
  instantly and reading cannot settle at all.
- **Images live in `Assets/` inside the bundle** and are referenced by file
  name, extension included. **They must carry alpha** — the exact opposite of a
  flat app icon, which is rejected if it has any.
- **At most four visible groups**, which the framework says in its own words.
- **Two groups here, not one.** The caret in its own group gets its own depth
  plane, and depth planes are what the home screen parallaxes. Rendered both:
  the difference is marginal in `Default` and slightly favours two in
  `TintedDark` and `ClearDark`, where the caret is otherwise close to the
  wool's value.

## Wiring it into the target

- **`App/AppIcon.icon` joins the target by existing.** `App` is a
  `PBXFileSystemSynchronizedRootGroup`, so there is no `pbxproj` edit; actool
  receives the `.icon` alongside `Assets.xcassets` and
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` resolves to it.
- **The `AppIcon.appiconset` had to go.** One name, one icon — a catalog entry
  and a document both called `AppIcon` is ambiguous. Nothing is lost: the
  deployment target is iOS 26, and actool derives the whole set, marketing icon
  included, from the document.
- **Verified in the built product rather than assumed.** `xcrun assetutil
  --info Assets.car` lists seven `AppIcon` entries across `UIAppearanceLight`,
  `UIAppearanceDark` and `ISAppearanceTintable`, and `Info.plist` carries
  `CFBundleIconName`. Installed on `rawillk.phone.pro` and `rawillk.pad.mini`.
- **`AccentColor` is still unset, on purpose.** Coral is close enough to the red
  that Stop and Delete are tinted with that promoting it to the app-wide accent
  would blur the one distinction those swipes rely on. Which colour the *app*
  uses is a separate decision from which colour its icon is.
