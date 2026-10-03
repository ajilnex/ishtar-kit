# Ishtar sous Linux (refonte « tout sur le serveur », 25/09) : l'outil
# `ishtar` compilé et exécuté sur le serveur, avec les outils qui remplacent
# PDFKit / Vision / QuickLook (poppler, ImageMagick, tesseract).
FROM swift:6.3-jammy
RUN apt-get update && apt-get install -y --no-install-recommends \
      libsqlite3-dev poppler-utils imagemagick tesseract-ocr tesseract-ocr-fra tesseract-ocr-eng \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
