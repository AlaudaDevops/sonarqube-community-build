# Brand overlay for the SonarQube webapps

SonarQube is shipped as a modified build, so every upstream SonarQube /
SonarSource mark in the delivered UI must be removed, and the tool's own pages
must carry the trademark notice. Both are baked in at image build time; nothing
depends on the customer configuring anything.

Two webapps are shipped and both go through `apply_brand.py`:

| Webapp | Where | Who serves it |
|---|---|---|
| `org.sonarsource.sonarqube:webapp-assets` (LGPL-3.0) | `/opt/sonarqube/web` in `image/community-build` | the server, when `plugins.useDefaultPluginsPackage=false` |
| `sonarqube-webapp.zip` of sonarqube-community-branch-plugin (LGPL-3.0) | `/tmp/sonarqube-webapp.zip` in `image/plugin` | the chart's `install-plugins` initContainer unzips it over `/opt/sonarqube/web` (the chart default) |

## Files

- `icon/acp-icon-code-quality.svg` — source icon, taken verbatim from the ACP
  component icon library (`ACP-组件图标库`, entry `code-quality`, mapped there to
  SonarQube / Alauda Toolchain Code Quality E1).
- `assets/` — generated from the icon by `hack/apply-sonar-brand.sh`
  (rsvg-convert + python3 stdlib). Root `width`/`height` are stripped so the SVG
  scales when used as a CSS-sized image.
- `apply_brand.py` — build-time step, stdlib only. Run as
  `python3 apply_brand.py <webapp-dir>`.
- `alauda-trademark-footer.js` — appends the two-line notice to SonarQube's own
  footer disclaimer. It has to be an external same-origin script: SonarQube sends
  a strict `script-src 'self' 'sha256-…'` CSP, so inline scripts are refused.

## Upstream marks and where they go

Inventory taken from webapp-assets 2025.6.0.36040 and
sonarqube-community-branch-plugin 26.1.0 (same asset set in both).

| Upstream | Shown at | Replaced with |
|---|---|---|
| `js/echoes-*.js` inline SVG components `logo.sonar`, `logo.sonarqube.community`, `logo.sonarqube.server`, `logo.sonarqube.cloud`, `logo.sonarqube.ide` | top bar (`sonar-qube-product-logo`), login page, About, every other in-app logo | component rewritten at build time to render `images/logo.svg` |
| `images/sonar-logo-white.svg` | login page marketing panel, small logo | `assets/logo.svg` |
| `images/sonar-whale-white.svg` | login page marketing panel, background | `assets/logo.svg` |
| `images/logo.svg` | default logo slot | `assets/logo.svg` |
| `images/embed-doc/sq-icon.svg` | embedded documentation | `assets/logo.svg` |
| `images/sonar-logo-horizontal.png` (98×26) | horizontal logo slots | `assets/logo-horizontal.png` |
| `favicon.ico` (16/32/48) | browser tab | `assets/favicon.ico` |
| `apple-touch-icon.png` (180×180) | iOS home screen | `assets/apple-touch-icon.png` |
| `mstile-512x512.png` | Windows tile | `assets/mstile-512x512.png` |
| any inline `<svg>` painted with the `logos-colors-brand` token: SonarQube for IDE promotion pictogram (`promotion-notification`), SonarLint quick-fix icon (`sonar-lint-logo`), IDE-connection illustrations (`SonarLintConnection-*.js`) | issue page, promotion pop-up, `/sonarlint/auth` | content replaced with `images/logo.svg`, attributes and viewBox kept |
| `js/**/*.map` | devtools only, but they embed the original logo sources | deleted |

Kept on purpose (not SonarSource marks): third-party ALM / CI logos
(`images/alm/*`, `images/tutorials/*`, identifying the integration, not our
product, same rule as the artifact-type icons decided on 10-10), the SAML
illustration, UI glyphs and the mode-tour / issue-sandbox illustrations.

Checked and nothing to do: the server-rendered SAML pages
(`validation-redirection.html`, `samlAuthResult.html`) mention SonarQube only in
an invisible `<meta name="application-name">`; no loading-page image exists
(the loading screen is a CSS spinner).

## Gates

`apply_brand.py` fails the image build when:

1. an image file in the webapp is neither replaced nor in the reviewed keep
   list (so an upstream bump that adds a logo stops the build), or a replaced
   file has moved;
2. any `id:"logo.*"` component, the `logos-colors-brand` token, original logo
   path data, or the whale path survives in any JS / CSS / HTML / SVG file;
3. replaced bytes do not match `assets/`, or the footer script is not wired.

## Changing the icon

```
hack/apply-sonar-brand.sh [path/to/square-icon.svg]
```

then commit `image/brand/assets/`. Filenames follow upstream, so no
referencing code changes.
