#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

manifest_out=""
if [[ $# -ge 2 && "$1" == "--manifest-out" ]]; then
    manifest_out="$2"
    shift 2
fi
if [[ $# -ne 1 ]]; then
    print -u2 "usage: $0 [--manifest-out <path>] <Oigo.app>"
    exit 64
fi

app="${1%/}"
if [[ ! -d "$app" ]]; then
    print -u2 "ERROR missing-bundle"
    exit 1
fi
app="$(cd "$app" && pwd -P)"
if [[ "${app:t}" != "Oigo.app" ]]; then
    print -u2 "ERROR wrong-bundle-name"
    exit 1
fi

scratch="$(mktemp -d "${app:h}/.oigo-bundle-digest.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT INT TERM
manifest="$scratch/manifest"

while IFS= read -r -d '' entry; do
    relative="${entry#./}"
    entry_path="$app/$relative"
    if [[ "$relative" == *$'\n'* || "$relative" == *$'\t'* ]]; then
        print -u2 "ERROR unsupported-entry-name"
        exit 1
    fi
    mode="$(stat -f '%Lp' "$entry_path")"
    if [[ -L "$entry_path" ]]; then
        target="$(readlink "$entry_path")"
        if [[ "$target" == /* ]]; then
            print -u2 "ERROR absolute-symlink"
            exit 1
        fi
        if ! resolved="$(realpath "$entry_path" 2>/dev/null)"; then
            print -u2 "ERROR dangling-symlink"
            exit 1
        fi
        if [[ "$resolved" != "$app" && "$resolved" != "$app"/* ]]; then
            print -u2 "ERROR bundle-escaping-symlink"
            exit 1
        fi
        printf 'symlink\t%s\t%s\t%s\n' "$mode" "$relative" "$target" >> "$manifest"
    elif [[ -f "$entry_path" ]]; then
        digest="$(shasum -a 256 "$entry_path" | awk '{print $1}')"
        printf 'file\t%s\t%s\t%s\n' "$mode" "$relative" "$digest" >> "$manifest"
    elif [[ -d "$entry_path" ]]; then
        printf 'directory\t%s\t%s\t-\n' "$mode" "$relative" >> "$manifest"
    else
        print -u2 "ERROR unsupported-entry-type"
        exit 1
    fi
done < <(cd "$app" && find . -mindepth 1 -print0 | sort -z)

if [[ -n "$manifest_out" ]]; then
    mkdir -p "${manifest_out:h}"
    cp "$manifest" "$manifest_out"
fi
print "APP_BUNDLE_SHA=sha256:$(shasum -a 256 "$manifest" | awk '{print $1}')"
