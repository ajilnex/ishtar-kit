#!/bin/zsh
# Compile et teste l'outil `ishtar` sous Linux, sur le serveur (iMac, Ubuntu,
# x86_64), dans le conteneur Swift (Dockerfile voisin : poppler et tesseract
# y remplacent PDFKit, QuickLook et Vision). Rien n'est installé sur le
# système ; 2 cœurs et 2 Go au plus : les services du serveur passent avant.
# Usage : Scripts/linux/construire.sh [build|release|test] [arguments de swift…]
# « release » : l'outil optimisé de l'atelier des fonds confiés (installé par
# Rayons, deploy/atelier-installer.sh) — l'empreinte en Swift pur y est
# des dizaines de fois plus rapide qu'en « build ».
set -euo pipefail
cd "${0:A:h}/../.."
HOST=pyrosarx@100.111.201.93
ACTION=${1:-build}
shift $(( $# > 0 ? 1 : 0 ))
case $ACTION in
  build) COMMANDE="swift build --product ishtar" ;;
  release) COMMANDE="swift build -c release --product ishtar" ;;
  test) COMMANDE="swift test" ;;
  *) echo "Usage : construire.sh [build|release|test] [arguments de swift…]" >&2; exit 64 ;;
esac
rsync -rt --delete --exclude .build --exclude .swiftpm --exclude .DS_Store --exclude .git ./ "${HOST}:ishtar-kit/"
ssh "${HOST}" "cd ~/ishtar-kit && docker build -q -t ishtar-linux Scripts/linux >/dev/null && \
  docker run --rm --memory=2g --memory-swap=3g --cpus=2 -v ~/ishtar-kit:/src -v ishtar-swiftpm:/root/.cache ishtar-linux \
  ${COMMANDE} -j 2 ${(q)@}"
