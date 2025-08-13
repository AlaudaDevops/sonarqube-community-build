#!/bin/bash

set -ex

SONAR_HOST=$1
SONAR_USER=$2
SONAR_PWD=$3

url="$SONAR_HOST/api/user_tokens/generate?name=my-token-$(date +%s)"
SONAR_TOKEN=$(curl -s -X POST -u "$SONAR_USER:$SONAR_PWD" "$url" | jq -r '.token')
echo "获取到的Token是: $SONAR_TOKEN"

mkdir -p ~/.m2
SONAR_SETTINGS_CONTENT="    <pluginGroups>\n"
SONAR_SETTINGS_CONTENT+="        <pluginGroup>org.sonarsource.scanner.maven</pluginGroup>\n"
SONAR_SETTINGS_CONTENT+="    </pluginGroups>\n"
SONAR_SETTINGS_CONTENT+="    <profiles>\n"
SONAR_SETTINGS_CONTENT+="        <profile>\n"
SONAR_SETTINGS_CONTENT+="            <id>sonar</id>\n"
SONAR_SETTINGS_CONTENT+="            <activation>\n"
SONAR_SETTINGS_CONTENT+="                <activeByDefault>true</activeByDefault>\n"
SONAR_SETTINGS_CONTENT+="            </activation>\n"
SONAR_SETTINGS_CONTENT+="            <properties>\n"
SONAR_SETTINGS_CONTENT+="                <sonar.host.url>$SONAR_HOST</sonar.host.url>\n"
SONAR_SETTINGS_CONTENT+="                <sonar.login>$SONAR_TOKEN</sonar.login>\n"
SONAR_SETTINGS_CONTENT+="            </properties>\n"
SONAR_SETTINGS_CONTENT+="        </profile>\n"
SONAR_SETTINGS_CONTENT+="    </profiles>"

SETTINGS_FILE=~/.m2/settings.xml
if [ -f "$SETTINGS_FILE" ]; then
    # 检查是否已有sonar profile
    if grep -q '<id>sonar</id>' "$SETTINGS_FILE"; then
        # 用新内容替换原有sonar profile
        TMP_FILE=$(mktemp)
        awk -v content="$SONAR_SETTINGS_CONTENT" '
            BEGIN{profile=0}
            /<profile>/ {p=NR}
            /<id>sonar<\/id>/ {profile=1}
            profile && /<\/profile>/ {
                print content; profile=0; next
            }
            !(profile && NR>p) {print}
        ' "$SETTINGS_FILE" > "$TMP_FILE"
        mv "$TMP_FILE" "$SETTINGS_FILE"
    else
        # 插入sonar配置到<settings>标签内
        TMP_FILE=$(mktemp)
        awk -v content="$SONAR_SETTINGS_CONTENT" '
            /<settings>/ && !x {print; print content; x=1; next} 1
        ' "$SETTINGS_FILE" > "$TMP_FILE"
        mv "$TMP_FILE" "$SETTINGS_FILE"
    fi
else
    cat <<EOF > "$SETTINGS_FILE"
<settings>
$SONAR_SETTINGS_CONTENT
</settings>
EOF
fi


cat <<EOF > sonarqube-config.yaml
sonar:
    url: $SONAR_HOST
    token: $SONAR_TOKEN
EOF

cat ./sonarqube-config.yaml


export SONAR_HOST=$SONAR_HOST
export SONAR_TOKEN=$SONAR_TOKEN
export TESTING_CONFIG=./sonarqube-config.yaml

make sonarqube
