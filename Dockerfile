# syntax=docker/dockerfile:1
# https://github.com/moby/buildkit/blob/master/frontend/dockerfile/docs/reference.md

# Stage: compile-frontend
# Purpose: Compiles the frontend
# Notes:
#  - Does NPM stuff with Typescript and such
FROM --platform=$BUILDPLATFORM docker.io/node:20-bookworm-slim AS compile-frontend

COPY ./src-ui /src/src-ui

WORKDIR /src/src-ui
RUN set -eux \
  && npm update npm -g \
  && npm ci --omit=optional
RUN set -eux \
  && ./node_modules/.bin/ng build --configuration production

# Stage: pipenv-base
# Purpose: Generates a requirements.txt file for building
# Comments:
#  - pipenv dependencies are not left in the final image
#  - pipenv can't touch the final image somehow
FROM --platform=$BUILDPLATFORM docker.io/python:3.11-alpine as pipenv-base

WORKDIR /usr/src/pipenv

COPY Pipfile* ./

RUN set -eux \
  && echo "Installing pipenv" \
    && python3 -m pip install --no-cache-dir --upgrade pipenv==2023.9.8 \
  && echo "Generating requirement.txt" \
    && pipenv requirements > requirements.txt

# Stage: s6-overlay-base
# Purpose: Installs s6-overlay and rootfs
# Comments:
#  - Don't leave anything extra in here either
FROM docker.io/python:3.11-slim-bookworm as s6-overlay-base

WORKDIR /usr/src/s6

# https://github.com/just-containers/s6-overlay#customizing-s6-overlay-behaviour
ENV \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_VERBOSITY=1 \
    PATH=/command:$PATH

# Buildx provided, must be defined to use though
ARG TARGETARCH
ARG TARGETVARIANT
# Lock this version
ARG S6_OVERLAY_VERSION=3.1.6.0

# Lock these are well to prevent rebuilds as much as possible
ARG S6_BUILD_TIME_PKGS="curl \
                        xz-utils"

RUN set -eux \
    && echo "Installing build time packages" \
      && apt-get update \
      && apt-get install --yes --quiet --no-install-recommends ${S6_BUILD_TIME_PKGS} \
    && echo "Determining arch" \
      && S6_ARCH="" \
      && if [ "${TARGETARCH}${TARGETVARIANT}" = "amd64" ]; then S6_ARCH="x86_64"; \
      elif [ "${TARGETARCH}${TARGETVARIANT}" = "arm64" ]; then S6_ARCH="aarch64"; fi\
      && if [ -z "${S6_ARCH}" ]; then { echo "Error: Not able to determine arch"; exit 1; }; fi \
    && echo "Installing s6-overlay for ${S6_ARCH}" \
      && curl --fail --silent --show-error -L --output s6-overlay-noarch.tar.xz --location \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
      && curl --fail --silent --show-error -L --output s6-overlay-noarch.tar.xz.sha256 \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz.sha256" \
      && curl --fail --silent --show-error -L --output s6-overlay-${S6_ARCH}.tar.xz --location \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
      && curl --fail --silent --show-error -L --output s6-overlay-${S6_ARCH}.tar.xz.sha256 \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz.sha256" \
      && echo "Validating s6-archive checksums" \
        && sha256sum -c ./*.sha256 \
      && echo "Unpacking archives" \
        && tar -C / -Jxpf s6-overlay-noarch.tar.xz \
        && tar -C / -Jxpf s6-overlay-${S6_ARCH}.tar.xz \
      && echo "Removing downloaded archives" \
        && rm ./*.tar.xz \
        && rm ./*.sha256 \
    && echo "Cleaning up image" \
      && apt-get -y purge ${S6_BUILD_TIME_PKGS} \
      && apt-get -y autoremove --purge \
      && rm -rf /var/lib/apt/lists/*

# Copy our service defs and filesystem
#COPY ./docker/rootfs /

# Stage: main-app
# Purpose: The final image
# Comments:
#  - Don't leave anything extra in here
FROM s6-overlay-base as main-app

LABEL org.opencontainers.image.authors="paperless-ngx team <hello@paperless-ngx.com>"
LABEL org.opencontainers.image.documentation="https://docs.paperless-ngx.com/"
LABEL org.opencontainers.image.source="https://github.com/paperless-ngx/paperless-ngx"
LABEL org.opencontainers.image.url="https://github.com/paperless-ngx/paperless-ngx"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

ARG DEBIAN_FRONTEND=noninteractive

# Buildx provided, must be defined to use though
ARG TARGETARCH

# Can be workflow provided, defaults set for manual building
ARG JBIG2ENC_VERSION=0.29
ARG QPDF_VERSION=11.6.1
ARG GS_VERSION=10.02.0

#
# Begin installation and configuration
# Order the steps below from least often changed to most
#

# Packages need for running
ARG RUNTIME_PACKAGES="\
  # General utils
  curl \
  # Docker specific
  gosu \
  # Timezones support
  tzdata \
  # fonts for text file thumbnail generation
  fonts-liberation \
  gettext \
  ghostscript \
  gnupg \
  icc-profiles-free \
  imagemagick \
  # PostgreSQL
  libpq5 \
  postgresql-client \
  # MySQL / MariaDB
  mariadb-client \
  # OCRmyPDF dependencies
  tesseract-ocr \
  tesseract-ocr-eng \
  tesseract-ocr-deu \
  tesseract-ocr-fra \
  tesseract-ocr-ita \
  tesseract-ocr-spa \
  unpaper \
  pngquant \
  jbig2dec \
  # lxml
  libxml2 \
  libxslt1.1 \
  # itself
  qpdf \
  # Mime type detection
  file \
  libmagic1 \
  media-types \
  zlib1g \
  # Barcode splitter
  libzbar0 \
  poppler-utils"

# Install basic runtime packages.
# These change very infrequently
RUN set -eux \
  echo "Installing system packages" \
    && apt-get update \
    && apt-get install --yes --quiet --no-install-recommends ${RUNTIME_PACKAGES} \
    && echo "Installing pre-built updates" \
      && echo "Installing qpdf ${QPDF_VERSION}" \
        && curl --fail --silent --show-error --output libqpdf29_${QPDF_VERSION}-1_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/libqpdf29_${QPDF_VERSION}-1_${TARGETARCH}.deb \
        && curl --fail --silent --show-error --output qpdf_${QPDF_VERSION}-1_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/qpdf_${QPDF_VERSION}-1_${TARGETARCH}.deb \
        && dpkg --install ./libqpdf29_${QPDF_VERSION}-1_${TARGETARCH}.deb \
        && dpkg --install ./qpdf_${QPDF_VERSION}-1_${TARGETARCH}.deb \
      && echo "Installing Ghostscript ${GS_VERSION}" \
        && curl --fail --silent --show-error --output libgs10_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/libgs10_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb \
        && curl --fail --silent --show-error --output ghostscript_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/ghostscript_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb \
        && curl --fail --silent --show-error --output libgs10-common_${GS_VERSION}.dfsg-2_all.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/libgs10-common_${GS_VERSION}.dfsg-2_all.deb \
        && dpkg --install ./libgs10-common_${GS_VERSION}.dfsg-2_all.deb \
        && dpkg --install ./libgs10_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb \
        && dpkg --install ./ghostscript_${GS_VERSION}.dfsg-2_${TARGETARCH}.deb \
      && echo "Installing jbig2enc" \
        && curl --fail --silent --show-error --output jbig2enc_${JBIG2ENC_VERSION}-1_${TARGETARCH}.deb --location https://github.com/paperless-ngx/builder/releases/download/v0.0.0/jbig2enc_${JBIG2ENC_VERSION}-1_${TARGETARCH}.deb \
        && dpkg --install ./jbig2enc_${JBIG2ENC_VERSION}-1_${TARGETARCH}.deb \
      && echo "Cleaning up image layer" \
        && rm --force --verbose *.deb \
    && rm --recursive --force --verbose /var/lib/apt/lists/*

# Copy gunicorn config
# Changes very infrequently
WORKDIR /usr/src/paperless/

COPY --chown=1000:1000 gunicorn.conf.py /usr/src/paperless/gunicorn.conf.py

# setup docker-specific things
# These change sometimes, but rarely
WORKDIR /usr/src/paperless/docker/

COPY --chown=1000:1000 [ \
  "docker/management_script.sh", \
  "docker/install_management_commands.sh", \
  "/usr/src/paperless/docker/" \
]

RUN set -eux \
  && echo "Installing managment commands" \
    && chmod +x install_management_commands.sh \
    && ./install_management_commands.sh

WORKDIR /usr/src/paperless/src/

# Python dependencies
# Change pretty frequently
COPY --chown=1000:1000 --from=pipenv-base /usr/src/pipenv/requirements.txt ./

# Packages needed only for building a few quick Python
# dependencies
ARG BUILD_PACKAGES="\
  build-essential \
  git \
  # https://www.psycopg.org/docs/install.html#prerequisites
  libpq-dev \
  # https://github.com/PyMySQL/mysqlclient#linux
  default-libmysqlclient-dev \
  pkg-config"

# hadolint ignore=DL3042
RUN --mount=type=cache,target=/root/.cache/pip/,id=pip-cache \
  set -eux \
  && echo "Installing build system packages" \
    && apt-get update \
    && apt-get install --yes --quiet --no-install-recommends ${BUILD_PACKAGES} \
    && python3 -m pip install --upgrade wheel \
  && echo "Installing Python requirements" \
    && python3 -m pip install --default-timeout=1000 --requirement requirements.txt \
  && echo "Patching whitenoise for compression speedup" \
    && curl --fail --silent --show-error --location --output 484.patch https://github.com/evansd/whitenoise/pull/484.patch \
    && patch -d /usr/local/lib/python3.11/site-packages --verbose -p2 < 484.patch \
    && rm 484.patch \
  && echo "Installing NLTK data" \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" snowball_data \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" stopwords \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" punkt \
  && echo "Cleaning up image" \
    && apt-get --yes purge ${BUILD_PACKAGES} \
    && apt-get --yes autoremove --purge \
    && apt-get clean --yes \
    && rm --recursive --force --verbose /var/lib/apt/lists/* \
    && rm --recursive --force --verbose /tmp/* \
    && rm --recursive --force --verbose /var/tmp/* \
    && rm --recursive --force --verbose /var/cache/apt/archives/* \
    && truncate --size 0 /var/log/*log

# copy backend
COPY --chown=1000:1000 ./src ./

# copy frontend
COPY --from=compile-frontend --chown=1000:1000 /src/src/documents/static/frontend/ ./documents/static/frontend/

# add users, setup scripts
# Mount the compiled frontend to expected location
RUN set -eux \
  && echo "Setting up user/group" \
    && addgroup --gid 1000 paperless \
    && useradd --uid 1000 --gid paperless --home-dir /usr/src/paperless paperless \
  && echo "Creating volume directories" \
    && mkdir --parents --verbose /usr/src/paperless/data \
    && mkdir --parents --verbose /usr/src/paperless/media \
    && mkdir --parents --verbose /usr/src/paperless/consume \
    && mkdir --parents --verbose /usr/src/paperless/export \
  && echo "Adjusting all permissions" \
    && chown --from root:root --changes --recursive paperless:paperless /usr/src/paperless \
  && echo "Collecting static files" \
    && gosu paperless python3 manage.py collectstatic --clear --no-input --link \
    && gosu paperless python3 manage.py compilemessages

VOLUME ["/usr/src/paperless/data", \
        "/usr/src/paperless/media", \
        "/usr/src/paperless/consume", \
        "/usr/src/paperless/export"]

ENTRYPOINT ["/init"]

EXPOSE 8000

COPY ./docker/rootfs /
