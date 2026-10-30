#!/usr/bin/env bash
# Build the static site and publish it to hetzner-1, where Caddy serves it as www.franciscoutrera.com.
# Usage: scripts/deploy.sh            (requires an ssh host alias "hetzner-1" in ~/.ssh/config)
set -euo pipefail
cd "$(dirname "$0")/.."
yarn build
npx next export
# The tags page is a dynamic route; Caddy rewrites /tags/* to this file and the page reads the tag client-side.
cp 'out/tags/[tag].html' out/tags/_tag.html
rsync -az --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r out/ hetzner-1:/srv/www/franciscoutrera.com/
echo "deployed $(find out -type f | wc -l | tr -d ' ') files"
