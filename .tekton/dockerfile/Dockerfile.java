# renovate: datasource=docker depName=eclipse-temurin
FROM docker-mirrors.alauda.cn/library/eclipse-temurin:17.0.15_6-jdk-jammy

# source: https://github.com/SonarSource/sonarqube/blob/170bd61e5e75fb3668dd31dc71570f5e40a800fd/.cirrus/Dockerfile#L1
RUN export DEBIAN_FRONTEND=noninteractive; \
    echo 'Acquire::AllowReleaseInfoChange::Suite "true";' > /etc/apt/apt.conf.d/allow_release_info_change.conf; \
    # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=863199#23
    mkdir -p /usr/share/man/man1; \
    apt-get update; \
    apt-get -y install --no-install-recommends \
      lsb-release \
      ca-certificates \
      curl \
      wget \
      gnupg;

RUN export NODE_MAJOR=18; \
    export DISTRO="$(lsb_release -s -c)"; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" >> /etc/apt/sources.list.d/nodesource.list; \
    curl -sSL https://packages.atlassian.com/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/atlassian.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/atlassian.gpg] https://packages.atlassian.com/debian/atlassian-sdk-deb/ stable contrib" >> /etc/apt/sources.list.d/atlassian-sdk.list; \
    curl -sSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium-archive-keyring.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/adoptium-archive-keyring.gpg] https://packages.adoptium.net/artifactory/deb $DISTRO main" >> /etc/apt/sources.list.d/adoptopenjdk.list; \
    apt-get update; \
    apt-get -y install --no-install-recommends \
      git \
      unzip \
      nodejs="$NODE_MAJOR".* \
      jq \
      expect \
      temurin-8-jdk \
      xmlstarlet; \
      npm install -g yarn;

RUN sed -i 's|securerandom.source=file:/dev/random|securerandom.source=file:/dev/urandom|g' "$JAVA_HOME/conf/security/java.security"
