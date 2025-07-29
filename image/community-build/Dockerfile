# source: https://github.com/SonarSource/sonarqube/blob/170bd61e5e75fb3668dd31dc71570f5e40a800fd/.cirrus/Dockerfile#L1
FROM docker-mirrors.alauda.cn/library/eclipse-temurin:17-jdk-jammy as builder

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -o errexit -o nounset \
  && groupadd --system --gid 1000 sonarsource \
  && useradd --system --gid sonarsource --uid 1000 --shell /bin/bash --create-home sonarsource

RUN echo 'Acquire::AllowReleaseInfoChange::Suite "true";' > /etc/apt/apt.conf.d/allow_release_info_change.conf

# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=863199#23
RUN mkdir -p /usr/share/man/man1 \
  && apt-get update \
  && apt-get -y install --no-install-recommends \
    lsb-release \
    ca-certificates \
    curl \
    wget \
    gnupg \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

ARG NODE_MAJOR=18
RUN DISTRO="$(lsb_release -s -c)" \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" >> /etc/apt/sources.list.d/nodesource.list \
  && curl -sSL https://packages.atlassian.com/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/atlassian.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/atlassian.gpg] https://packages.atlassian.com/debian/atlassian-sdk-deb/ stable contrib" >> /etc/apt/sources.list.d/atlassian-sdk.list \
  && curl -sSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium-archive-keyring.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/adoptium-archive-keyring.gpg] https://packages.adoptium.net/artifactory/deb $DISTRO main" >> /etc/apt/sources.list.d/adoptopenjdk.list \
  && apt-get update \
  && apt-get -y install --no-install-recommends \
    git \
    unzip \
    nodejs="$NODE_MAJOR".* \
    jq \
    expect \
    # atlassian-plugin-sdk \
    temurin-8-jdk \
    xmlstarlet \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && npm install -g yarn

# Avoiding JVM Delays Caused by Random Number Generation (https://docs.oracle.com/cd/E13209_01/wlcp/wlss30/configwlss/jvmrand.html)
RUN sed -i 's|securerandom.source=file:/dev/random|securerandom.source=file:/dev/urandom|g' "$JAVA_HOME/conf/security/java.security"

RUN mkdir /data && chown -R sonarsource:sonarsource /data
USER sonarsource
WORKDIR /home/sonarsource

ARG SONARQUBE_VERSION=25.1.0.102122
COPY --chown=sonarsource:sonarsource source/ /home/sonarsource
RUN set -eux; \
    export BUILD_NUMBER="${SONARQUBE_VERSION##*.}"; \
    ./gradlew build -DbuildNumber="$BUILD_NUMBER" -x test --console plain;

RUN mkdir -p /data/patches \
  && unzip sonar-application/build/distributions/sonar-application-${SONARQUBE_VERSION}.zip -d /data \
  && mv /data/sonarqube-${SONARQUBE_VERSION} /data/sonarqube \
  && ls -al /data/sonarqube

COPY --chown=sonarsource:sonarsource image/community-build/apply-jar-patch.sh /tmp/apply-jar-patch.sh
# renovate: datasource=maven depName=net.minidev/json-smart
ARG JSON_SMART_VERSION=2.5.2
# renovate: datasource=maven depName=io.netty/netty-handler
ARG NETTY_HANDLER_VERSION=4.1.118.Final
RUN set -eux \
  && curl -o /data/patches/json-smart-${JSON_SMART_VERSION}.jar https://repo1.maven.org/maven2/net/minidev/json-smart/${JSON_SMART_VERSION}/json-smart-${JSON_SMART_VERSION}.jar \
  && curl -o /data/patches/netty-handler-${NETTY_HANDLER_VERSION}.jar https://repo1.maven.org/maven2/io/netty/netty-handler/${NETTY_HANDLER_VERSION}/netty-handler-${NETTY_HANDLER_VERSION}.jar \
  && chmod +x /tmp/apply-jar-patch.sh \
  && /tmp/apply-jar-patch.sh /data/patches /data/sonarqube


FROM docker-mirrors.alauda.cn/library/eclipse-temurin:17-jdk-jammy

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

RUN mkdir -p /opt
COPY --from=builder /data/sonarqube/ ${SONARQUBE_HOME}

RUN set -eux; \
    # deluser ubuntu; \
    useradd --system --uid 1000 --gid 0 sonarqube; \
    apt-get update; \
    apt-get --no-install-recommends -y install \
        bash \
        curl \
        fonts-dejavu; \
    echo "networkaddress.cache.ttl=5" >> "${JAVA_HOME}/conf/security/java.security"; \
    sed --in-place --expression="s?securerandom.source=file:/dev/random?securerandom.source=file:/dev/urandom?g" "${JAVA_HOME}/conf/security/java.security"; \
    rm -rf ${SONARQUBE_HOME}/bin/*; \
    ln -s "${SONARQUBE_HOME}/lib/sonar-application-${SONARQUBE_VERSION}.jar" "${SONARQUBE_HOME}/lib/sonarqube.jar"; \
    chmod -R 550 ${SONARQUBE_HOME}; \
    chmod -R 770 "${SQ_DATA_DIR}" "${SQ_EXTENSIONS_DIR}" "${SQ_LOGS_DIR}" "${SQ_TEMP_DIR}"; \
    rm -rf /var/lib/apt/lists/*;

VOLUME ["${SQ_DATA_DIR}", "${SQ_EXTENSIONS_DIR}", "${SQ_LOGS_DIR}", "${SQ_TEMP_DIR}"]

COPY image/community-build/entrypoint.sh ${SONARQUBE_HOME}/docker/

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
