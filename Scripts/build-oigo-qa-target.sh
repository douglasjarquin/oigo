#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

output=""
bundle_id=""
field_id=""
while (( $# > 0 )); do
    case "$1" in
        --output|--bundle-id|--field-id)
            [[ $# -ge 2 ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
            value="$2"
            case "$1" in
                --output) output="$value" ;;
                --bundle-id) bundle_id="$value" ;;
                --field-id) field_id="$value" ;;
            esac
            shift 2
            ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
done
if [[ -z "$output" || -z "$bundle_id" || -z "$field_id" ]]; then
    print -u2 "ERROR missing-argument"
    exit 64
fi
if [[ "$output" != *.app || ! "$bundle_id" =~ '^[A-Za-z0-9.-]+$' || ! "$field_id" =~ '^[A-Za-z0-9._-]+$' ]]; then
    print -u2 "ERROR malformed-input"
    exit 64
fi
if [[ -e "$output" ]]; then
    print -u2 "ERROR output-exists"
    exit 1
fi

script_root="${0:A:h}"
mkdir -p "$output/Contents/MacOS"
/usr/bin/xcrun swiftc "$script_root/oigo-qa-target.swift" -framework AppKit -o "$output/Contents/MacOS/OigoQATarget"
cat > "$output/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OigoQATarget</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>Oigo QA Target</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>OigoQATargetFieldIdentifier</key><string>$field_id</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$output/Contents/Info.plist" >/dev/null
print "QA_TARGET_BUILT bundle=$bundle_id field=$field_id"
