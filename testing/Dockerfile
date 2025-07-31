FROM docker-mirrors.alauda.cn/library/golang:1.23.7-bookworm AS builder

WORKDIR /app

COPY . /app

ENV GOPROXY='https://build-nexus.alauda.cn/repository/golang/,direct'
RUN set -eux; \
    mkdir -p /tools/bin && chmod -R 777 /tools/bin; \
    cd /app/testing && \
    CGO_ENABLED=0 go test -c -o /tools/bin/sonarqube-e2e.test ./


FROM docker-mirrors.alauda.cn/library/openjdk:17-jdk-slim

WORKDIR /app

ARG SONAR_SCANNER_VERSION=7.1.0.4889
RUN set -ex; \
    apt-get update; \
    apt-get install -y nodejs unzip jq maven git curl ca-certificates tzdata bash locales make wget git jq; \
    curl -O https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip; \
    unzip sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip; \
    mv sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64 sonar-scanner; \
    rm sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip; \
    rm -rf /var/lib/apt/lists/*

ARG YQ_VERSION=4.25.2
ARG KUBECTL_VERSION=1.28.2
ARG HELM_VERSION=3.12.3

RUN set -eux; \
    if [ "$(arch)" = "arm64" ] || [ "$(arch)" = "aarch64" ]; then \
    export ARCH="arm64"; \
    export ARCH_ALIAS="arm64"; \
    else \
    export ARCH="amd64"; \
    export ARCH_ALIAS="x86_64"; \
    fi; \
    mkdir -p tmp; \
    mkdir -p bin; \
    curl -sfL https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH} -o ./bin/yq && \
    curl -sfL https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl -o ./bin/kubectl && \
    curl -sfL https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz | tar xzf - -C tmp 2>&1 && mv tmp/linux-${ARCH}/helm ./bin && \
    chmod +x ./bin/* && \
    rm -rf tmp && \
    ./bin/yq --version && \
    ./bin/kubectl version --client && \
    ./bin/helm version && \
    jq --version

# Create user with ID 65532 for security purposes
RUN groupadd --gid 65532 nonroot && \
useradd --uid 65532 --gid 65532 --shell /bin/bash --create-home nonroot

COPY --chown=nonroot:nonroot ./chart /app/chart
COPY --chown=nonroot:nonroot ./testing /app/testing
COPY --chown=nonroot:nonroot --from=builder /tools/bin/sonarqube-e2e.test /app/bin/sonarqube-e2e.test

USER 65532

WORKDIR /app/testing

ENV PATH="${PATH}:/app/sonar-scanner/bin:/app/bin"
ENV CI=true
ENV LANG=zh_CN.UTF-8
ENV LC_ALL=zh_CN.UTF-8
ENV TEST_COMMAND="/app/bin/sonarqube-e2e.test"
ENTRYPOINT ["/app/testing/sonarqube-e2e.test"]
