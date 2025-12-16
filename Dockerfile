ARG REGISTRY_IMAGE=ghcr.io/ma-riviere/docker-shiny
FROM ${REGISTRY_IMAGE}:base

# Install R (full version for download, major.minor for symlinks/profiles)
ARG R_VERSION
ARG R_VERSION_SHORT
ARG DEBIAN_NUMERIC=12
RUN curl -O https://cdn.posit.co/r/debian-${DEBIAN_NUMERIC}/pkgs/r-${R_VERSION}_1_$(dpkg --print-architecture).deb \
    && apt-get update && apt-get install -y --no-install-recommends ./r-${R_VERSION}_1_$(dpkg --print-architecture).deb \
    && ln -s /opt/R/${R_VERSION}/bin/R /usr/local/bin/R \
    && ln -s /opt/R/${R_VERSION}/bin/Rscript /usr/local/bin/Rscript \
    && rm r-${R_VERSION}_1_$(dpkg --print-architecture).deb \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Setup R packages with renv
WORKDIR /srv/shiny-server
COPY --chown=shiny:shiny renv/ ./renv/
COPY --chmod=755 docker-shiny.sh ./docker-shiny.sh

USER shiny
ENV RENV_PATHS_CACHE=/opt/renv/cache \
    RENV_CONFIG_PPM_ENABLED=TRUE \
    RENV_CONFIG_SANDBOX_ENABLED=FALSE \
    RENV_CONFIG_SYNCHRONIZED_CHECK=FALSE \
    RENV_PROFILE=docker-${R_VERSION_SHORT}

RUN R -e "source('renv/activate.R'); renv::restore()"

EXPOSE 3838
CMD ["/srv/shiny-server/docker-shiny.sh"]
