#!/bin/bash
set -euo pipefail

GRY='\033[0;37m'; GRN='\033[0;32m'; YLW='\033[1;33m'; N='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PKG_NAME="$(basename "$SCRIPT_DIR")"
RECIPE="${SCRIPT_DIR}/recipe.yml"

[ -f "$RECIPE" ] || { echo -e "${YLW}[!] 缺少 $RECIPE${N}"; exit 1; }

REPO_URL=$(grep '^upstream:' "$RECIPE" | awk '{print $2}' | tr -d '"' || true)
POLICY=$(grep '^policy:' "$RECIPE" | awk '{print $2}' | tr -d '"' || true)
REF=$(grep '^ref:' "$RECIPE" | awk '{print $2}' | tr -d '"' || true)

[ -n "${REPO_URL:-}" ] || { echo -e "${YLW}[!] recipe.yml 缺少 upstream 字段${N}"; exit 1; }
POLICY="${POLICY:-latest}"
REF="${REF:-HEAD}"

command -v git >/dev/null 2>&1      || { echo -e "${YLW}[!] 缺少 git${N}"; exit 1; }
command -v dpkg-deb >/dev/null 2>&1 || { echo -e "${YLW}[!] 缺少 dpkg-deb${N}"; exit 1; }

sanitize_deb_file() {
  local file="$1"
  if [ -f "$file" ]; then
    sed -i 's/\r$//' "$file"
    sed -i 's/[[:space:]]*$//' "$file"
    if [ -n "$(tail -c1 "$file")" ]; then
      echo "" >> "$file"
    fi
  fi
}

WORK_DIR="${GITHUB_WORKSPACE:-$REPO_ROOT}/build_${PKG_NAME}"
DEB_ROOT="${WORK_DIR}/deb_root"
SRC_DIR="${WORK_DIR}/src"
INSTALL_DIR="${DEB_ROOT}/opt/theos"

echo -e "${GRY}[>] Preparing ${PKG_NAME}${N}"
rm -rf "$WORK_DIR"
mkdir -p "${DEB_ROOT}/DEBIAN"

echo -e "  ${GRY}=> Cloning source at ${REF}${N}"
git clone --recursive "$REPO_URL" "$SRC_DIR"
cd "$SRC_DIR"
if [ "$REF" != "HEAD" ]; then
  git checkout "$REF"
fi
git submodule update --init --recursive

if [[ "$POLICY" == "locked" ]] && [[ "$REF" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  VERSION="$REF"
else
  SHORT_HASH=$(git rev-parse --short HEAD)
  VERSION="1.0.0~$(date +%Y%m%d%H%M)-${SHORT_HASH}"
fi
echo -e "  ${GRY}=> Generated dynamic version: ${VERSION}${N}"

echo -e "  ${GRY}=> Pruning non-iOS files${N}"

rm -rf docs extras
rm -f  out.txt README.md CODE_OF_CONDUCT.md LICENSE.md package.json

rm -f  makefiles/platform/Cygwin.mk \
       makefiles/platform/Windows.mk \
       makefiles/platform/FreeBSD.mk \
       makefiles/platform/Linux.mk

rm -rf makefiles/targets/Cygwin \
       makefiles/targets/Windows \
       makefiles/targets/Linux

rm -f  makefiles/targets/_common/cygwin.mk \
       makefiles/targets/_common/linux.mk

rm -f  makefiles/targets/Darwin/appletv.mk \
       makefiles/targets/Darwin/appletv_simulator.mk \
       makefiles/targets/Darwin/macosx.mk \
       makefiles/targets/Darwin/native.mk \
       makefiles/targets/Darwin/simulator.mk \
       makefiles/targets/Darwin/watchos.mk \
       makefiles/targets/Darwin/watchos_simulator.mk

rm -rf vendor/logos/extras

find . -name '.DS_Store' -type f -delete 2>/dev/null || true
find . -name '._*'       -type f -delete 2>/dev/null || true

echo -e "  ${GRY}=> Archiving source snapshot${N}"
tar -czf "${WORK_DIR}/${PKG_NAME}-source.tar.gz" \
    --exclude=.git --exclude=.github \
    -C "$SRC_DIR" .

echo -e "  ${GRY}=> Organizing package structure${N}"
mkdir -p "$INSTALL_DIR"
tar -cf - --exclude=.git --exclude=.github -C "$SRC_DIR" . | tar -xf - -C "$INSTALL_DIR"

[ -f "${SCRIPT_DIR}/control.in" ] || { echo -e "${YLW}[!] 缺少 ${SCRIPT_DIR}/control.in${N}"; exit 1; }

echo -e "  ${GRY}=> Injecting control files${N}"
sed "s/{{VERSION}}/${VERSION}/g" "${SCRIPT_DIR}/control.in" > "${DEB_ROOT}/DEBIAN/control"
sed -i 's/^\([A-Za-z-]*\):[[:space:]]*/\1: /' "${DEB_ROOT}/DEBIAN/control"
sanitize_deb_file "${DEB_ROOT}/DEBIAN/control"
chmod 644 "${DEB_ROOT}/DEBIAN/control"

for script in preinst postinst prerm postrm; do
  if [ -f "${SCRIPT_DIR}/${script}" ]; then
    cp "${SCRIPT_DIR}/${script}" "${DEB_ROOT}/DEBIAN/${script}"
    sanitize_deb_file "${DEB_ROOT}/DEBIAN/${script}"
    chmod 755 "${DEB_ROOT}/DEBIAN/${script}"
  fi
done

chmod 755 "${DEB_ROOT}/DEBIAN"

echo -e "  ${GRY}=> Building .deb${N}"
cd "$WORK_DIR"

if dpkg-deb --help 2>&1 | grep -- '--root-owner-group' >/dev/null; then
  dpkg-deb --root-owner-group -b -Zxz deb_root "${PKG_NAME}.deb"
else
  echo -e "  ${YLW}[!] 降级打包${N}"
  dpkg-deb -b -Zxz deb_root "${PKG_NAME}.deb"
fi

echo -e "  ${GRN}✓${N} Built ${PKG_NAME}.deb"