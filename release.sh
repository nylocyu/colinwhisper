#!/bin/bash
# Publishes a new version: ./release.sh 1.1 "Was ist neu (optional)"
# Builds, signs with Developer ID, notarizes, signs the update for Sparkle and
# uploads zip + appcast.xml as a GitHub release. Installed apps pick it up from there.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Version angeben, z. B. ./release.sh 1.1}"
NOTES="${2:-}"
REPO="nylocyu/colinwhisper"
NOTARY_PROFILE="ColinWhisper"  # created once with: xcrun notarytool store-credentials ColinWhisper
TEAM=$(sed -nE 's/^ *DEVELOPMENT_TEAM: *//p' project.yml)
OUT="build/release"
ZIP="ColinWhisper-$VERSION.zip"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

[[ -z "$(git status --porcelain)" ]] || { echo "Es gibt uncommittete Änderungen – erst committen."; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "Kein „Developer ID Application“-Zertifikat im Schlüsselbund (Xcode → Einstellungen → Accounts → Zertifikate verwalten)."; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "v$VERSION gibt es schon."; exit 1; }

sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
xcodegen generate

rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild -project ColinWhisper.xcodeproj -scheme ColinWhisper -configuration Release \
  -derivedDataPath build/DerivedData -archivePath "$OUT/ColinWhisper.xcarchive" archive
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF
# Export re-signs the app and Sparkle's helpers with Developer ID + secure timestamp.
xcodebuild -exportArchive -archivePath "$OUT/ColinWhisper.xcarchive" -exportPath "$OUT" -exportOptionsPlist "$OUT/ExportOptions.plist"

ditto -c -k --keepParent "$OUT/ColinWhisper.app" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT/ColinWhisper.app"
spctl -a -vv "$OUT/ColinWhisper.app"

ditto -c -k --keepParent "$OUT/ColinWhisper.app" "$OUT/$ZIP"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$OUT/$ZIP")  # sparkle:edSignature="…" length="…"
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ColinWhisper</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      ${NOTES:+<description><![CDATA[$NOTES]]></description>}
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$ZIP" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

git commit -am "Release $VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" "$OUT/$ZIP" "$OUT/appcast.xml" -R "$REPO" \
  --title "ColinWhisper $VERSION" --notes "${NOTES:-Version $VERSION}"
echo "Fertig: https://github.com/$REPO/releases/tag/v$VERSION"
