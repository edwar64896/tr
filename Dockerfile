# Talyllyn Railway Archive — catalogue viewer (proof of concept)
#
# A tiny static site served by nginx. The catalogue.json is generated from the
# MODES XML export at build time so the image is fully self-contained: hand the
# image (or a `docker run`) to anyone and it works offline, no backend needed.
#
#   docker build -t tr-archive .
#   docker run --rm -p 8080:80 tr-archive
#   open http://localhost:8080

# ---- Stage 1: generate catalogue.json from the XML export --------------------
FROM python:3.12-slim AS build
WORKDIR /src
COPY tools/build_catalogue.py tools/
COPY data/ data/
# Produce the JSON the web app consumes.
RUN python3 tools/build_catalogue.py data/tr.xml --out /out/catalogue.json

# ---- Stage 2: static web server ---------------------------------------------
FROM nginx:1.27-alpine
COPY web/ /usr/share/nginx/html/
COPY --from=build /out/catalogue.json /usr/share/nginx/html/catalogue.json
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
# Optional: drop scanned JPEGs into ./scans and they are served at /scans/…
#   (set IMAGE_BASE = "/scans/" in web/index.html to display them)
EXPOSE 80
HEALTHCHECK CMD wget -qO- http://localhost/ >/dev/null || exit 1
