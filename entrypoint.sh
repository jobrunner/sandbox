#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/init-firewall.sh

# Zu "dev" wechseln, alle Capabilities verwerfen, keine Rechteausweitung mehr.
# Der Agent kann die Firewall danach nicht mehr ändern.
exec setpriv --reuid=dev --regid=dev --init-groups \
     --inh-caps=-all --bounding-set=-all --no-new-privs -- "$@"
