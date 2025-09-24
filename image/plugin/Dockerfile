FROM build-harbor.alauda.cn/ops/alpine:3@sha256:d97795482dc347cc59432bf4fe506b5f92ca03f83d4fd3c746b8fa49d8371e5a

ADD plugins.txt /tmp/plugins/
WORKDIR /tmp/plugins
RUN apk add --no-cache wget && wget -c -q -i ./plugins.txt
