#!/usr/bin/env bash
# Apply the Orbital brand to the Authentik default brand + the `orbital` application icon.
# Needs AUTHENTIK_API_KEY in the environment (repo-root .env). Uses curl on purpose:
# Cloudflare's browser check 403s non-browser POSTs (error 1010) from most other clients.
#
#   ./apply.sh            # CSS + title + logo/favicon/background URLs + app icon
#   ./apply.sh --css-only # just CSS + title (use before the PAI deploy that hosts the images)
set -euo pipefail
cd "$(dirname "$0")"
: "${AUTHENTIK_API_KEY:?set AUTHENTIK_API_KEY}"
H="${AUTHENTIK_HOST:-https://auth.clausens.cloud}"
ASSETS="${BRAND_ASSETS_BASE:-https://ai.clausens.cloud/images/brand}"
AUTH=(-H "Authorization: Bearer $AUTHENTIK_API_KEY")

uuid=$(curl -sf "${AUTH[@]}" "$H/api/v3/core/brands/?default=true" | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["brand_uuid"])')
echo "brand $uuid"

if [[ ! -f brand-before.json ]]; then
  curl -sf "${AUTH[@]}" "$H/api/v3/core/brands/$uuid/" | python3 -m json.tool > brand-before.json
  echo "saved brand-before.json"
fi

python3 - "$ASSETS" "${1:-}" > /tmp/brand-patch.json <<'PY'
import json, sys
assets, mode = sys.argv[1], sys.argv[2]
body = {"branding_title": "Orbital", "branding_custom_css": open("custom.css").read()}
if mode != "--css-only":
    body.update({
        "branding_logo": f"{assets}/logo.png",
        "branding_favicon": f"{assets}/favicon-64.png",
        "branding_default_flow_background": f"{assets}/login-bg.jpg",
    })
json.dump(body, sys.stdout)
PY

curl -sf "${AUTH[@]}" -X PATCH -H "Content-Type: application/json" \
  --data-binary @/tmp/brand-patch.json "$H/api/v3/core/brands/$uuid/" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("title:",d["branding_title"]);print("logo:",d["branding_logo"]);print("css bytes:",len(d["branding_custom_css"]))'

if [[ "${1:-}" != "--css-only" ]]; then
  # 2026.8 has no set_icon upload endpoint any more (it 404s); the icon is a URL.
  curl -sf "${AUTH[@]}" -X PATCH -H "Content-Type: application/json" \
    -d "{\"meta_icon\": \"$ASSETS/icon-512.png\"}" "$H/api/v3/core/applications/orbital/" \
    | python3 -c 'import sys,json;print("app icon:",json.load(sys.stdin)["meta_icon"])'
fi
# The flow's own title is what the card says under the logo.
curl -sf "${AUTH[@]}" -X PATCH -H "Content-Type: application/json" -d '{"title":"Sign in to Orbital"}' \
  "$H/api/v3/flows/instances/default-authentication-flow/" >/dev/null && echo "flow title set"
rm -f /tmp/brand-patch.json
