# SonarQube 官方插件导入步骤

插件包在独立的外部工作环境中准备，再复制到 SonarQube 实例。整个过程不依赖
代码仓库、SonarQube 镜像或 Helm Chart。安装目录为
`${SONARQUBE_HOME}/extensions/plugins/`，不要使用 `elasticsearch/plugins/`。

## 0. 部署前配置 Sonar CR

SonarQube 通过 Helm 部署时，必须在 Sonar CR 的 Helm values 中关闭默认插件清理，
否则 Pod 启动时会删除共享卷中的外部插件：

```yaml
plugins:
  deleteDefaultPlugins: false
```

修改 Sonar CR 后等待 Deployment 滚动完成，再执行后续步骤。确认配置已生效：

```bash
kubectl -n <sonarqube-namespace> get sonarqube <sonarqube-cr-name> -o yaml
```

输出中的 `plugins.deleteDefaultPlugins` 必须为 `false`。

## 1. 在外部环境创建插件清单

清单与仓库中的 `hack/official-plugins-26.1.txt` 保持一致，更新时两处一起修改。

```bash
mkdir -p "$PWD/sonarqube-plugins-26.1"
cd "$PWD/sonarqube-plugins-26.1"
cat > official-plugins-26.1.txt <<'EOF'
org.sonarsource.dotnet:sonar-csharp-plugin:10.17.0.131074
org.sonarsource.dotnet:sonar-vbnet-plugin:10.17.0.131074
org.sonarsource.flex:sonar-flex-plugin:2.16.0.6009
org.sonarsource.go:sonar-go-plugin:1.31.0.4938
org.sonarsource.html:sonar-html-plugin:3.22.0.7011
org.sonarsource.java:sonar-java-plugin:8.22.0.41895
org.sonarsource.java:sonar-java-symbolic-execution-plugin:8.16.3.1589
org.sonarsource.jacoco:sonar-jacoco-plugin:1.4.0.4946
org.sonarsource.javascript:sonar-javascript-plugin:11.7.1.36988:multi
org.sonarsource.php:sonar-php-plugin:3.53.0.15220
org.sonarsource.plugins.cayc:sonar-cayc-plugin:2.6.0.3665
org.sonarsource.python:sonar-python-plugin:5.31.0.36502
org.sonarsource.kotlin:sonar-kotlin-plugin:3.3.1.7792
org.sonarsource.slang:sonar-ruby-plugin:1.21.1.1877
org.sonarsource.rust:sonar-rust-plugin:1.2.0.1339
org.sonarsource.slang:sonar-scala-plugin:1.20.1.1884
org.sonarsource.xml:sonar-xml-plugin:2.14.2.7437
org.sonarsource.iac:sonar-iac-plugin:2.4.0.18716
org.sonarsource.text:sonar-text-plugin:2.49.0.12346
EOF
```

## 2. 创建下载和打包脚本

```bash
cat > download-plugins.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
manifest=${1:?manifest path required}
output_dir=${2:?output directory required}
repo_url=${MAVEN_REPO_URL:-https://repo1.maven.org/maven2}
mkdir -p "$output_dir"
while IFS=: read -r group artifact version classifier; do
  [[ -z "${group:-}" || "$group" == \#* ]] && continue
  if [[ "$artifact" == "sonar-javascript-plugin" && -n "${JS_CLASSIFIER:-}" ]]; then
    classifier=$JS_CLASSIFIER
  fi
  path="${group//.//}/$artifact/$version"
  name="${artifact}-${version}"
  [[ -n "${classifier:-}" ]] && name="${name}-${classifier}"
  curl --fail --location --retry 3 \
    "$repo_url/$path/$name.jar" \
    --output "$output_dir/$name.jar"
done < "$manifest"
tar -czf "${output_dir}.tgz" -C "$output_dir" .
EOF
chmod 700 download-plugins.sh
```

## 3. 下载、校验并传送插件包

`sonar-javascript-plugin` 的 `multi` 包只带 x86_64 等平台的 Node 运行时。SonarQube
运行在 **arm64** 节点上时，下载前设置 `JS_CLASSIFIER=linux-arm64`，改用 arm64 包；
否则 JavaScript / TypeScript 分析会因缺少 Node 运行时而失败。

```bash
# x86_64 节点
./download-plugins.sh official-plugins-26.1.txt plugins
# arm64 节点改用：
# JS_CLASSIFIER=linux-arm64 ./download-plugins.sh official-plugins-26.1.txt plugins
find plugins -maxdepth 1 -type f -name '*.jar' -print
(cd plugins && sha256sum *.jar) > official-plugins-26.1.sha256
tar -tzf plugins.tgz
```

校验文件必须只包含 JAR 文件名，不得包含 `plugins/` 前缀。若已生成旧校验文件，先删除
后重新执行上面的 `sha256sum` 命令：

```bash
rm -f official-plugins-26.1.sha256
(cd plugins && sha256sum *.jar) > official-plugins-26.1.sha256
```

将 `plugins.tgz` 和 `official-plugins-26.1.sha256` 传送到安装环境。传送后执行：

```bash
(cd plugins && sha256sum -c ../official-plugins-26.1.sha256)
```

## 4. 复制插件包到 Kubernetes Pod

将下面三个值替换为实际的命名空间、Pod 名称和容器名称：

```bash
# 用户输入：SonarQube 部署所在的 namespace
export NAMESPACE=<sonarqube-namespace>
# 用户输入：当前运行 SonarQube 的 Pod 名称
export POD_NAME=<sonarqube-pod-name>
export CONTAINER_NAME=sonarqube
kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o wide
kubectl -n "$NAMESPACE" cp plugins.tgz "$POD_NAME":/tmp/plugins.tgz -c "$CONTAINER_NAME"
kubectl -n "$NAMESPACE" cp official-plugins-26.1.sha256 \
  "$POD_NAME":/tmp/official-plugins-26.1.sha256 -c "$CONTAINER_NAME"
kubectl -n "$NAMESPACE" exec "$POD_NAME" -c "$CONTAINER_NAME" -- \
  ls -l /tmp/plugins.tgz /tmp/official-plugins-26.1.sha256
```

## 5. 在 Pod 内安装插件包

```bash
kubectl -n "$NAMESPACE" exec "$POD_NAME" -c "$CONTAINER_NAME" -- sh -eu -c '
  SONARQUBE_HOME=${SONARQUBE_HOME:-/opt/sonarqube}
  backup="$SONARQUBE_HOME/extensions/plugins-backup/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  cp -a "$SONARQUBE_HOME/extensions/plugins"/*.jar "$backup" 2>/dev/null || true
  incoming=$(mktemp -d)
  tar -xzf /tmp/plugins.tgz -C "$incoming"
  sed "s#  plugins/#  #" /tmp/official-plugins-26.1.sha256 > /tmp/plugins.sha256
  (cd "$incoming" && sha256sum -c /tmp/plugins.sha256)
  find "$incoming" -maxdepth 1 -type f -name "*.jar" -print
  find "$SONARQUBE_HOME/extensions/plugins" -maxdepth 1 -type f -name "*.jar" -delete
  cp "$incoming"/*.jar "$SONARQUBE_HOME/extensions/plugins/"
  chown -R sonarqube "$SONARQUBE_HOME/extensions/plugins"
  chmod 0644 "$SONARQUBE_HOME/extensions/plugins"/*.jar
  rm -rf "$incoming"
  rm -f /tmp/plugins.sha256
'
```

## 6. 重启 Pod

`extensions/plugins` 使用持久卷，因此通过删除 Pod 触发 Kubernetes 重建：

```bash
kubectl -n "$NAMESPACE" delete pod "$POD_NAME"
kubectl -n "$NAMESPACE" get pod -w
```

Pod 重新就绪后，输入新 Pod 名称并继续验证：

```bash
# 用户输入：重建后的 SonarQube Pod 名称
export POD_NAME=<new-sonarqube-pod-name>
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD_NAME" --timeout=300s
```

Pod 重启后 `/tmp` 会被清空。必须重新执行第 4 步，将 `plugins.tgz` 和
`official-plugins-26.1.sha256` 复制到新 Pod，再执行第 5 步；不能复用旧 Pod 的
`/tmp` 文件。

## 7. 验证 Pod 内服务

```bash
export SONAR_PASSWORD=<sonarqube-admin-password>
kubectl -n "$NAMESPACE" exec "$POD_NAME" -c "$CONTAINER_NAME" -- \
  curl --fail http://localhost:9000/api/system/status
kubectl -n "$NAMESPACE" exec "$POD_NAME" -c "$CONTAINER_NAME" -- \
  curl -u admin:$SONAR_PASSWORD --fail http://localhost:9000/api/plugins/installed
kubectl -n "$NAMESPACE" exec "$POD_NAME" -c "$CONTAINER_NAME" -- \
  find /opt/sonarqube/extensions/plugins -maxdepth 1 -type f -name '*.jar' -print
```

确认状态为 `UP`，插件 ID/版本正确且无重复版本，再执行一次实际扫描。

