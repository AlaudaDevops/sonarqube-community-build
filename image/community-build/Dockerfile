# source: https://github.com/SonarSource/sonarqube/blob/170bd61e5e75fb3668dd31dc71570f5e40a800fd/.cirrus/Dockerfile#L1
# renovate: datasource=docker depName=eclipse-temurin
ARG JDK_IMAGE_VERSION=17.0.16_8-jdk-jammy
# renovate: datasource=docker depName=eclipse-temurin
ARG JRE_IMAGE_VERSION=17.0.16_8-jre-jammy
FROM docker-mirrors.alauda.cn/library/eclipse-temurin:${JDK_IMAGE_VERSION} as builder

RUN mkdir -p /usr/share/man/man1 \
  && apt-get update \
  && apt-get -y install --no-install-recommends \
    lsb-release \
    ca-certificates \
    curl \
    gnupg \
    unzip \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN set -o errexit -o nounset \
  && groupadd --system --gid 1000 sonarsource \
  && useradd --system --gid sonarsource --uid 1000 --shell /bin/bash --create-home sonarsource

ARG SONARQUBE_VERSION=25.1.0.102122
COPY --chown=sonarsource:sonarsource source/sonar-application/build/distributions/sonar-application-${SONARQUBE_VERSION}.zip /home/sonarsource
RUN mkdir -p /data/patches \
  && unzip /home/sonarsource/sonar-application-${SONARQUBE_VERSION}.zip -d /data \
  && mv /data/sonarqube-${SONARQUBE_VERSION} /data/sonarqube \
  && ls -al /data/sonarqube

RUN set -eux \
  && rm -rf /data/sonarqube/bin/* \
  && chmod -R 550 /data/sonarqube \
  && chmod -R 770 /data/sonarqube/data /data/sonarqube/extensions /data/sonarqube/logs /data/sonarqube/temp

COPY --chown=sonarsource:sonarsource image/community-build/replace-jar.sh /tmp/replace-jar.sh

# renovate: datasource=maven depName=netty-codec lookupName=io.netty:netty-codec
ARG NETTY_VERSION=4.1.128.Final
# renovate: datasource=maven depName=bc-fips lookupName=org.bouncycastle:bc-fips
ARG BC_VERSION=1.0.2.6
# renovate: datasource=maven depName=bcpkix-jdk18on lookupName=org.bouncycastle:bcpkix-jdk18on
ARG BCPKIX_VERSION=1.79
RUN chmod +x /tmp/replace-jar.sh && \
    /tmp/replace-jar.sh io.netty netty-codec 4.1.118.Final ${NETTY_VERSION} /data/sonarqube/elasticsearch && \
    /tmp/replace-jar.sh io.netty netty-codec-http 4.1.118.Final ${NETTY_VERSION} /data/sonarqube/elasticsearch && \
    /tmp/replace-jar.sh io.netty netty-codec-http2 4.1.118.Final ${NETTY_VERSION} /data/sonarqube/elasticsearch && \
    /tmp/replace-jar.sh org.bouncycastle bc-fips 1.0.2.5 ${BC_VERSION} /data/sonarqube/elasticsearch && \
    /tmp/replace-jar.sh org.bouncycastle bcpkix-jdk18on 1.78.1 ${BCPKIX_VERSION} /data/sonarqube/elasticsearch

FROM docker-mirrors.alauda.cn/library/eclipse-temurin:${JRE_IMAGE_VERSION}

LABEL io.k8s.description="SonarQube Community Build is a self-managed, automatic code review tool that systematically helps you deliver Clean Code."
LABEL io.openshift.min-cpu=400m
LABEL io.openshift.min-memory=2048M
LABEL io.openshift.non-scalable=true
LABEL io.openshift.tags=sonarqube,static-code-analysis,code-quality,clean-code
LABEL org.opencontainers.image.url=https://github.com/SonarSource/docker-sonarqube

ENV LANG='en_US.UTF-8' \
    LANGUAGE='en_US:en' \
    LC_ALL='en_US.UTF-8'

ARG SONARQUBE_VERSION=25.1.0.102122

# SonarQube setup
ENV DOCKER_RUNNING="true" \
    JAVA_HOME='/opt/java/openjdk' \
    SONARQUBE_HOME=/opt/sonarqube \
    SONAR_VERSION="${SONARQUBE_VERSION}" \
    SQ_DATA_DIR="/opt/sonarqube/data" \
    SQ_EXTENSIONS_DIR="/opt/sonarqube/extensions" \
    SQ_LOGS_DIR="/opt/sonarqube/logs" \
    SQ_TEMP_DIR="/opt/sonarqube/temp"

# Separate stage to use variable expansion
ENV ES_TMPDIR="${SQ_TEMP_DIR}"

RUN mkdir -p /opt \
  && useradd --system --uid 1000 --gid 0 sonarqube;
COPY --from=builder --chown=sonarqube:sonarqube /data/sonarqube/ ${SONARQUBE_HOME}

RUN set -eux; \
  apt-get update; \
  apt-get --no-install-recommends -y install \
    bash \
    curl \
    fonts-dejavu \
    perl-base=5.34.0-3ubuntu1.5; \
  apt-get --no-install-recommends -y upgrade libc-bin libc6 locales; \
  echo "networkaddress.cache.ttl=5" >> "${JAVA_HOME}/conf/security/java.security"; \
  sed --in-place --expression="s?securerandom.source=file:/dev/random?securerandom.source=file:/dev/urandom?g" "${JAVA_HOME}/conf/security/java.security"; \
  ln -s ${SONARQUBE_HOME}/lib/sonar-application-${SONARQUBE_VERSION}.jar ${SONARQUBE_HOME}/lib/sonarqube.jar; \
  rm -rf /var/lib/apt/lists/*;

VOLUME ["${SQ_DATA_DIR}", "${SQ_EXTENSIONS_DIR}", "${SQ_LOGS_DIR}", "${SQ_TEMP_DIR}"]

COPY --chown=sonarqube:sonarqube image/community-build/entrypoint.sh ${SONARQUBE_HOME}/docker/

# replace go-plugin to support arm architecture
# pipeline: https://edge.alauda.cn/console-devops/workspace/devops/ci?namespace=tools&cluster=business-build&buildName=sonarqube-go-plugin
# RUN set -eux; \
#     rm $(find /opt/sonarqube/lib/extensions/ -name "sonar-go-plugin*"); \
#     curl -o ${SONARQUBE_HOME}/lib/extensions/sonar-go-plugin-${SONAR_GO_PLUGIN_VERSION}.jar ${REPO_HOST}/repository/alauda/sonar-plugin/sonar-go-plugin-${SONAR_GO_PLUGIN_VERSION}-all.jar; \
#     chown -R 1000:1000 ${SONARQUBE_HOME}/lib/extensions/sonar-go-plugin-${SONAR_GO_PLUGIN_VERSION}.jar

WORKDIR ${SONARQUBE_HOME}
EXPOSE 9000

USER sonarqube
STOPSIGNAL SIGINT

ENTRYPOINT ["/opt/sonarqube/docker/entrypoint.sh"]
