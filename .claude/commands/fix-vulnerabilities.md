---
description: Build sonarqube + sonarqube-plugins images, scan with Trivy, and fix all severities
---

# SonarQube Image Vulnerability Fix Workflow

Execute step by step. Report progress at each stage and pause for confirmation before risky changes (force-push, fork creation, `.trivyignore` edits).

Pipeline gate today is `severity=High` with `ignore-unfixed=true` (see [.tekton/pipeline/sonar-image-build.yaml:316](.tekton/pipeline/sonar-image-build.yaml:316)). For releases that target zero CVEs, fix every severity that has an upstream fix and document the rest in [`.trivyignore`](.trivyignore).

The repeatable steps below are scripted. **Do not re-implement them inline** — extend the helper scripts in [`hack/`](hack/) when you need new behaviour.

| Helper | Purpose |
|---|---|
| [`hack/sync-trivyignore.sh`](hack/sync-trivyignore.sh) | Pull approved CVE exemptions from Thanos and regenerate `.trivyignore`. |
| [`hack/scan-image.sh`](hack/scan-image.sh) | Wrap `trivy image` with the project's standard flags + `.trivyignore`. |
| [`hack/build-images.sh`](hack/build-images.sh) | Build the SonarQube source artifact and the two container images locally. |
| [`hack/local-smoke-test.sh`](hack/local-smoke-test.sh) | Boot the rebuilt image against a throwaway Postgres, wait for `/api/system/status=UP`, scan logs for known-fatal patterns, then run a full Trivy scan and assert the vulnerability budget is met. |
| [`image/community-build/jar-tools.sh`](image/community-build/jar-tools.sh) | `replace` / `overlay` / `overlay-from-maven` subcommands used inside the Containerfile. |
| [`image/community-build/patch-lodash-cve-2025-13465.py`](image/community-build/patch-lodash-cve-2025-13465.py) | In-place lodash patcher. |

## Step 0: Prep & sync exemptions

Copy `.env.example` to `.env` once per checkout and fill in the Thanos plugin name (the API silently returns `{"data":[]}` for any string, so confirm the value with the platform team before trusting an empty result).

```bash
cp .env.example .env
$EDITOR .env

./hack/sync-trivyignore.sh --dry-run            # preview
./hack/sync-trivyignore.sh                      # write .trivyignore
git diff -- .trivyignore                        # review and commit if changed
```

If Thanos is unreachable or returns an unexpectedly empty list, **stop**. Do not continue with a stale `.trivyignore` — that risks silencing a regression.

## Step 1: Branch out

Always work on a fresh branch off the active release branch. Never edit the release branch directly.

```bash
git fetch upstream alauda-2026.1.0
git checkout -b fix/image-vulnerabilities upstream/alauda-2026.1.0
```

## Step 2: Scan the current production images

Image tags live in [chart/values.yaml](chart/values.yaml). With `HARBOR_REGISTRY_HOST` set in `.env`, the scanner picks up the active tags itself when no `--image` flag is given:

```bash
./hack/scan-image.sh --summary-only                                    # quick header counts
./hack/scan-image.sh --format json --out /tmp/main.json \
    --image "${HARBOR_REGISTRY_HOST}/devops/sonarqube:$(yq '.global.images.app.tag' chart/values.yaml)"
./hack/scan-image.sh --format json --out /tmp/plugins.json \
    --image "${HARBOR_REGISTRY_HOST}/devops/sonarqube-plugins:$(yq '.global.images.app.tag' chart/values.yaml)"
```

Pretty-print to drive Step 3:

```bash
jq -r '.Results[]?.Vulnerabilities[]? |
  "\(.Severity)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion//"-")\t\(.VulnerabilityID)\t\(.PkgPath//"-"|split("/")|.[-1])"' \
  /tmp/main.json | sort | column -t -s $'\t'
```

If the primary registry is unreachable, point `HARBOR_REGISTRY_HOST` to the internal mirror you have access to.

## Step 3: Categorize each CVE and pick a strategy

Use this decision table **in priority order** — always pick the earliest option that actually fixes the CVE.

| Source of the vulnerable artifact | Strategy | Where to change |
|---|---|---|
| Ubuntu noble apt package | Pin a fixed version inline | [image/community-build/Containerfile](image/community-build/Containerfile) — extend the `apt-get install` block. |
| Alpine apk package (plugin image) | `apk upgrade --no-cache <pkg>...` | [image/plugin/Containerfile](image/plugin/Containerfile) — add an `apk upgrade` line before `apk add`. |
| Maven dep that flows through `source/build.gradle` resolution | Bump in the dependency BOM or add an explicit override | [source/build.gradle](source/build.gradle) — typical edits: `jackson-bom`, `mssql-jdbc`, `sonar-{python,text}-plugin`, `com.sun.mail:jakarta.mail` (override transitive). |
| Bundled Elasticsearch — standalone jar in `elasticsearch/modules/<m>/<artifact>-<ver>.jar` | `jar-tools.sh replace` | [image/community-build/Containerfile](image/community-build/Containerfile) — extend the existing `jar-tools.sh` RUN block. |
| Bundled ES — fat-jar shaded dep (`elasticsearch-x-content`, `sonar-application`, `sonar-python-plugin`) | `jar-tools.sh overlay-from-maven` | Same Containerfile. Pass the `target-prefix` arg for IMPL-JARS layout (e.g. `IMPL-JARS/x-content/jackson-core-2.17.2.jar`). |
| Bundled ES — entire jar is a renamed upstream artifact (`elasticsearch-log4j-X.jar` is just `log4j-core` renamed) | Direct `curl -fsSL -o $TARGET <maven_url>` | Same Containerfile, after the `jar-tools.sh` calls. |
| Bundled ES — fat-jar agent that shades everything (`elastic-apm-agent-java8-X.jar`) | Direct `curl` overwrite with the latest patched agent jar | Same Containerfile. |
| Bundled SonarQube/SonarSource plugin in `lib/extensions/sonar-X-plugin-Y.jar` | First, check if a newer plugin release ships the fix (download the candidate jar and inspect its `META-INF/maven/.../jackson-core/pom.properties`); if yes, bump the dep version in `source/build.gradle`. If not, `overlay-from-maven` on the plugin jar. | [source/build.gradle](source/build.gradle) for the bump, or Containerfile for overlay. |
| 3rd-party plugin we already fork (e.g. `sonarqube-community-branch-plugin`) | Switch the download URL in [image/plugin/plugins.txt](image/plugin/plugins.txt) to the AlaudaDevops fork build published in the internal Maven repo (host configured via `${NEXUS_HOST}` in your environment). | Search via Nexus REST: `GET https://${NEXUS_HOST}/service/rest/v1/search?repository=<repo>&name=<artifact>` to find the published path. |
| 3rd-party plugin with no upstream fix and no existing fork | Fork to `AlaudaDevops/<repo>`, branch `alauda-<version>`, bump the offending dep, push and let the existing Tekton pipeline (e.g. `.tekton/build.yaml` in the fork) publish the patched jar to the internal Maven repo. Then update `plugins.txt` as above. Commit footer must include `Upstream-PR:` and `Cherry-picked-from:` if applicable. | New AlaudaDevops fork. |
| No fix exists anywhere (latest upstream still vulnerable, or Trivy false positive on version parsing) | Submit an exemption to Thanos and re-run `./hack/sync-trivyignore.sh` — never edit `.trivyignore` by hand. | Thanos. |

### Known false positives / patterns

- **`mssql-jdbc-X.jre11.jar`**: Trivy strips the `.jre11` qualifier and reports `X` as installed. The fixed-version list from Microsoft also uses `X.jre11`, so Trivy never matches them. Pin the highest available `X.jre11` in `source/build.gradle` and add the CVE to Thanos.
- **`com.hazelcast:hazelcast` shaded jackson-core**: Hazelcast keeps the upstream `META-INF/maven/com.fasterxml.jackson.core/jackson-core/pom.properties` even though classes are relocated under `com/hazelcast/shaded/...`. Pure metadata false positive — Thanos exemption is the right answer when no Hazelcast bump is available.
- **SonarSource plugin shaded jackson-core**: The latest plugin release sometimes still ships the previous patch (e.g. `jackson-core 2.21.0` while the fix lands in 2.21.1+). `overlay-from-maven` the fix into the plugin jar, otherwise Thanos exemption + recheck next cycle.

## Step 4: Apply the fixes

Edit the files identified in Step 3. Helpful patterns:

```dockerfile
# OS pin (main image, Ubuntu)
apt-get --no-install-recommends -y install \
    curl=8.5.0-2ubuntu10.8 \
    libssl3t64=3.0.13-0ubuntu3.9 \
    ...

# OS upgrade (plugin image, Alpine)
apk upgrade --no-cache libcrypto3 libssl3 musl musl-utils zlib

# Standalone ES jar replace
/tmp/jar-tools.sh replace "io.netty" "netty-codec-http" 4.1.130.Final 4.1.132.Final \
    "${SONARQUBE_HOME}/elasticsearch/modules/x-pack-inference"

# IMPL-JARS overlay (jackson inside elasticsearch-x-content)
/tmp/jar-tools.sh overlay-from-maven "com.fasterxml.jackson.core" "jackson-core" 2.18.6 \
    "${SONARQUBE_HOME}/elasticsearch/lib/elasticsearch-x-content-8.19.13.jar" \
    "IMPL-JARS/x-content/jackson-core-2.17.2.jar"

# Renamed jar — direct curl overwrite
ES_LOG4J_FILE=$(ls ${SONARQUBE_HOME}/elasticsearch/lib/elasticsearch-log4j-*.jar)
curl -fsSL -o "$ES_LOG4J_FILE" \
    "https://repo1.maven.org/maven2/org/apache/logging/log4j/log4j-core/${LOG4J_VERSION}/log4j-core-${LOG4J_VERSION}.jar"
```

Force a transitive Maven dep by declaring it in the BOM block in `source/build.gradle`:

```groovy
dependency 'com.sun.mail:jakarta.mail:2.0.2'   // forces shaded sonar-application past CVE-2025-7962
```

## Step 5: Build locally

```bash
./hack/build-images.sh --target both --tag local-fix         # both images, fresh source build
./hack/build-images.sh --target main --skip-source           # only re-run docker, reuse existing zip
./hack/build-images.sh --target main --build-number 118079   # override the suffix used in the Containerfile COPY
```

The script:
- derives `${SONARQUBE_VERSION}` from `source/gradle.properties` + `--build-number`;
- runs the gradle wrapper inside a clean `env -i` (sidesteps the macOS `gvm` shell-init issue);
- skips the gradle stage when the expected zip already exists (set `FORCE_SOURCE=true` to override).

## Step 6: Re-scan and verify zero residuals

```bash
./hack/scan-image.sh --image sonarqube-main:local-fix \
                     --image sonarqube-plugins:local-fix \
                     --summary-only

./hack/scan-image.sh --image sonarqube-main:local-fix --format json --out /tmp/main-fixed.json
jq -r '.Results[]?.Vulnerabilities[]? |
  "\(.Severity)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion//"-")\t\(.VulnerabilityID)\t\(.PkgPath//"-"|split("/")|.[-1])"' \
  /tmp/main-fixed.json | sort | column -t -s $'\t'
```

Trivy auto-loads `.trivyignore` from the working directory, so run the script from the repo root if you rely on it.

If anything is still flagged: route it back through Step 3's table. Don't cheat by silencing real CVEs in `.trivyignore` — submit an exemption to Thanos and let `sync-trivyignore.sh` regenerate the file.

## Step 7: Smoke test (required before PR)

This step is non-negotiable. JAR replacements routinely break Elasticsearch / Web / CE startup with `NoSuchMethodError`, `NoClassDefFoundError`, or `IllegalArgumentException: Invalid Configuration class` (e.g. when only `log4j-core` is bumped while `log4j-api` / `log4j-slf4j2-impl` stay on the old version). Trivy alone will *not* catch these regressions — only running the image will.

`hack/local-smoke-test.sh` boots SonarQube against a throwaway Postgres, polls `/api/system/status` until `UP`, scans the logs for the known-fatal patterns above, **then re-runs `hack/scan-image.sh` against both images and asserts the vulnerability budget is met**. The default budget is `0` for every severity.

```bash
./hack/local-smoke-test.sh \
    --main-image    sonarqube-main:local-fix \
    --plugin-image  sonarqube-plugins:local-fix \
    --max-vulns     0 \
    --timeout       420
```

Useful flags:

- `--max-severity HIGH,CRITICAL` — only count those severities towards the budget (matches the default Tekton gate).
- `--keep` — leave the Postgres + SonarQube containers running so you can poke around (`docker logs sonar-smoke` / `psql ...`). Run `docker rm -f sonar-smoke sonar-smoke-pg && docker network rm sonar-smoke-net` when you're done.
- `PLATFORM=linux/amd64 ./hack/local-smoke-test.sh ...` — required on Apple Silicon. The public Elasticsearch tarball fetched by the source build only ships x86_64 native libs, so you must `docker buildx build --platform linux/amd64 ...` first and then ask the smoke script to start the container under Rosetta.

Failure modes the smoke script catches that Trivy misses:

| Symptom in logs | Most likely cause |
|---|---|
| `NoSuchMethodError: ...LoaderUtil.newCheckedInstanceOfProperty` | log4j-core was upgraded but log4j-api / log4j-slf4j2-impl were left behind. |
| `NoClassDefFoundError` referencing a `com.fasterxml.jackson.*` class | Plugin / fat-jar overlay removed classes the host expected. |
| `UnsatisfiedLinkError: ...elasticsearch/lib/platform/linux-aarch64/...` | Wrong architecture — rebuild with the right `--platform`. |
| `Process[Web Server] is stopped` immediately after `Process[es] is up` plus a `JdbcSQLSyntaxErrorException` | The script was invoked against H2 — switch to Postgres (the script does so by default). |

Do not move on to Step 8 until the smoke test ends with `==> PASS` AND the Trivy budget assertion passes. If either fails, route the offender back through Step 3.

## Step 8: Commit and PR

```bash
git add image/community-build/Containerfile image/plugin/Containerfile \
        image/plugin/plugins.txt source/build.gradle source/gradle.properties \
        source/sonar-application/build.gradle .trivyignore

git commit -m "fix: ..."
git push -u origin fix/image-vulnerabilities

gh pr create --repo AlaudaDevops/sonarqube-community-build \
    --base alauda-2026.1.0 --head <user>:fix/image-vulnerabilities \
    --title "fix: patch image vulnerabilities flagged by Trivy" \
    --body-file <(...)
```

PR body should include:
- before/after Trivy counts per image,
- the per-fix mapping (CVE → strategy → file),
- explicit notes for any new `.trivyignore` entry (with the matching Thanos exemption link),
- a test plan (`./hack/scan-image.sh` ✓, CI scan, smoke test).

If upstream `alauda-2026.1.0` advances while the PR is open, prefer `git reset --hard upstream/alauda-2026.1.0 && re-apply your delta` over a many-conflict rebase — vuln-fix PRs touch the same Containerfile that other vuln-fix PRs are also rewriting.

## Key files

| File | Purpose |
|------|---------|
| [image/community-build/Containerfile](image/community-build/Containerfile) | Main image: OS pins + jar-tools.sh calls + lodash patch + sniff-tool removal. |
| [image/community-build/jar-tools.sh](image/community-build/jar-tools.sh) | `replace` / `overlay` / `overlay-from-maven` subcommands. Reuse — do not re-invent. |
| [image/community-build/patch-lodash-cve-2025-13465.py](image/community-build/patch-lodash-cve-2025-13465.py) | In-place lodash patcher. |
| [image/plugin/Containerfile](image/plugin/Containerfile) | Plugin image: `apk upgrade` + downloads jars listed in `plugins.txt`. |
| [image/plugin/plugins.txt](image/plugin/plugins.txt) | Plugin download URLs. Switch to the internal Nexus (`${NEXUS_HOST}`) for AlaudaDevops fork builds. |
| [source/build.gradle](source/build.gradle) | Top-level dependency BOM: `jackson-bom`, `mssql-jdbc`, `sonar-*-plugin`, `com.sun.mail:jakarta.mail`. |
| [source/gradle.properties](source/gradle.properties) | `elasticSearchServerVersion` lives here. |
| [source/sonar-application/build.gradle](source/sonar-application/build.gradle) | ES tarball repackaging — exclude lists for unwanted ES binaries. |
| [.trivyignore](.trivyignore) | Documented residuals only — synced from Thanos via `hack/sync-trivyignore.sh`. |
| [.tekton/pipeline/sonar-image-build.yaml](.tekton/pipeline/sonar-image-build.yaml) | The pipeline that actually scans on PR (Trivy task, gate config). |
| [.env.example](.env.example) | Template for `.env`; documents `THANOS_API_HOST`, `THANOS_PLUGIN`, `THANOS_BRANCH`, `HARBOR_REGISTRY_HOST`. |
