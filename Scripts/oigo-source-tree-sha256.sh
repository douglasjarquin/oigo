#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

[[ $# -eq 1 && -d "$1" ]] || { print -u2 "ERROR invalid-source-root"; exit 64; }
root="$(cd "$1" && pwd -P)"
LC_ALL=C find "$root" \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r file; do
    relative="$(print -r -- "$file" | sed "s#^$root/##")"
    if [[ -L "$file" ]]; then
        print "$relative|symlink|$(readlink "$file")"
    else
        print "$relative|file|$(shasum -a 256 "$file" | awk '{print $1}')"
    fi
done | shasum -a 256 | awk '{print "sha256:" $1}'
