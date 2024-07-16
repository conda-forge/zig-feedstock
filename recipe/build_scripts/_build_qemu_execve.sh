function build_qemu_execve() {
  local arch=${1:-"aarch64"}

  mkdir -p "${SRC_DIR}"/_qemu_execve
  cd "${SRC_DIR}"/_qemu_execve
    # git clone https://github.com/balena-io/qemu.git
    git clone https://gitlab.com/qemu-project/qemu.git
    patch -p0 < "${RECIPE_DIR}"/patches/xxxx-qemu-execve.patch

    mkdir _conda-build
    cd _conda-build
      export PKG_CONFIG="${BUILD_PREFIX}/bin/pkg-config"
      export PKG_CONFIG_PATH="${BUILD_PREFIX}/lib/pkgconfig"
      export PKG_CONFIG_LIBDIR="${BUILD_PREFIX}/lib/pkgconfig"
      export CC="${CC_FOR_BUILD}"
      export CXX="${CXX_FOR_BUILD}"
      export CFLAGS=$(echo "$CFLAGS" | sed 's#\$PREFIX#\$BUILD_PREFIX#g' | sed "s#$PREFIX#$BUILD_PREFIX#g")
      export CXXFLAGS=$(echo "$CXXFLAGS" | sed 's#\$PREFIX#\$BUILD_PREFIX#g' | sed "s#$PREFIX#$BUILD_PREFIX#g")
      export LDFLAGS=$(echo "$LDFLAGS" | sed 's#\$PREFIX#\$BUILD_PREFIX#g' | sed "s#$PREFIX#$BUILD_PREFIX#g")

      ../qemu/configure --prefix="${BUILD_PREFIX}" \
         --interp-prefix="${BUILD_PREFIX}" \
         --enable-linux-user --target-list="${arch}"-linux-user > _configure_qemu.log 2>&1
         # --disable-bsd-user --disable-guest-agent --disable-strip --disable-werror --disable-gcrypt --disable-pie \
         # --disable-debug-info --disable-debug-tcg --enable-docs --disable-tcg-interpreter --enable-attr \
         # --disable-brlapi --disable-linux-aio --disable-bzip2 --disable-cap-ng --disable-curl --disable-fdt \
         # --disable-glusterfs --disable-gnutls --disable-nettle --disable-gtk --disable-rdma --disable-libiscsi \
         # --disable-vnc-jpeg --disable-kvm --disable-lzo --disable-curses --disable-libnfs --disable-numa \
         # --disable-opengl --disable-vnc-png --disable-rbd --disable-vnc-sasl --disable-sdl --disable-seccomp \
         # --disable-smartcard --disable-snappy --disable-spice --disable-libusb --disable-usb-redir --disable-vde \
         # --disable-vhost-net --disable-virglrenderer --disable-virtfs --disable-vnc --disable-vte --disable-xen \
         # --disable-xen-pci-passthrough --disable-system --disable-blobs --disable-tools \
      make -j"${CPU_COUNT}" > _make_qemu.log 2>&1
      make install > install_qemu.log 2>&1

      # Patch the interpreter
      patchelf --set-interpreter "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64/ld-linux-x86-64.so.2" "${BUILD_PREFIX}/bin/qemu-${arch}"
      patchelf --set-rpath "\$ORIGIN/../x86_64-conda-linux-gnu/sysroot/lib64" "${BUILD_PREFIX}/bin/qemu-${arch}"
      patchelf --add-rpath "\$ORIGIN/../lib" "${BUILD_PREFIX}/bin/qemu-${arch}"
  cd "${SRC_DIR}"
}
