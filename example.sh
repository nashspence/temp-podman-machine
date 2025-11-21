TMP_LIB=$(mktemp)
curl -fsSL "https://raw.githubusercontent.com/nashspence/temp-podman-machine/main/lib.sh" > "$TMP_LIB"
. "$TMP_LIB"

CONTAINER_CONNECTION=test-machine
CONTAINER_SOCKET=$(temp_podman_machine $$ \
  --cpus=4 \
  --memory=8192 \
  --disk-size=100 \
  --swap=2048 \
  --timezone="America/Los_Angeles" \
  --volume=/Users:/Users \
  --volume=/Volumes:/Volumes \
  "$CONTAINER_CONNECTION")

podman run --rm -it \
  --security-opt label=disable \
  --name podman-dood-test \
  --network=bridge \
  --hostname podman-dood \
  -e TZ="America/Los_Angeles" \
  -e DOCKER_HOST="unix:///var/run/docker.sock" \
  -v "$CONTAINER_SOCKET:/var/run/docker.sock" \
  docker.io/library/ubuntu:22.04 \
  bash -euxo pipefail -c '
    echo "Inside outer container:"
    whoami
    uname -a
    echo "DOCKER_HOST=$DOCKER_HOST"
    echo

    # Install Docker CLI
    apt-get update
    apt-get install -y docker.io

    echo "=== docker version (talking to Podman via socket) ==="
    docker version || true
    echo

    echo "=== docker run nested alpine container ==="
    docker run --rm alpine:3.20 /bin/sh -c "
      echo \"Hello from nested container\";
      echo \"Nested uname: \";
      uname -a
    "
    echo

    echo "=== docker ps -a (from inside outer container) ==="
    docker ps -a
  '
