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

> **ES version first.** Before writing any `jar-tools.sh` line for a CVE inside the Elasticsearch bundle, check whether bumping `elasticSearchServerVersion` in `source/gradle.properties` already ships the fix. ES releases frequently upgrade netty, log4j, bouncycastle, jackson, etc. A version bump is always cleaner than accumulating jar-replacement lines that silently break when the next ES bump changes file names. Only fall back to `replace`/`overlay-from-maven` for CVEs that survive the latest available ES release. After bumping, run `FORCE_SOURCE=true ./hack/build-images.sh` so gradle actually fetches the new ES tarball (the existing zip is otherwise reused).

Use this decision table **in priority order** — always pick the earliest option that actually fixes the CVE.

| Source of the vulnerable artifact | Strategy | Where to change |
|---|---|---|
| Ubuntu noble apt package | Pin a fixed version inline | [image/community-build/Containerfile](image/community-build/Containerfile) — extend the `apt-get install` block. |
| Alpine apk package (plugin image) | `apk upgrade --no-cache <pkg>...` | [image/plugin/Containerfile](image/plugin/Containerfile) — add an `apk upgrade` line before `apk add`. |
| Maven dep that flows through `source/build.gradle` resolution | Bump in the dependency BOM or add an explicit override | [source/build.gradle](source/build.gradle) — typical edits: `jackson-bom`, `mssql-jdbc`, `sonar-{python,text}-plugin`, `com.sun.mail:jakarta.mail` (override transitive). |
| **Bundled Elasticsearch artifact (any kind)** | **Bump `elasticSearchServerVersion` first** — re-scan after the rebuild. Only add `jar-tools.sh` lines for CVEs that survive the new ES version. | `source/gradle.properties` → rebuild with `FORCE_SOURCE=true`. |
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

## Step 7: Smoke test (required before PR — no exceptions)

**This step is a hard gate. Do not commit or open a PR until the smoke test passes.** A clean Trivy scan is necessary but not sufficient — JAR replacements routinely break Elasticsearch / Web / CE startup with `NoSuchMethodError`, `NoClassDefFoundError`, or `IllegalArgumentException: Invalid Configuration class` (e.g. when only `log4j-core` is bumped while `log4j-api` / `log4j-slf4j2-impl` stay on the old version). And even when the image *boots*, the analyser side may have lost the ability to actually scan code (broken plugin classpath, removed scanner endpoints). Trivy alone will *not* catch either class of regression — only running the image and feeding it real code will.

`hack/local-smoke-test.sh` is the closed-loop runner that does all of it:

1. boots SonarQube against a throwaway Postgres on a private docker network,
2. waits for `/api/system/status == UP`,
3. greps the container logs for known-fatal patterns,
4. runs `hack/scan-image.sh` against both images and asserts the vulnerability budget,
5. **provisions an admin token, runs the official `sonarsource/sonar-scanner-cli` image against [`testing/repos/python-example`](testing/repos/python-example/), waits for the compute engine task to finish, and asserts `ncloc > 0` plus analysis status `SUCCESS`.**

```bash
./hack/local-smoke-test.sh \
    --main-image    sonarqube-main:local-fix \
    --plugin-image  sonarqube-plugins:local-fix \
    --max-vulns     0 \
    --timeout       420
```

Useful flags:

- `--scan-project-dir testing/repos/maven-simple` — switch to a different fixture under `testing/repos/`. Defaults to `python-example`, which doesn't need a JDK or Maven.
- `--scan-project-key custom-key` — override the project key sent to SonarQube; defaults to `smoke-<basename>`.
- `--scanner-image sonarsource/sonar-scanner-cli:11` — pin the scanner CLI version if needed.
- `--skip-scan` — only do steps 1-4 (boot + log scan + Trivy budget) when you're certain Step 5 isn't useful (e.g. you already triggered an analysis manually). Default is to always run Step 5.
- `--max-severity HIGH,CRITICAL` — restrict the Trivy budget to those severities (matches the default Tekton gate).
- `--keep` — leave the Postgres + SonarQube containers running for manual poking. Clean up later with `docker rm -f sonar-smoke sonar-smoke-pg && docker network rm sonar-smoke-net`.
- `PLATFORM=linux/amd64 ./hack/local-smoke-test.sh ...` — required on Apple Silicon. The public Elasticsearch tarball fetched by the source build only ships x86_64 native libs, so you must `docker build --platform linux/amd64 ...` first and then ask the smoke script to start everything under Rosetta. Note: macOS Docker Desktop's LinuxKit kernel is built without `CONFIG_SECCOMP`, which ES refuses to start without — full e2e on Apple Silicon currently only works in CI on a real Linux runner.

### Apple Silicon fallback: cluster-based smoke validation

ES 8.x unconditionally calls `tryInstallExecSandbox` during startup — it throws `UnsupportedOperationException: seccomp unavailable: CONFIG_SECCOMP not compiled into kernel` if the kernel lacks SECCOMP support. OrbStack's x86_64 Rosetta emulation layer does not expose CONFIG_SECCOMP, so the local smoke test **cannot run on Apple Silicon regardless of flags or env vars** (`-Des.bootstrap.system_call_filter=false` is accepted by SonarQube's JVM args but ignored by ES 8.x which checks SECCOMP before bootstrap gates). You cannot override `-Des.enforce.bootstrap.checks=true` either — SonarQube rejects it as a mandatory-option conflict.

When the local smoke test is blocked by this limitation, ask the user to provide a test environment:

> "Local smoke test cannot run on Apple Silicon (ES requires CONFIG_SECCOMP which OrbStack's Rosetta kernel does not provide). Please provide:
> 1. A registry I can push the image to (e.g. `<registry>/<project>/sonarqube-main:<tag>`)
> 2. A kubeconfig / cluster where there is an existing SonarQube deployment to update, or a namespace where I can deploy one
>
> I will push the linux/amd64 image, roll it out to the cluster, and confirm the pod reaches Running state and SonarQube reports status UP."

Once the user supplies the environment, the steps are:

```bash
# 1. Rebuild as linux/amd64 for the x86_64 cluster
BUILD_PLATFORM=linux/amd64 ./hack/build-images.sh --target main --skip-source --tag local-fix

# 2. Push to the registry provided by the user
docker tag sonarqube-main:local-fix <registry>/<project>/sonarqube-main:<tag>
docker push <registry>/<project>/sonarqube-main:<tag>

# 3. Roll out (update the image in the existing deployment, or deploy fresh)
kubectl set image deployment/<name> <container>=<registry>/<project>/sonarqube-main:<tag> -n <namespace>
kubectl rollout status deployment/<name> -n <namespace> --timeout=300s

# 4. Verify manually:
#    - SonarQube UI loads and status is UP
#    - Run a project analysis and confirm it completes successfully
```

The cluster deployment is NOT a full substitute for `local-smoke-test.sh` (no automated analysis assertion or log pattern check), but it **proves the image boots and ES starts** on a real Linux x86_64 kernel. Mark the PR with `smoke-test: cluster` and note that the CI pipeline's smoke step will provide the full automated validation.

Failure modes the smoke script catches that Trivy misses:

| Symptom | Most likely cause |
|---|---|
| `NoSuchMethodError: ...LoaderUtil.newCheckedInstanceOfProperty` in container logs | log4j-core was upgraded but log4j-api / log4j-slf4j2-impl were left behind. |
| `NoClassDefFoundError` referencing a `com.fasterxml.jackson.*` class | Plugin / fat-jar overlay removed classes the host expected. |
| `UnsatisfiedLinkError: ...elasticsearch/lib/platform/linux-aarch64/...` | Wrong architecture — rebuild with the right `--platform`. |
| `Process[Web Server] is stopped` right after `Process[es] is up` + `JdbcSQLSyntaxErrorException` | The script was launched against H2 — switch to Postgres (the script does so by default). |
| `compute engine: FAILED` in Step 5 | Plugin classpath broken — analyser cannot register a sensor for the language under test. |
| `Expected ncloc > 0` in Step 5 | Source files were never visible to the scanner. Check the volume mount and `sonar-project.properties` in the test project. |
| `seccomp unavailable: CONFIG_SECCOMP not compiled into kernel` | Running on Apple Silicon under OrbStack Rosetta — use the cluster fallback above. |

Do not move on to Step 8 until **either** the smoke test ends with `==> PASS — ... SonarQube analysis succeeded (ncloc=...)` **or** the cluster deployment is confirmed UP and a manual analysis completes successfully. If anything fails, route the offender back through Step 3.

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
