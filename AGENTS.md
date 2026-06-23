# Repository Guidelines

## Project Structure & Module Organization
This repository combines upstream SonarQube sources with Alauda packaging.

- `source/`: main Gradle multi-project build for SonarQube backend modules, plugins, and the distributable app under `sonar-application/`.
- `chart/`: Helm chart, default values, schema, and templates for Kubernetes and OpenShift deployment.
- `image/`: container build context for the community image and plugin packaging.
- `testing/`: Go-based BDD and e2e suite; feature files live in `testing/features/`, step code in `testing/steps/`, and manifests in `testing/testdata/`.
- `.tekton/`: CI/CD pipeline definitions used for image builds and integration runs.

## Build, Test, and Development Commands
- `cd source && ./gradlew build`: build all Java modules, run tests, and produce the distribution ZIP.
- `cd source && ./gradlew :sonar-application:zip -x test`: build the SonarQube distribution faster when tests are not needed.
- `cd source && ./gradlew test`: run JVM tests without packaging.
- `docker build -f image/community-build/Containerfile --build-arg SONARQUBE_VERSION=26.1-SNAPSHOT -t sonarqube-community-build:<tag> .`: build the local image from the generated ZIP.
- `cd testing && make test`: run chart-based BDD tests against a Kubernetes cluster.
- `cd testing && make test-e2e`: run operator-oriented end-to-end tests.
- `helm template sonarqube ./chart -f testing/testdata/sonarqube.yaml`: quick local validation for chart changes.

JDK 21+ is required for `source/`. Kubernetes tests require a working `kubeconfig`, ingress, and RWX-capable storage.

## Image Scan Workflow
- Codex command routing: when the user asks to run `fix-vulnerabilities`, fix image vulnerabilities, or execute the Claude vulnerability command, read [`.claude/commands/fix-vulnerabilities.md`](.claude/commands/fix-vulnerabilities.md) first and follow it as the authoritative workflow. Report progress at each stage and pause before risky changes such as force-push, fork creation, or `.trivyignore` exemption changes.
- Build and scan locally only; do not push intermediate images. Use explicit tags such as `sonarqube-community-build:fix-20260324-c893a9f9`.
- Scan with the private Trivy DB mirrors and pin the latest date tag published in `registry.alauda.cn:60070/ops/aquasecurity/trivy-db` and `registry.alauda.cn:60070/ops/aquasecurity/trivy-java-db`.
- Example baseline scan:
  `trivy image --image-src docker --scanners vuln --format json --output /tmp/trivy-sonarqube/baseline.json --db-repository registry.alauda.cn:60070/ops/aquasecurity/trivy-db:2026-03-23 --java-db-repository registry.alauda.cn:60070/ops/aquasecurity/trivy-java-db:2026-03-23 --timeout 20m sonarqube-community-build:<tag>`
- After fixes, rescan with `--skip-db-update --skip-java-db-update` and write a new report such as `/tmp/trivy-sonarqube/rescan.json`.
- Prioritize source-level fixes in `source/` and rebuild from source whenever possible. Use image-layer jar replacement in `image/community-build/` only for bundled third-party artifacts that are not rebuilt from source.
- Do not force remediation for findings that have no `FixedVersion` in Trivy output; record them as residual base-image or upstream risk instead.

## Coding Style & Naming Conventions
Follow existing per-language conventions.

- Java/Groovy in `source/`: 2-space indentation, `PascalCase` types, `camelCase` methods and fields.
- Go in `testing/`: format with `gofmt`; keep test entry points in `*_test.go`.
- YAML/Helm: 2-space indentation; keep values keys aligned with `chart/values.schema.json`.

Use descriptive filenames such as `*Test.java`, `*IT.java`, and `*.feature`.

## Testing Guidelines
JVM modules use JUnit, AssertJ, Mockito, and JaCoCo-enabled Gradle test tasks. Add tests close to the changed module. Prefer `*Test` for unit coverage and `*IT` for integration-style cases.

BDD coverage lives in `testing/features/*.feature`. When chart defaults or install flows change, update both the step logic and the matching files in `testing/testdata/`.

## Commit & Pull Request Guidelines
Recent history follows Conventional Commit style: `feat:`, `fix:`, `chore(deps):`. Keep subjects imperative and scoped to one change, for example `fix: align fsGroup defaults for init containers`.

Pull requests should explain the problem, the affected area (`source/`, `chart/`, `image/`, or `testing/`), and the commands you ran. Link the relevant issue when available. For Helm or e2e changes, include rendered manifests, sample values, or test logs.
