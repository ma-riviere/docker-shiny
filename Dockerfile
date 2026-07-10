ARG R_VERSION=4.6.1
ARG R_VERSION_SHORT=4.6
ARG DEBIAN_NUMERIC=13
ARG DEBIAN_CODENAME=trixie
ARG SHINY_SERVER_VERSION=1.5.23.1030

FROM debian:${DEBIAN_CODENAME}-slim AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    R_LIBS_SITE=/opt/r-site-library

FROM base AS r-deb

ARG R_VERSION
ARG DEBIAN_NUMERIC

# The Posit R deb's hard Depends include the compiler toolchain: this stage is
# disposable, runtime copies /opt/R out of it instead of installing the deb
RUN curl --fail --location --output /tmp/r.deb \
        "https://cdn.posit.co/r/debian-${DEBIAN_NUMERIC}/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb" \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/r.deb \
    && ln -s /opt/R/${R_VERSION}/bin/R /usr/local/bin/R \
    && ln -s /opt/R/${R_VERSION}/bin/Rscript /usr/local/bin/Rscript \
    && rm /tmp/r.deb \
    && rm -rf /var/lib/apt/lists/*

# Shiny Server scrubs the environment of R worker processes, so ENV R_LIBS_SITE never
# reaches apps. The deb's etc/Renviron sets R_LIBS_SITE=${R_LIBS_SITE:-'%S'} (unsubstituted
# template) before Renviron.site is read, so the default must be fixed in etc/Renviron itself.
RUN sed -i "s|^R_LIBS_SITE=.*|R_LIBS_SITE=\${R_LIBS_SITE:-'${R_LIBS_SITE}'}|" /opt/R/${R_VERSION}/lib/R/etc/Renviron \
    && grep -q "opt/r-site-library" /opt/R/${R_VERSION}/lib/R/etc/Renviron

FROM r-deb AS builder

ARG R_VERSION
ARG R_VERSION_SHORT
ARG DEBIAN_CODENAME

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        # otelsdk source fallback builds opentelemetry-cpp
        cmake \
        libpq-dev \
        libsodium-dev \
        libssl-dev \
        libcurl4-openssl-dev \
        # fs/httpuv PPM binaries link system libuv; renv load-tests packages at install time
        libuv1 \
        # otelsdk PPM binary links libprotobuf.so.32
        libprotobuf32t64 \
        libxml2-dev \
        zlib1g-dev \
        pkg-config \
        libfontconfig1-dev \
        libfreetype6-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        libpng-dev \
        libtiff-dev \
        libjpeg-dev \
        libwebp-dev \
    && rm -rf /var/lib/apt/lists/*

# No renv cache: restores install real files straight into the site library
# (cache symlinks would break COPY --from, and the cache doubles the image)
ENV RENV_CONFIG_SANDBOX_ENABLED=false \
    RENV_CONFIG_AUTO_SNAPSHOT=false \
    RENV_CONFIG_CACHE_ENABLED=false

# Latest renv as a PPM trixie binary; it only drives restores (lockfiles pin their own records).
# No RENV_CONFIG_REPOS_OVERRIDE anywhere: restores must honor the lockfile's dated PPM snapshot.
RUN mkdir -p /opt/renv-bootstrap \
    && PPM_LATEST="https://packagemanager.posit.co/cran/__linux__/${DEBIAN_CODENAME}/latest" \
       Rscript -e 'install.packages("renv", lib = "/opt/renv-bootstrap", repos = Sys.getenv("PPM_LATEST"))'

COPY renv/profiles/docker-${R_VERSION_SHORT}/renv.lock /tmp/renv.lock

# The selected lockfile must match the installed R (guards matrix typos pairing
# e.g. R 4.5.3 with the docker-4.6 lockfile)
RUN grep -A2 '"R":' /tmp/renv.lock | grep -q "\"Version\": \"${R_VERSION}\"" \
    || { echo "Lockfile R version does not match R_VERSION=${R_VERSION}"; exit 1; }

# Private GitHub packages (auth0r, shinyutils) need a read-scoped PAT,
# passed as a BuildKit secret so it never lands in a layer
RUN --mount=type=secret,id=github_pat \
    mkdir -p "${R_LIBS_SITE}" \
    && GITHUB_PAT="$(cat /run/secrets/github_pat 2>/dev/null || true)" \
    Rscript -e '.libPaths(c("/opt/renv-bootstrap", .libPaths())); renv::restore(lockfile = "/tmp/renv.lock", library = Sys.getenv("R_LIBS_SITE"), clean = TRUE, prompt = FALSE)' \
    && rm -rf /root/.cache/R

RUN find "${R_LIBS_SITE}" -depth -type d \
        \( -name help -o -name html -o -name doc -o -name tests \) -exec rm -rf {} +

FROM builder AS test

# Debian's chromium crashes (SIGTRAP) in headless remote-debugging mode inside
# containers, breaking shinytest2; Google Chrome stable works
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /usr/share/keyrings/google-chrome.asc \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# CI containers run as root, where Chrome's sandbox cannot be used.
# IN_CONTAINER lets consumer .Rprofile skip renv activation (library is in R_LIBS_SITE).
ENV CHROMOTE_CHROME=/usr/bin/google-chrome-stable \
    SHINYTEST2_CHROMIUM_PATH=/usr/bin/google-chrome-stable \
    CHROMOTE_CHROME_ARGS="--no-sandbox --disable-dev-shm-usage" \
    IN_CONTAINER=true

FROM base AS runtime

ARG R_VERSION
ARG SHINY_SERVER_VERSION

COPY --from=r-deb /opt/R/${R_VERSION} /opt/R/${R_VERSION}

# Explicit runtime allowlist: the R deb's Depends minus toolchain/-dev packages,
# plus the shared libraries the package library links (validated by verify)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fontconfig \
        libbz2-1.0 \
        libcairo2 \
        libcurl4t64 \
        libdeflate0 \
        libfontconfig1 \
        libfreetype6 \
        libfribidi0 \
        libgfortran5 \
        libglib2.0-0t64 \
        libgomp1 \
        libgssapi-krb5-2 \
        libharfbuzz0b \
        libicu76 \
        libkrb5-3 \
        liblzma5 \
        libopenblas0-pthread \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libpaper-utils \
        libpcre2-8-0 \
        libpng16-16t64 \
        libpq5 \
        # otelsdk links libprotobuf.so.32
        libprotobuf32t64 \
        libreadline8t64 \
        libsodium23 \
        libtcl8.6 \
        libtiff6 \
        libtirpc3t64 \
        libtinfo6 \
        libtk8.6 \
        libuv1 \
        libwebpmux3 \
        libx11-6 \
        libxml2 \
        libxt6t64 \
        libzstd1 \
        ucf \
        unzip \
        xtail \
        zip \
        zlib1g \
    && ln -s /opt/R/${R_VERSION}/bin/R /usr/local/bin/R \
    && ln -s /opt/R/${R_VERSION}/bin/Rscript /usr/local/bin/Rscript \
    && mkdir -p "${R_LIBS_SITE}" \
    && rm -rf /var/lib/apt/lists/*

# Pinned UID/GID: deployment volumes are owned by 997:997; created before the
# shiny-server deb so its postinst reuses this user
RUN groupadd -g 997 shiny \
    && useradd -u 997 -g shiny -m -d /home/shiny -s /usr/sbin/nologin shiny

RUN curl --fail --location --output /tmp/ss.deb \
        "https://download3.rstudio.org/ubuntu-20.04/x86_64/shiny-server-${SHINY_SERVER_VERSION}-amd64.deb" \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/ss.deb \
    && rm /tmp/ss.deb \
    && rm -rf /var/lib/apt/lists/* \
    && [ "$(id -u shiny)" = "997" ] && [ "$(id -g shiny)" = "997" ] \
    && mkdir -p /srv/shiny-server /var/log/shiny-server /var/lib/shiny-server \
    && chown -R shiny:shiny /srv/shiny-server /var/log/shiny-server /var/lib/shiny-server

COPY --chmod=755 docker-shiny.sh /usr/local/bin/docker-shiny.sh

# Lets consumer .Rprofile skip renv activation (the library lives in R_LIBS_SITE)
ENV IN_CONTAINER=true

WORKDIR /srv/shiny-server
USER shiny
EXPOSE 3838
CMD ["/usr/local/bin/docker-shiny.sh"]

FROM runtime AS verify

COPY --from=builder ${R_LIBS_SITE} ${R_LIBS_SITE}

# Every package must load on the runtime image (catches missing shared libraries)
RUN Rscript -e 'lib <- Sys.getenv("R_LIBS_SITE"); pkgs <- rownames(installed.packages(lib.loc = lib)); failed <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE, lib.loc = lib)]; if (length(failed)) stop("Could not load: ", paste(failed, collapse = ", "))'

# No ELF object in Shiny Server, R, or the site library may have unresolved links
RUN <<'EOF'
#!/bin/bash
set -u
export LD_LIBRARY_PATH="$(echo /opt/R/*/lib/R/lib | tr ' ' ':')"
failures=0
while IFS= read -r binary; do
    if head -c4 "$binary" 2>/dev/null | grep -q $'\x7fELF'; then
        missing=$(ldd "$binary" 2>/dev/null | grep "not found")
        if [ -n "$missing" ]; then
            echo "UNRESOLVED: $binary"
            echo "$missing"
            failures=1
        fi
    fi
done < <(find /opt/shiny-server /opt/R "$R_LIBS_SITE" -type f \( -perm -u+x -o -name "*.so*" \))
[ "$failures" -eq 0 ] && echo "ldd check OK"
exit "$failures"
EOF

# Shiny Server must serve an app over HTTP and accept a websocket upgrade
RUN <<'EOF'
#!/bin/bash
set -eu
cat > /srv/shiny-server/app.R <<'APP'
library(shiny)
shinyApp(
    fluidPage(textOutput("status")),
    function(input, output, session) {
        output$status <- renderText("verify-ok")
    }
)
APP
# Exercise the published entrypoint: env filtering into .Renviron + shiny-server.
# Output to a file so the backgrounded xtail cannot hold this build step open.
VERIFY_SENTINEL=sentinel-value DOCKER_INTERNAL=leak /usr/local/bin/docker-shiny.sh > /tmp/ss.log 2>&1 &
server_pid=$!
sleep 8
[ -f /srv/shiny-server/.Renviron ]
[ "$(stat -c '%a %U' /srv/shiny-server/.Renviron)" = "600 shiny" ]
grep -q "VERIFY_SENTINEL=sentinel-value" /srv/shiny-server/.Renviron
if grep -q "DOCKER_INTERNAL" /srv/shiny-server/.Renviron; then
    echo ".Renviron filtering failed"
    exit 1
fi
curl -fsS http://127.0.0.1:3838/ > /tmp/index.html
grep -qi "shiny" /tmp/index.html
if grep -qi "error has occurred" /tmp/index.html; then
    echo "app failed to start:"
    cat /var/log/shiny-server/*.log 2>/dev/null
    exit 1
fi
curl -fsS --max-time 5 http://127.0.0.1:3838/__sockjs__/info | grep -q '"websocket":true'
# A successful upgrade keeps the connection open: cap with --max-time, read the header
ws_status=$(curl -si --max-time 3 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    http://127.0.0.1:3838/__sockjs__/0/verify00/websocket 2>/dev/null | head -1 || true)
echo "$ws_status" | grep -q "101" || { echo "websocket handshake failed: $ws_status"; exit 1; }
kill "$server_pid"
rm -f /srv/shiny-server/app.R /srv/shiny-server/.Renviron /tmp/index.html /tmp/ss.log
echo "shiny-server smoke test OK"
EOF

# Runtime contract: no build/test tooling, correct user, writable directories
RUN <<'EOF'
#!/bin/bash
set -eu
for tool in gcc g++ gfortran make git google-chrome-stable; do
    if command -v "$tool" > /dev/null 2>&1; then
        echo "forbidden tool in runtime: $tool"
        exit 1
    fi
done
[ "$(id -un)" = "shiny" ] && [ "$(id -u)" = "997" ] && [ "$(id -g)" = "997" ]
[ -w /srv/shiny-server ] && [ -w /var/log/shiny-server ] && [ -w /var/lib/shiny-server ]
[ -r "$R_LIBS_SITE" ]
Rscript -e 'stopifnot(Sys.getenv("R_LIBS_SITE") %in% .libPaths())'
echo "runtime contract OK"
EOF
