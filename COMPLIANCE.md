# Compliance notes

Build-side work only. Whether SonarQube may be distributed (V2, SSALv1) is
still open; nothing here states a compliance conclusion.

## SSALv1 analyzers are not in the released images

- `source/sonar-application/bundled_plugins.gradle` no longer bundles the 19
  SonarSource language analyzers (list and versions kept in
  `hack/official-plugins-26.1.txt`), so the community-build image ships
  no SSALv1 code.
- The Marketplace / update center keeps the upstream default (on). Anything an
  operator downloads from SonarSource through it is fetched by the operator
  from SonarSource, not provided by us, so it is not blocked.
- `docs/sonarqube-plugin-import-plan.md` describes customers importing the
  official analyzers themselves. Whether that counts as us providing them is a
  legal question, not decided here.

## Delivered alongside: sonarqube-community-branch-plugin

The plugins image (`image/plugin`) ships the AlaudaDevops fork of
sonarqube-community-branch-plugin (LGPL-3.0), loaded by default through
`-javaagent` (`chart/values.yaml`), and its `sonarqube-webapp.zip`, which the
chart's `install-plugins` initContainer unzips over `/opt/sonarqube/web`. It is
part of the product and gets the same brand and license treatment as the main
image.

## SSALv1 analyzers in tests

No image we build carries the SonarSource analyzers. Tests that analyse code import
them after deployment with `testing/scripts/import-official-plugins.sh`, which follows
`docs/sonarqube-plugin-import-plan.md` (download from Maven Central, verify, copy into
the pod, restart). The manifest `hack/official-plugins-26.1.txt` (group:artifact:version[:classifier])
is the single, fixed list; refresh it once per SonarQube baseline upgrade from the upstream
tag's `sonar-application/bundled_plugins.gradle`. Test releases set `plugins.deleteDefaultPlugins=false`; chart
defaults, operator relatedImages and artifacts are untouched.

## SonarQube UI: logo removal and trademark notice

See `image/brand/README.md` for the full inventory and the build gates.

- Every upstream SonarQube mark in both webapps is replaced with the ACP icon
  library's `code-quality` icon at build time, including the inline SVG logo
  components compiled into `js/echoes-*.js`.
- The two-line notice is appended to the global footer on every page
  (`image/brand/alauda-trademark-footer.js`) and to every outgoing email
  (`EmailNotificationChannel`).

## License files

Both images carry `/licenses` (verify with
`docker run --rm --entrypoint sh <image> -c 'ls /licenses; cat /licenses/*'`):

- community-build: `LICENSE` (LGPL-3.0), `NOTICE`, `ELASTICSEARCH-LICENSE.txt`,
  `ELASTICSEARCH-NOTICE.txt`, `README`.
- plugins: `LICENSE` (LGPL-3.0: branch-plugin, its webapp, sonar-findbugs),
  `Apache-2.0.txt` (sonar-auth-oidc), `README`.

## Modified upstream files (LGPL source delivery)

- `source/server/sonar-server-common/src/main/java/org/sonar/server/notification/email/EmailNotificationChannel.java`
- `source/sonar-application/bundled_plugins.gradle`
- `source/build.gradle` (analyzer version entries removed)
- `source/sonar-application/build.gradle` (Elasticsearch SQL CLI jar excluded for every version)
- compiled webapp, changed at build time by `image/brand/apply_brand.py`:
  `js/echoes-*.js`, `index.html`, the 8 image files listed in
  `image/brand/README.md`, source maps removed; `js/lodash-*.js` patched for
  CVE-2025-13465 by `image/community-build/patch-lodash-cve-2025-13465.py`
  (2026-03-26).

## Patched third-party libraries

`com.hazelcast:hazelcast` and `org.mybatis:mybatis` shade dependencies with known
CVEs that upstream has fixed on master but not released. They are taken from
https://github.com/AlaudaDevops/sonarqube-patched-deps (`5.7.0-alauda-1`: shaded
Jackson 2.22.4 / 3.2.3; `3.5.19-alauda-1`: shaded ognl 3.4.16). Both remain
Apache-2.0; that repository holds the upstream tag plus the complete patch set.
Switch back to the upstream releases once they contain the fixes.
