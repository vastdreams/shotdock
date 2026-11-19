#!/bin/zsh
# Regenerate docs/images from made-up demo data. Renders off-screen: nothing appears on your screen and no real
# chats are read (HOME, Claude's folder and ShotDock's profile all point at the demo folder).
set -e
cd "${0:A:h}/.."
DEMO=${DEMO:-/Users/Shared/shotdock-demo}
python3 scripts/demo-data.py "$DEMO" >/dev/null
npm run build >/dev/null
env -u ELECTRON_RUN_AS_NODE -u CLAUDE_CODE_ENTRYPOINT HOME="$DEMO" CLAUDE_CONFIG_DIR="$DEMO/.claude" SHOTDOCK_PROFILE_DIR="$DEMO/profile" \
  ./node_modules/.bin/electron . --dev --screenshots="$PWD/../docs/images" --ids="$DEMO/ids.json"
echo "Updated: docs/images"
