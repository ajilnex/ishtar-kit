#!/bin/zsh
# `swift test` qui marche aussi sans Xcode.
#
# Avec les seuls Command Line Tools, le module Testing est livré hors des
# chemins par défaut du compilateur : il faut les lui donner, à la compilation
# comme à l'édition des liens. Avec Xcode, rien à ajouter.
set -e
cd "${0:A:h}/.."

DEV=$(xcode-select -p)
if [[ "$DEV" == *CommandLineTools* ]]; then
  F="$DEV/Library/Developer/Frameworks"
  L="$DEV/Library/Developer/usr/lib"
  exec swift test \
    -Xswiftc -F -Xswiftc "$F" \
    -Xlinker -F -Xlinker "$F" \
    -Xlinker -rpath -Xlinker "$F" \
    -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
