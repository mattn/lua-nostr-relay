FROM alpine:3.20 AS builder

ARG LUA_VER=5.2
ARG LUAROCKS_VER=3.12.2

RUN apk add --no-cache \
    lua${LUA_VER} lua${LUA_VER}-dev \
    luajit gcc musl-dev postgresql-dev \
    libsecp256k1-dev \
    git make tar wget ca-certificates

RUN set -ex; \
    wget https://github.com/luarocks/luarocks/archive/v${LUAROCKS_VER}.tar.gz && \
    tar xzf v${LUAROCKS_VER}.tar.gz && \
    cd luarocks-${LUAROCKS_VER} && \
    ./configure --with-lua=/usr && \
    make build install && \
    cd .. && rm -rf luarocks-${LUAROCKS_VER} v${LUAROCKS_VER}.tar.gz

RUN luarocks install copas \
 && luarocks install luasocket \
 && luarocks install lua-cjson \
 && luarocks install luapgsql PQ_INCDIR=/usr/include/postgresql \
 && luarocks install lua-websockets \
 && luarocks install log.lua \
 && luarocks install https://raw.githubusercontent.com/mattn/lua-nostr-schnorr/refs/heads/main/nostr-schnorr-0.0.1-1.rockspec

FROM alpine:3.20

ARG LUA_VER=5.2
ENV LUA_EXE=lua${LUA_VER}
ENV DATABASE_URL=

RUN apk add --no-cache lua${LUA_VER} libpq libsecp256k1

COPY --from=builder /usr/local /usr/local

WORKDIR /app
COPY nostr-relay.lua .
COPY public ./public

EXPOSE 8080

CMD ["sh", "-c", "exec ${LUA_EXE} nostr-relay.lua"]
