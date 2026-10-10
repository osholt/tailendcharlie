# Photon geocoder (https://github.com/komoot/photon), Apache-2.0.
# The jar is pinned by version and by the SHA-256 GitHub publishes for it.
FROM eclipse-temurin:21-jre

ARG PHOTON_VERSION=1.3.0
ARG PHOTON_SHA256=a89707c0045e4807b2a1180e132e68e108d998709f48b6c94b98a6e281f571a5

# curl and zstd are for the import, which streams a compressed dump straight
# into the indexer rather than storing it.
RUN apt-get update \
  && apt-get install --yes --no-install-recommends ca-certificates curl zstd \
  && rm -rf /var/lib/apt/lists/* \
  && curl --fail --location --silent --show-error \
    --output /opt/photon.jar \
    "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar" \
  && echo "${PHOTON_SHA256}  /opt/photon.jar" | sha256sum --check --strict -

# Compose runs this as the host's deploy user, so the index on disk belongs to
# the same account as everything else under ROUTING_DATA_DIR.
ENV HOME=/tmp
WORKDIR /photon
EXPOSE 2322
ENTRYPOINT ["java"]
