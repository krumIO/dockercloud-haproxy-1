FROM alpine:3.6

ENV HAPROXY_MAJOR 1.8
ENV HAPROXY_VERSION 1.8.3
ENV HAPROXY_MD5 2e1e3eb42f07983c9303c5622d812862

# https://www.lua.org/ftp/#source
ENV LUA_VERSION=5.3.4 \
	LUA_SHA1=79790cfd40e09ba796b01a571d4d63b52b1cd950

# see https://sources.debian.net/src/haproxy/jessie/debian/rules/ for some helpful navigation of the possible "make" arguments
RUN set -x \
	\
	&& apk add --no-cache --virtual .build-deps \
		ca-certificates \
		gcc \
		libc-dev \
		linux-headers \
		make \
		openssl \
		openssl-dev \
		pcre-dev \
		readline-dev \
		tar \
		zlib-dev \
	\
# install Lua
	&& wget -O lua.tar.gz "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz" \
	&& echo "$LUA_SHA1 *lua.tar.gz" | sha1sum -c \
	&& mkdir -p /usr/src/lua \
	&& tar -xzf lua.tar.gz -C /usr/src/lua --strip-components=1 \
	&& rm lua.tar.gz \
	&& make -C /usr/src/lua -j "$(getconf _NPROCESSORS_ONLN)" linux \
	&& make -C /usr/src/lua install \
# put things we don't care about into a "trash" directory for purging
		INSTALL_BIN='/usr/src/lua/trash/bin' \
		INSTALL_CMOD='/usr/src/lua/trash/cmod' \
		INSTALL_LMOD='/usr/src/lua/trash/lmod' \
		INSTALL_MAN='/usr/src/lua/trash/man' \
# ... and since it builds static by default, put those bits somewhere we can purge after we build haproxy
		INSTALL_INC='/usr/local/lua-install/inc' \
		INSTALL_LIB='/usr/local/lua-install/lib' \
	&& rm -rf /usr/src/lua \
	\
# install HAProxy
	&& wget -O haproxy.tar.gz "https://www.haproxy.org/download/${HAPROXY_MAJOR}/src/haproxy-${HAPROXY_VERSION}.tar.gz" \
	&& echo "$HAPROXY_MD5 *haproxy.tar.gz" | md5sum -c \
	&& mkdir -p /usr/src/haproxy \
	&& tar -xzf haproxy.tar.gz -C /usr/src/haproxy --strip-components=1 \
	&& rm haproxy.tar.gz \
	\
	&& makeOpts=' \
		TARGET=linux2628 \
		USE_LUA=1 LUA_INC=/usr/local/lua-install/inc LUA_LIB=/usr/local/lua-install/lib \
		USE_OPENSSL=1 \
		USE_PCRE=1 PCREDIR= \
		USE_ZLIB=1 \
	' \
	&& make -C /usr/src/haproxy -j "$(getconf _NPROCESSORS_ONLN)" all $makeOpts \
	&& make -C /usr/src/haproxy install-bin $makeOpts \
	\
# purge the remnants of our static Lua
	&& rm -rf /usr/local/lua-install \
	\
	&& mkdir -p /usr/local/etc/haproxy \
	&& cp -R /usr/src/haproxy/examples/errorfiles /usr/local/etc/haproxy/errors \
	&& rm -rf /usr/src/haproxy \
	\
	&& runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)" \
	&& apk add --virtual .haproxy-rundeps $runDeps \
	&& apk del .build-deps

COPY . /haproxy-src

RUN apk update && \
    apk --no-cache add tini haproxy py-pip build-base python-dev && \
    cp /haproxy-src/reload.sh /reload.sh && \
    cd /haproxy-src && \
    pip install -r requirements.txt && \
    pip install . && \
    apk del build-base python-dev && \
    rm -rf "/tmp/*" "/root/.cache" `find / -regex '.*\.py[co]'`

ENV RSYSLOG_DESTINATION=127.0.0.1 \
    MODE=http \
    BALANCE=roundrobin \
    MAXCONN=4096 \
    OPTION="redispatch, httplog, dontlognull, forwardfor" \
    TIMEOUT="connect 5000, client 50000, server 50000" \
    STATS_PORT=1936 \
    STATS_AUTH="stats:stats" \
    SSL_BIND_OPTIONS=no-sslv3 \
    SSL_BIND_CIPHERS="ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:AES128-GCM-SHA256:AES128-SHA256:AES128-SHA:AES256-GCM-SHA384:AES256-SHA256:AES256-SHA:DHE-DSS-AES128-SHA:DES-CBC3-SHA" \
    HEALTH_CHECK="check inter 2000 rise 2 fall 3" \
    NBPROC=1

EXPOSE 80 443 1936
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["dockercloud-haproxy"]
