#!/usr/bin/env bash
# Build and start N KVM runners on this host. Needs /dev/kvm (SVM/VT-x on in BIOS).
# From the laptop:
#   tar -C host/kvm-runner -c . | ssh lm-server-raw 'd=$(mktemp -d) && tar -C $d -x && \
#     RUNNER_TOKEN=<token> bash $d/up.sh 1'
#   token: gh api -X POST repos/wearefractional/foraudits/actions/runners/registration-token --jq .token
set -euo pipefail
cd "$(dirname "$0")"
: "${RUNNER_TOKEN:?set RUNNER_TOKEN (repo registration token)}"
n=${1:-1}

[ -c /dev/kvm ] || { echo "no /dev/kvm: enable SVM in BIOS, then check: lsmod | grep kvm_amd" >&2; exit 1; }
kvm_gid=$(stat -c %g /dev/kvm)

docker build -q -t lm-kvm-runner:2.338.2 .

for i in $(seq 1 "$n"); do
  name=gh-runner-kvm-$i
  docker rm -f "$name" 2>/dev/null || true
  # ponytail: 10g cap per runner to protect the fleet's 56G budget; raise if the AVD OOMs.
  # android-sdk volume keeps downloaded system images across container rebuilds.
  docker run -d --name "$name" --restart unless-stopped \
    --device /dev/kvm --group-add "$kvm_gid" --memory 10g \
    -v "gh-kvm-android-sdk-$i:/home/runner/android-sdk" \
    -e RUNNER_TOKEN="$RUNNER_TOKEN" \
    --entrypoint bash lm-kvm-runner:2.338.2 -c "
      [ -f .runner ] || ./config.sh --unattended --url https://github.com/wearefractional/foraudits \
        --token \$RUNNER_TOKEN --name lm-server-kvm-$i --labels kvm --replace
      exec ./run.sh"
done
docker ps --filter name=gh-runner-kvm
