function build_qemu_execve() {
  local arch=${1:-"aarch64"}

  mamba create -n qemu-execve -y -c conda-forge \
    gcc_linux-64 \
    glib \
    make \
    meson \
    patchelf \
    pkg-config \
    sphinx \
    sphinx-rtd-theme \
    sysroot_linux-64=2.28 \
    zlib

  mkdir -p "${SRC_DIR}"/_qemu_execve
  cd "${SRC_DIR}"/_qemu_execve
    git clone https://gitlab.com/qemu-project/qemu.git
    cd qemu
      git checkout v9.1.0
    cd ..
    patch -p0 < "${RECIPE_DIR}"/patches/xxxx-qemu-execve.patch

    mkdir _conda-build
    cd _conda-build
      local CC=$(mamba run -n qemu-execve which x86_64-conda-linux-gnu-gcc | grep -Eo '/.*gcc' | tail -n 1)
      local PKG_CONFIG=$(mamba run -n qemu-execve which pkg-config | grep -Eo '/.*pkg-config' | tail -n 1)
      local PKG_CONFIG_PATH=$(dirname ${PKG_CONFIG})/../lib/pkgconfig
      mamba run -n qemu-execve bash -c 'echo "${CFLAGS:-}" > _cflags.txt' >& /dev/null
      local CFLAGS=$(< _cflags.txt)
      CFLAGS=${CFLAGS//-mcpu=power8 -mtune=power8/}
      mamba run -n qemu-execve bash -c 'echo "${LDFLAGS:-}" > _ldflags.txt' >& /dev/null
      local LDFLAGS=$(< _ldflags.txt)
      mamba run -n qemu-execve bash -c 'echo "${PATH:-}" > _path.txt' >& /dev/null
      local PATH=$(< _path.txt)

      # export CC PATH PKG_CONFIG CFLAGS LDFLAGS PKG_CONFIG_PATH

      "${SRC_DIR}"/_qemu_execve/qemu/configure --prefix="${BUILD_PREFIX}" \
         --interp-prefix="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot" \
         --enable-linux-user \
         --target-list="${arch}-linux-user" \
         "--cross-cc-${arch}=${SYSROOT_ARCH}-conda-linux-gnu-gcc" \
         "--cross-prefix-${arch}=${SYSROOT_ARCH}-conda-linux-gnu-" \
         --disable-system --disable-fdt --disable-guest-agent --disable-tools --disable-virtfs \
         --disable-docs --disable-hexagon-idef-parser \
         --disable-bsd-user --disable-strip --disable-werror --disable-gcrypt --disable-pie \
         --disable-debug-info --disable-debug-tcg --disable-tcg-interpreter \
         --disable-brlapi --disable-linux-aio --disable-bzip2 --disable-cap-ng --disable-curl \
         --disable-glusterfs --disable-gnutls --disable-nettle --disable-gtk --disable-rdma --disable-libiscsi \
         --disable-vnc-jpeg --disable-kvm --disable-lzo --disable-curses --disable-libnfs --disable-numa \
         --disable-opengl --disable-rbd --disable-vnc-sasl --disable-sdl --disable-seccomp \
         --disable-smartcard --disable-snappy --disable-spice --disable-libusb --disable-usb-redir --disable-vde \
         --disable-vhost-net --disable-virglrenderer --disable-vnc --disable-vte --disable-xen \
         --disable-xen-pci-passthrough > "${SRC_DIR}"/_configure_qemu.log 2>&1
      make -j"${CPU_COUNT}" > "${SRC_DIR}"/_make_qemu.log 2>&1
      make install > "${SRC_DIR}"/_install_qemu.log 2>&1

      # Patch the interpreter
      patchelf --set-interpreter "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64/ld-2.28.so" "${BUILD_PREFIX}/bin/qemu-${arch}"
      patchelf --set-rpath "\$ORIGIN/../x86_64-conda-linux-gnu/sysroot/lib64" "${BUILD_PREFIX}/bin/qemu-${arch}"
      patchelf --add-rpath "\$ORIGIN/../lib" "${BUILD_PREFIX}/bin/qemu-${arch}"

      export QEMU_LD_PREFIX="${SYSROOT_PATH}"
      export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"
      export QEMU_EXECVE="${BUILD_PREFIX}"/bin/qemu-${arch}
      export QEMU_STACK_SIZE=67108864
      export QEMU_LOG_FILENAME="${SRC_DIR}"/_qemu.log
      export QEMU_LOG="strace"
  cd "${SRC_DIR}"
}
