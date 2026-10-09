# Download, checksum and merge the OpenStreetMap extracts Valhalla is built
# from. osmium writes an object present in two extracts once, which a
# cross-border ferry otherwise would not be.
FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install --yes --no-install-recommends ca-certificates curl osmium-tool \
  && rm -rf /var/lib/apt/lists/*
ENV HOME=/tmp
WORKDIR /work
