#!/usr/bin/env bash
#
# Store one charging-feed credential in the collector's private env file on the
# relay host, without the value ever appearing in a command line, shell history,
# terminal output, log or the repository.
#
#   deploy/charging/put-credential.sh [--clipboard] [--recreate] VARIABLE
#
# The value is read from a hidden prompt (or, with --clipboard, from the macOS
# clipboard, which is then cleared) and sent over SSH on stdin. The host side
# rewrites the env file atomically with mode 0600 and reports only the variable
# name and whether it was added or replaced. VARIABLE must be a credential name
# declared in tools/charging/feeds.toml, so a typo cannot create a stray entry.
#
# --recreate restarts only the `charging` service afterwards, explicitly loading
# the production env file, so the collector picks up the new value. Docker reads
# env_file only when a container is created; without --recreate the change takes
# effect at the next deploy.
#
# Optional environment:
#   CHARGING_SSH_HOST  SSH alias of the relay host (default: oracle-relay)
#   CHARGING_ENV_PATH  env file on the host (default: ~/.config/tailendcharlie/charging.env)

set -euo pipefail

host="${CHARGING_SSH_HOST:-oracle-relay}"
env_path="${CHARGING_ENV_PATH:-.config/tailendcharlie/charging.env}"
register="$(cd "$(dirname "$0")/../.." && pwd)/tools/charging/feeds.toml"

clipboard=0
recreate=0
name=""
for arg in "$@"; do
  case "$arg" in
  --clipboard) clipboard=1 ;;
  --recreate) recreate=1 ;;
  -h | --help)
    sed -n '3,22p' "$0"
    exit 0
    ;;
  -*)
    echo "put-credential: unknown option $arg" >&2
    exit 2
    ;;
  *) name="$arg" ;;
  esac
done

if ! [[ "$env_path" =~ ^[A-Za-z0-9_./~-]+$ ]]; then
  echo "put-credential: CHARGING_ENV_PATH contains unsupported characters" >&2
  exit 2
fi
if ! [[ "$name" =~ ^OCPI_FEED_[A-Z0-9_]+$ ]]; then
  echo "put-credential: VARIABLE must look like OCPI_FEED_<ID>_<KIND>" >&2
  exit 2
fi
if ! grep -Eq "^(credential_env|api_key_env) = \"$name\"$" "$register"; then
  echo "put-credential: $name is not declared in tools/charging/feeds.toml" >&2
  exit 2
fi

if test "$clipboard" = 1; then
  value="$(pbpaste)"
  # Leave nothing behind for the next paste.
  pbcopy </dev/null
else
  IFS= read -r -s -p "Value for $name (input hidden): " value
  echo >&2
fi
# Trim surrounding whitespace that copy-paste from email tends to add.
value="${value#"${value%%[![:space:]]*}"}"
value="${value%"${value##*[![:space:]]}"}"
if test -z "$value"; then
  echo "put-credential: empty value; nothing changed" >&2
  exit 1
fi
if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
  echo "put-credential: value contains a line break; nothing changed" >&2
  exit 1
fi
if [[ "$name" == *_BASIC && "$value" != *:* ]]; then
  echo "put-credential: $name must be username:password; nothing changed" >&2
  exit 1
fi

# The host program travels as an argument (it holds no secret); the value
# travels on stdin only.
read -r -d '' remote_program <<'PY' || true
import os, sys, tempfile
name, path = sys.argv[1], os.path.expanduser(sys.argv[2])
value = sys.stdin.read()
if not value or "\n" in value or "\r" in value:
    sys.exit("put-credential: rejected value")
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
lines, action = [], "added"
if os.path.exists(path):
    with open(path) as f:
        for line in f.read().splitlines():
            if line.split("=", 1)[0].strip() == name:
                action = "replaced"
                continue
            lines.append(line)
lines.append(f"{name}={value}")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".charging.env.")
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"put-credential: {action} {name}")
PY

# Base64 keeps the program intact through whatever login shell the host runs;
# the name and path are already restricted to shell-safe characters.
program_b64="$(printf '%s' "$remote_program" | base64 | tr -d '\n')"
printf '%s' "$value" | ssh -o BatchMode=yes "$host" \
  "python3 -c 'import base64; exec(base64.b64decode(\"$program_b64\"))' $name $env_path"
unset value

if test "$recreate" = 1; then
  # Same project, env file and override files as relay-deploy.sh; only the
  # collector is recreated, from the image already built for this commit.
  ssh -o BatchMode=yes "$host" 'set -e
    test -r /etc/relay-deploy.conf && . /etc/relay-deploy.conf
    cd "${RELAY_DEPLOY_REPO:-/opt/tailendcharlie}"
    files="--file deploy/compose.yaml"
    for o in ${RELAY_DEPLOY_PRODUCTION_OVERRIDES:-}; do files="$files --file deploy/$o"; done
    docker compose --env-file deploy/.env $files up -d --no-deps --no-build --force-recreate charging >/dev/null 2>&1
    echo "put-credential: recreated charging"'
fi
