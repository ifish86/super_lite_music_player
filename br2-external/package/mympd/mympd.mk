################################################################################
#
# mympd
#
################################################################################

# Built from the submodule in src/mympd, not from an upstream tarball,
# so there is no hash to verify and no version to bump here: the pin is
# the submodule commit. This string only names the build directory.
MYMPD_VERSION = 26.1.0
MYMPD_SITE = $(BR2_EXTERNAL_SLMP_PATH)/../src/mympd
MYMPD_SITE_METHOD = local
MYMPD_LICENSE = GPL-3.0+
MYMPD_LICENSE_FILES = LICENSE.md

# host-jq, because myMPD runs its own build.sh at CMake configure time
# to minify and gzip the web assets, and that needs jq for the i18n
# JSON. Depending on the package rather than on whatever the developer
# happens to have installed keeps the build reproducible: BR_PATH puts
# $(HOST_DIR)/bin first, so this jq wins even on a host that has one.
# perl and gzip, which build.sh also needs, are host requirements the
# top-level script already checks for.
MYMPD_DEPENDENCIES = host-jq openssl pcre2

# Out-of-source, and not as a matter of taste. Buildroot builds CMake
# packages in-source unless told otherwise, which here means
# CMAKE_CURRENT_BINARY_DIR is the source directory, and myMPD's asset
# generator opens with:
#
#     rm -fr "$$MYMPD_BUILDDIR/htdocs"
#
# In an in-source build that deletes the htdocs it is about to read
# index.html from, and the configure step fails inside a subshell whose
# stderr build.sh has redirected to /dev/null. The visible error is
# "Creating assets failed", which says nothing about the cause.
MYMPD_SUPPORTS_IN_SOURCE_BUILD = NO

# CMAKE_BUILD_TYPE=None is the whole reason this package is not three
# lines long.
#
# myMPD's CMakeLists.txt applies a large hardening flag set for every
# build type it recognises, and feature-tests each flag with
# check_c_compiler_flag before adding it. One of them is
# -fcf-protection=full, which this toolchain accepts and which makes
# GCC emit ENDBR32 (F3 0F 1E FB) at every function entry. ENDBR32 sits
# in the 0F 1E slot, one opcode below the long NOP (0F 1F) that the
# Geode LX does not implement and that this entire project exists to
# avoid. A CPU that raises #UD on 0F 1F cannot be assumed to decode
# 0F 1E either, and appending -fcf-protection=none to CFLAGS does not
# help: add_compile_options() lands after CMAKE_C_FLAGS, so the last
# flag on the command line is still =full.
#
# The upstream CMakeLists ends that block with "if CMAKE_BUILD_TYPE is
# neither Release nor Debug, do not alter compile options". Taking it at
# its word is cheaper and more honest than patching it. We lose only
# flags Buildroot already supplies: -O2 from BR2_OPTIMIZE_2, -fPIE from
# BR2_PIC_PIE, relro/now from BR2_RELRO_FULL, and the strip from
# BR2_STRIP_strip. It also drops upstream's -Werror, which is not
# something to inherit when building someone else's C with a compiler
# they did not test.
MYMPD_CONF_OPTS = \
	-DCMAKE_BUILD_TYPE=None \
	-DBUILD_SHARED_LIBS=OFF \
	-DMYMPD_BUILD_TESTING=OFF \
	-DMYMPD_DOC=OFF \
	-DMYMPD_DOC_HTML=OFF \
	-DMYMPD_MANPAGES=OFF \
	-DMYMPD_STARTUP_SCRIPT=OFF \
	-DMYMPD_EMBEDDED_ASSETS=ON \
	-DMYMPD_EMBEDDED_LIBMPDCLIENT=ON \
	-DMYMPD_ENABLE_IPV6=OFF \
	-DMYMPD_ENABLE_LUA=OFF \
	-DMYMPD_ENABLE_UTF8=OFF

# BUILD_SHARED_LIBS=OFF overrides Buildroot, which passes ON for every
# CMake package unless the whole image is static. myMPD bundles mongoose,
# mpack, rax, sds and libmpdclient in dist/ and declares them with a bare
# add_library(), so ON turns all five into shared objects. It then
# installs none of them, because upstream builds them static and has
# never needed to. The result links, installs, and dies at exec with
# "libmpack.so: No such file or directory".
#
# The bundled libmpdclient is worse than merely missing. It is
# libmpdclient.so with no version suffix, and mpc has already put
# Buildroot's libmpdclient.so -> libmpdclient.so.2.22 in /usr/lib. The
# binary would have resolved against the 2.22 it was not compiled
# against, which is an ABI mismatch that shows up as a crash somewhere
# unrelated rather than as a link error. Static bundling removes the
# collision along with the missing files.

# MYMPD_DOC, MYMPD_MANPAGES and MYMPD_STARTUP_SCRIPT are not off to save
# space. They are off because cmake/Install.cmake.in installs them with
# file(INSTALL) to absolute paths that DESTDIR does not prefix, and it
# picks the init system by probing the *host* for /usr/lib/systemd or
# /etc/init.d. Left on, a cross build writes into the build machine's
# own filesystem.

# Buildroot's libmpdclient is 2.22 and myMPD wants 2.26. Left to itself
# myMPD finds the staging copy, warns, and silently falls back to the
# one it bundles. Asking for the bundled one outright means the outcome
# does not depend on what else happens to be in staging.

ifeq ($(BR2_PACKAGE_MYMPD_FLAC),y)
MYMPD_DEPENDENCIES += flac
MYMPD_CONF_OPTS += -DMYMPD_ENABLE_FLAC=ON
else
MYMPD_CONF_OPTS += -DMYMPD_ENABLE_FLAC=OFF
endif

ifeq ($(BR2_PACKAGE_MYMPD_LIBID3TAG),y)
MYMPD_DEPENDENCIES += libid3tag
MYMPD_CONF_OPTS += -DMYMPD_ENABLE_LIBID3TAG=ON
else
MYMPD_CONF_OPTS += -DMYMPD_ENABLE_LIBID3TAG=OFF
endif

# No work directory is created here. myMPD's compiled-in default is
# /var/lib/mympd, which is on the read-only root; /etc/default/mympd
# points it at /data/mympd instead, and /etc/init.d/S03data creates that
# on the persistent partition before anything needs it.

$(eval $(cmake-package))
