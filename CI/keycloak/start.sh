#!/usr/bin/env bash
#
# Starts a throwaway Keycloak with the flight-test realm, for the OIDC
# sign-in integration tests:
#
#   ./CI/keycloak/start.sh            # prints the URL to export
#   export FLIGHT_TEST_KEYCLOAK_URL=http://localhost:8089
#   swift test --enable-all-traits --filter KeycloakSignIn
#   docker rm -f flight-test-keycloak
#
# The realm (CI/keycloak/flight-test-realm.json) holds one confidential
# client with PKCE required, one user (ada / "correct horse") with a verified
# email and an `author` realm role mapped into the ID token as `roles`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
port="${FLIGHT_TEST_KEYCLOAK_PORT:-8089}"
image="${FLIGHT_TEST_KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.3}"

docker rm -f flight-test-keycloak >/dev/null 2>&1 || true
docker run -d --name flight-test-keycloak -p "$port:8080" \
  -v "$here:/opt/keycloak/data/import:ro" \
  "$image" start-dev --import-realm >/dev/null

# Ready when the realm's discovery document answers.
for _ in $(seq 1 90); do
  if curl -sf "http://localhost:$port/realms/flight-test/.well-known/openid-configuration" >/dev/null; then
    echo "FLIGHT_TEST_KEYCLOAK_URL=http://localhost:$port"
    exit 0
  fi
  sleep 2
done
echo "::error::Keycloak did not become ready" >&2
docker logs flight-test-keycloak 2>&1 | tail -40 >&2
exit 1
