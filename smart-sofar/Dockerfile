ARG BUILD_FROM=ghcr.io/hassio-addons/base:15.0.7
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apk add --no-cache bash jq nodejs-lts npm \
  || apk add --no-cache bash jq "nodejs~22" "npm~10"

RUN npm install -g node-red@4.1.4 \
  && npm cache clean --force

WORKDIR /opt
RUN apk add --no-cache --virtual .build-deps \
      build-base linux-headers python3 make g++ \
  && npm i --omit=dev --no-audit --no-fund \
      node-red-node-serialport \
      node-red-contrib-modbus \
  && apk del .build-deps \
  && npm cache clean --force

COPY . /addon
RUN chmod a+x /addon/run.sh

WORKDIR /addon
ENTRYPOINT ["/addon/run.sh"]
