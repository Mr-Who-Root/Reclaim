# Sourced by build.sh and package.sh. Picks the code-signing identity for xcodebuild and sets SIGN_ARGS.
#
# macOS only lists a widget in the widget gallery when its extension is signed with a certificate that has a
# team (chronod drops ad-hoc signed widgets), so a real identity is used whenever this Mac has one:
#   1. RECLAIM_SIGN_IDENTITY, if set ("-" forces ad hoc)
#   2. a "Developer ID Application" certificate
#   3. an "Apple Development" certificate (free: Xcode › Settings › Accounts › your Apple ID › Manage Certificates)
# Otherwise the build is signed ad hoc, which runs fine but keeps the widget out of the gallery.

SIGN_ARGS=()
SIGN_NAME="${RECLAIM_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_NAME" ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for kind in "Developer ID Application" "Apple Development"; do
    SIGN_NAME=$(print -r -- "$identities" | /usr/bin/sed -nE "s/^ *[0-9]+\) [0-9A-F]{40} \"($kind: [^\"]+)\".*/\1/p" | head -1)
    [[ -n "$SIGN_NAME" ]] && break
  done
fi

if [[ -n "$SIGN_NAME" && "$SIGN_NAME" != "-" ]]; then
  # The team ID is the certificate's organizational unit.
  SIGN_TEAM=$(security find-certificate -c "$SIGN_NAME" -p 2>/dev/null \
    | /usr/bin/openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_NAME" DEVELOPMENT_TEAM="${SIGN_TEAM:-}")
  echo "Signing with: $SIGN_NAME${SIGN_TEAM:+ (team $SIGN_TEAM)}"
else
  echo "Signing ad hoc (no Apple Development or Developer ID certificate found; the widget won't appear in the widget gallery)"
fi
