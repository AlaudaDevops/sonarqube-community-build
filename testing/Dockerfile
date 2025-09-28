FROM docker-mirrors.alauda.cn/library/golang:1.23.7-bookworm AS builder

WORKDIR /app

COPY . /app

ENV GOPROXY='https://build-nexus.alauda.cn/repository/golang/,direct'
RUN PWGO_VER=$(grep -oE "playwright-go v\S+" /app/testing/go.mod | sed 's/playwright-go //g') \
    && go install github.com/playwright-community/playwright-go/cmd/playwright@${PWGO_VER}
RUN set -eux \
    && mkdir -p /tools/bin && chmod -R 777 /tools/bin \
    && cd /app/testing \
    && CGO_ENABLED=0 go test -c -o /tools/bin/sonarqube-e2e.test ./


FROM build-harbor.alauda.cn/devops/sonarqube-ce-test-base:latest

RUN set -eux \
    && groupadd --gid 65532 nonroot \
    && useradd --uid 65532 --gid 65532 --shell /bin/bash --create-home nonroot

COPY --chown=nonroot:nonroot ./chart /app/chart
COPY --chown=nonroot:nonroot ./testing /app/testing
COPY --chown=nonroot:nonroot --from=builder /tools/bin/sonarqube-e2e.test /app/bin/sonarqube-e2e.test
COPY --chown=nonroot:nonroot --from=builder /go/bin/playwright /app/bin/playwright

RUN /app/bin/playwright install chromium --with-deps

WORKDIR /app/testing

ENV PATH="${PATH}:/app/sonar-scanner/bin:/app/bin"
ENV CI=true
ENV LANG=zh_CN.UTF-8
ENV LC_ALL=zh_CN.UTF-8
ENV TEST_COMMAND="/app/bin/sonarqube-e2e.test"
ENTRYPOINT ["/app/testing/sonarqube-e2e.test"]
