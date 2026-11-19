#!/usr/bin/env bash
# Starts the image for real and checks what it promises. GitHub Actions runs
# this before publishing; it runs the same on the Mac.
#
#   Usage: bash test/smoke.sh IMAGE FOLDER_FOR_LOGS_AND_THE_SCREENSHOT
#
# Part 1, a plain "docker run":
#   - the desktop comes up, and the web page answers and passes VNC through
#   - VNC asks for no password, and the screen shows a drawn desktop
#   - SSH works with a key, as "desktop", with sudo, and can open a window
#   - SSH refuses a password
#   - "seat add" gives a second screen with its own window manager, listed on
#     the web page and reachable through it
# Part 2, the machine on a volume (how the cluster runs it):
#   - seed-machine fills the volume
#   - a package installed with apt, a file in /etc and the SSH host key are
#     all still there in a brand-new container on the same volume
#   - a seat added in the first container comes back by itself in the second
#
# It makes its own throwaway SSH key and volume. Containers are stopped and
# left, with the volume, for looking at afterwards; their names are printed.
set -Eeuo pipefail
image=${1:?Usage: test/smoke.sh IMAGE FOLDER_FOR_LOGS}
artifacts=${2:?A folder for logs and the screenshot is needed}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$artifacts"
work=$(mktemp -d /tmp/job-desktop-smoke.XXXXXX)
ssh-keygen -q -t ed25519 -N '' -f "$work/id_ed25519"
chmod 0644 "$work/id_ed25519.pub"
name="job-desktop-smoke-${GITHUB_RUN_ID:-local}-$$"
ssh_port=${SSH_TEST_PORT:-12222}
http_port=${HTTP_TEST_PORT:-16080}
ssh_args=(-i "$work/id_ed25519" -p "$ssh_port" -o BatchMode=yes -o IdentitiesOnly=yes
    -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work/known_hosts")

containers=()
finish() {
    local status=$?
    trap - EXIT
    for container in "${containers[@]}"; do
        docker logs "$container" > "$artifacts/$container.log" 2>&1 || true
        docker stop -t 20 "$container" >/dev/null 2>&1 || true
    done
    echo "Left behind: containers ${containers[*]:-none}, volume $name-machine, folder $work"
    exit "$status"
}
trap finish EXIT

wait_until_up() {
    for ((attempt=0; attempt<120; attempt++)); do
        [[ $(docker inspect --format '{{.State.Status}}' "$1") == running ]] || { docker logs "$1"; return 1; }
        docker exec "$1" /desktop/healthcheck >/dev/null 2>&1 && return 0
        sleep 2
    done
    docker exec "$1" /desktop/healthcheck
}

echo '--- Part 1: plain docker run'
docker run -d --name "$name" --shm-size=1g \
    -p "127.0.0.1:$http_port:6080" -p "127.0.0.1:$ssh_port:22" \
    --mount "type=bind,source=$work/id_ed25519.pub,target=/run/ssh-keys/authorized_keys,readonly" \
    "$image" >/dev/null
containers+=("$name")
wait_until_up "$name"

# The bare address sends the browser straight to the desktop.
curl --fail --silent "http://127.0.0.1:$http_port/" | grep -F 'vnc.html?autoconnect=1' >/dev/null
curl --fail --silent "http://127.0.0.1:$http_port/vnc.html" | grep -i novnc >/dev/null
# The page reaches the screen over a WebSocket; check that the upgrade is accepted.
HTTP_TEST_PORT="$http_port" python3 - <<'PY'
import os
import socket
with socket.create_connection(('127.0.0.1', int(os.environ['HTTP_TEST_PORT'])), timeout=10) as sock:
    sock.sendall(b'GET /websockify?token=management HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n')
    reply = sock.recv(4096)
    assert b'101 Switching Protocols' in reply, reply.split(b'\r\n')[0]
print('The web page can reach the screen.')
PY

# Real SSH, and a window opened from it: this is how an agent would start a program.
ssh "${ssh_args[@]}" desktop@127.0.0.1 'set -eu
    test "$(id -u)" = 1000
    test "$HOME" = /home/desktop
    sudo -n true
    test "$(locale charmap)" = UTF-8
    xdpyinfo >/dev/null
    . /etc/profile.d/desktop.sh
    nohup gnome-terminal --title="job-desktop smoke test" -- bash -c "cat /etc/os-release; sleep 600" >/dev/null 2>&1 &
' > "$artifacts/ssh.log" 2>&1
if ssh "${ssh_args[@]}" -o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=0 desktop@127.0.0.1 true 2>/dev/null; then
    echo 'SSH let a login in without a key.' >&2
    exit 1
fi
window_up=false
for ((attempt=0; attempt<30; attempt++)); do
    if docker exec "$name" bash -c 'for window in $(xprop -root _NET_CLIENT_LIST | grep -oE "0x[[:xdigit:]]+"); do
            xprop -id "$window" _NET_WM_NAME | grep -F "job-desktop smoke test" >/dev/null && exit 0
        done; exit 1'; then
        window_up=true
        break
    fi
    sleep 2
done
[[ $window_up == true ]] || { echo 'The terminal window never appeared.' >&2; exit 1; }
sleep 3
docker exec -i "$name" python3 - < "$here/vnc_probe.py"
docker cp "$name:/tmp/desktop-screen.png" "$artifacts/desktop-screen.png" >/dev/null
# A seat: a second screen for an agent. cua-driver is not in the image, so only
# the screen, its window manager and the web page's route to it are checked.
docker exec --user 1000:1000 "$name" seat add demo
docker exec --user 1000:1000 "$name" bash -c '
    xdpyinfo -display :2 >/dev/null
    for attempt in $(seq 1 20); do pgrep -u 1000 -x openbox >/dev/null && break; sleep 1; done
    pgrep -u 1000 -x openbox >/dev/null
    test "$(seat run demo -- printenv DISPLAY)" = :2
    seat list | grep -E "^demo +:2 +yes"
'
curl --fail --silent "http://127.0.0.1:$http_port/" | grep -F 'token%3Ddemo' >/dev/null
HTTP_TEST_PORT="$http_port" python3 - <<'PY'
import os
import socket
def greeting(token):
    with socket.create_connection(('127.0.0.1', int(os.environ['HTTP_TEST_PORT'])), timeout=10) as sock:
        sock.sendall(('GET /websockify?token=%s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n' % token).encode())
        sock.settimeout(5)
        data = b''
        try:
            while b'RFB' not in data and len(data) < 600:
                part = sock.recv(4096)
                if not part:
                    break
                data += part
        except OSError:
            pass
        return data
assert b'RFB 003' in greeting('demo'), 'the web page cannot reach the seat'
assert b'101' not in greeting('no-such-screen'), 'an unknown screen name was let through'
print('The web page reaches the seat by name, and refuses a name it does not know.')
PY
# No host key may be baked into the image; each machine makes its own.
docker run --rm --entrypoint bash "$image" -c 'test -z "$(find /etc/ssh -maxdepth 1 -name "ssh_host_*" -print)"'
docker stop -t 20 "$name" >/dev/null

echo '--- Part 2: the machine on a volume'
volume="$name-machine"
docker volume create "$volume" >/dev/null
docker run --rm --entrypoint /desktop/seed-machine --mount "type=volume,source=$volume,target=/machine" "$image" /machine
mounts=()
for dir in etc usr var opt home root srv; do
    mounts+=(--mount "type=volume,source=$volume,target=/$dir,volume-subpath=$dir")
done
run_on_volume() {
    docker run -d --name "$1" --shm-size=1g "${mounts[@]}" \
        --mount "type=bind,source=$work/id_ed25519.pub,target=/run/ssh-keys/authorized_keys,readonly" \
        "$image" >/dev/null
    containers+=("$1")
    wait_until_up "$1"
}
run_on_volume "$name-first"
# Install something small the way I would, and change a file in /etc.
docker exec "$name-first" bash -c 'apt-get update -qq && apt-get install -y -qq sl >/dev/null && echo kept > /etc/smoke-test-marker'
docker exec --user 1000:1000 "$name-first" bash -c 'echo kept > "$HOME/smoke-test-marker"'
docker exec --user 1000:1000 "$name-first" seat add demo
host_key=$(docker exec "$name-first" cat /etc/ssh/ssh_host_ed25519_key.pub)
docker stop -t 20 "$name-first" >/dev/null
# A different container, as after a restart on the cluster.
run_on_volume "$name-second"
docker exec "$name-second" bash -c '
    test -x /usr/games/sl
    dpkg -s sl >/dev/null
    test "$(cat /etc/smoke-test-marker)" = kept
    test "$(cat /home/desktop/smoke-test-marker)" = kept
    test "$(stat -c %U /home/desktop/smoke-test-marker)" = desktop
'
[[ $(docker exec "$name-second" cat /etc/ssh/ssh_host_ed25519_key.pub) == "$host_key" ]] \
    || { echo 'The SSH host key changed between containers.' >&2; exit 1; }
# The seat was only added in the first container. It has to be back here.
seat_back=false
for ((attempt=0; attempt<30; attempt++)); do
    if docker exec --user 1000:1000 "$name-second" seat list | grep -E '^demo +:2 +yes' >/dev/null; then seat_back=true; break; fi
    sleep 2
done
[[ $seat_back == true ]] || { echo 'The seat did not come back in the new container.' >&2; docker exec "$name-second" cat /tmp/desktop-runtime/seats.log; exit 1; }
# Seeding again must change nothing.
docker run --rm --entrypoint /desktop/seed-machine --mount "type=volume,source=$volume,target=/machine" "$image" /machine \
    | grep -Fx 'The machine is on the volume.' >/dev/null
echo 'All checks passed.'
