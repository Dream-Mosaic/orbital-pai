#!/usr/bin/env bash
# Apply the Orbital brand to the Authentik default brand + the `orbital` application icon.
# Needs AUTHENTIK_API_KEY in the environment (repo-root .env). Uses curl on purpose:
# Cloudflare's browser check 403s non-browser POSTs (error 1010) from most other clients.
#
#   ./apply.sh            # upload images + CSS + titles + app icon
#   ./apply.sh --css-only # just CSS + titles
set -euo pipefail
cd "$(dirname "$0")"
: "${AUTHENTIK_API_KEY:?set AUTHENTIK_API_KEY}"
H="${AUTHENTIK_HOST:-https://auth.clausens.cloud}"
AUTH=(-H "Authorization: Bearer $AUTHENTIK_API_KEY")

# Images go into Authentik's own media store (POST /admin/file/, multipart) and the brand
# fields hold the BARE FILENAME; Authentik resolves it to a signed /files/media/public/...
# URL at render time. Note Cloudflare edge-caches those URLs: re-uploading under the same
# name keeps serving the old bytes for a while, so a changed image gets a new name.
IMG=../../../server/priv/static/images/brand
upload() { curl -sf "${AUTH[@]}" -X POST -F "file=@$IMG/$1" -F "name=$2" "$H/api/v3/admin/file/" -o /dev/null && echo "uploaded $2"; }

uuid=$(curl -sf "${AUTH[@]}" "$H/api/v3/core/brands/?default=true" | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["brand_uuid"])')
echo "brand $uuid"

if [[ ! -f brand-before.json ]]; then
  curl -sf "${AUTH[@]}" "$H/api/v3/core/brands/$uuid/" | python3 -m json.tool > brand-before.json
  echo "saved brand-before.json"
fi

if [[ "${1:-}" != "--css-only" ]]; then
  upload logo.png logo.png
  upload favicon-64.png favicon-64.png
  upload login-bg.jpg login-bg-wide.jpg
  upload icon-512.png icon-512.png
fi

python3 - "${1:-}" > /tmp/brand-patch.json <<'PY'
import json, sys
mode = sys.argv[1]
body = {"branding_title": "Orbital", "branding_custom_css": open("custom.css").read()}
if mode != "--css-only":
    body.update({
        "branding_logo": "logo.png",
        "branding_favicon": "favicon-64.png",
        "branding_default_flow_background": "login-bg-wide.jpg",
    })
json.dump(body, sys.stdout)
PY

curl -sf "${AUTH[@]}" -X PATCH -H "Content-Type: application/json" \
  --data-binary @/tmp/brand-patch.json "$H/api/v3/core/brands/$uuid/" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("title:",d["branding_title"]);print("logo:",d["branding_logo"]);print("css bytes:",len(d["branding_custom_css"]))'

if [[ "${1:-}" != "--css-only" ]]; then
  curl -sf "${AUTH[@]}" -X PATCH -H "Content-Type: application/json" \
    -d '{"meta_icon": "icon-512.png"}' "$H/api/v3/core/applications/orbital/" \
    | python3 -c 'import sys,json;print("app icon:",json.load(sys.stdin)["meta_icon"])'
fi

# The flow's own title is what the card says under the logo.
curl -sf "${AUTH[@]}" -X PATCH -H "Content-Type: application/json" -d '{"title":"Sign in to Orbital"}' \
  "$H/api/v3/flows/instances/default-authentication-flow/" >/dev/null && echo "flow title set"
rm -f /tmp/brand-patch.json
