#!/usr/bin/env bash
set -euo pipefail
[[ "$(id -u)" != 0 ]] || { echo 'A non-root host user is required' >&2; exit 1; }
SBM_TEST_REPOSITORY=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_TEST_REPOSITORY
work=$(mktemp -d /tmp/sbm-local-openrc.XXXXXX)
cleanup() { [[ "$work" == /tmp/sbm-local-openrc.* ]] && rm -rf -- "$work"; }
trap cleanup EXIT
rootfs="$work/alpine.tar.gz"
asset="$work/sing-box-1.14.4-linux-amd64-musl.tar.gz"
curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-minirootfs-3.23.8-x86_64.tar.gz -o "$rootfs"
printf '%s  %s\n' 56e2810205c17a5dff78cdd7b2c2af4ccdef16f18d765d5bb0f527438b136676 "$rootfs" | sha256sum -c -
curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64-musl.tar.gz -o "$asset"
printf '%s  %s\n' 8f7c5f0651238850d96a0e488e5473cd77ec1a0098f63942e943f475a12057ca "$asset" | sha256sum -c -
export SBM_PARENT_MNT_NS SBM_PARENT_PID_NS SBM_PARENT_NET_NS
SBM_PARENT_MNT_NS=$(readlink /proc/self/ns/mnt)
SBM_PARENT_PID_NS=$(readlink /proc/self/ns/pid)
SBM_PARENT_NET_NS=$(readlink /proc/self/ns/net)
export SBM_ISOLATED_TEST=1
export SBM_TEST_SCENARIO="${SBM_TEST_SCENARIO:-all}"
export SBM_ISOLATED_ROOT_ID
SBM_ISOLATED_ROOT_ID=$(cat /proc/sys/kernel/random/uuid)
mkdir "$work/root"
timeout -k 5 600 unshare --user --map-root-user --mount --pid --fork --mount-proc bash -s -- "$work" <<'SETUP'
set -euo pipefail
work="$1"
root="$work/root"
mount --make-rprivate /
mount -t tmpfs -o size=1500m,mode=755 tmpfs "$root"
tar -xzf "$work/alpine.tar.gz" --no-same-owner -C "$root"
mkdir -p "$root/dev" "$root/proc" "$root/workspace/fixtures"
for device in null zero random urandom; do
    : > "$root/dev/$device"
    mount --bind "/dev/$device" "$root/dev/$device"
done
mount -t proc proc "$root/proc"
cp /etc/resolv.conf "$root/etc/resolv.conf"
printf '%s\n' "$SBM_ISOLATED_ROOT_ID" > "$root/.sbm-isolated-test-root"
chmod 600 "$root/.sbm-isolated-test-root"
cp -R "$SBM_TEST_REPOSITORY/src" "$SBM_TEST_REPOSITORY/scripts" "$SBM_TEST_REPOSITORY/tests" "$root/workspace/"
cp "$work/sing-box-1.14.4-linux-amd64-musl.tar.gz" "$root/workspace/fixtures/"
chroot "$root" /sbin/apk add --no-cache --no-scripts bash openrc python3 curl ca-certificates iproute2 gcc musl-dev flock 'sing-box=1.12.12-r6'
chroot "$root" /bin/sh -c 'cd /workspace && bash scripts/build-install.sh'
cat > "$root/workspace/isolate.c" <<'C'
#define _GNU_SOURCE
#include <sched.h>
#include <sys/mount.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
static int status_code(int status) { return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status); }
int main(void) {
    if (unshare(CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWNET) < 0) { perror("unshare"); return 2; }
    pid_t init = fork();
    if (init < 0) return 3;
    if (init != 0) { int status; return waitpid(init, &status, 0) == init ? status_code(status) : 4; }
    if (mount("proc", "/proc", "proc", 0, NULL) < 0) { perror("proc mount"); return 5; }
    if (system("ip link set lo up") != 0) return 6;
    pid_t child = fork();
    if (child < 0) return 7;
    if (child == 0) { chdir("/workspace"); execlp("python3", "python3", "tests/engine-service-integration.py", "--manager", "openrc", "--scenario", getenv("SBM_TEST_SCENARIO"), (char *)NULL); _exit(127); }
    int status; pid_t reaped;
    while ((reaped = wait(&status)) > 0) if (reaped == child) return status_code(status);
    return 8;
}
C
chroot "$root" /usr/bin/gcc -O2 -o /workspace/isolate /workspace/isolate.c
status=0
chroot "$root" /workspace/isolate || status=$?
if [[ -f "$root/tmp/sbm-engine-service-report.json" ]]; then cat "$root/tmp/sbm-engine-service-report.json"; fi
exit "$status"
SETUP
