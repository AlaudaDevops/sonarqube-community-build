FROM build-harbor.alauda.cn/ops/alpine:3.21.5-alauda-202512020944

ADD plugins.txt /tmp/plugins/
WORKDIR /tmp/plugins
RUN cat /tmp/plugins/plugins.txt | xargs wget 
