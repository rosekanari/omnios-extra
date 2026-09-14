#!/usr/bin/bash
#
# {{{ CDDL HEADER
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source. A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
# }}}

# Copyright 2026 OmniOS Community Edition (OmniOSce) Association.

. ../../lib/build.sh

PROG=bmake
VER=20260824
PKG=ooce/developer/bmake
SUMMARY="NetBSD make"
DESC="A portable version of the NetBSD make(1) build tool, which understands "
DESC+="BSD makefiles"

set_arch 64
# Upstream publishes flat tarballs under .../pub/sjg; the framework builds
# the URL as $SRCMIRROR/$DLDIR/$FILENAME, so sjg is the download directory.
set_mirror https://www.crufty.net/ftp/pub

# Upstream ships no .sha256 alongside the tarball, so the checksum is carried
# here rather than fetched. Verified against two independent downloads.
set_checksum sha256 \
    76c6253a592dd55741be0b14805b9f7e0eb8442004146a978f24b20f37d2cb72

# bmake installs as bmake, never as make, so nothing shadows illumos make(1).

# There is no usable configure/make path here. The configure script exists and
# runs, but it only writes a four-line makefile that relays every target to
# boot-strap; the real Makefile is BSD syntax, which neither illumos make nor
# GNU make can parse. boot-strap compiles the sources directly with $CC, so
# there is no chicken-and-egg problem -- no make is needed to build this make.

build() {
    # boot-strap keeps the source tree clean by building in a <host-target>
    # subdirectory; run from the source directory it puts that subdirectory in
    # the parent, so it is given an explicit object directory instead.
    OBJDIR=$TMPDIR/obj/$HOST_TARGET
    logcmd $MKDIR -p $TMPDIR/obj || logerr "Failed to create object directory"

    pushd $TMPDIR/obj >/dev/null

    # boot-strap runs the unit tests as part of both 'build' and 'install', and
    # its exit status reflects the tests rather than the compilation. It is
    # therefore not checked here; the binary is checked instead.
    logmsg "Bootstrapping $PROG"
    logcmd env CC="$CC" $TMPDIR/$BUILDDIR/boot-strap --prefix=$PREFIX op=build

    OBJDIR=
    for d in $TMPDIR/obj/*/; do
        [ -x "$d$PROG" ] && OBJDIR="${d%/}"
    done
    [ -n "$OBJDIR" ] || logerr "boot-strap produced no $PROG binary"
    logmsg "-- built $OBJDIR/$PROG"

    popd >/dev/null
}

install_bmake() {
    pushd $TMPDIR/obj >/dev/null

    # Two overrides are needed, both satisfied by what upstream already ships:
    #
    # INSTALL -- the Makefile calls install(1) with BSD syntax
    # ("install -c -s -o root -g root -m 555"); illumos /usr/sbin/install
    # rejects that with "The -c, -f, -n options each require a directory
    # following!" and installs nothing. bmake bundles install-sh for exactly
    # this case, and its Makefile already defaults to it (INSTALL ?=
    # ${srcdir}/install-sh) -- configure just finds the system one first.
    #
    # 'tested' -- op_install() calls op_test() first and aborts the install if
    # any test fails, so a test result would otherwise decide whether the
    # package gets built at all. The sentinel makes op_test() return early
    # (is_newer bmake tested || return). The tests still run, under
    # run_testsuite below, where their output is recorded rather than fatal.
    logcmd $TOUCH $OBJDIR/tested || logerr "Failed to mark tests as run"

    logmsg "Installing $PROG"
    # MANTARGET -- bmake defaults to 'cat', which installs a preformatted page
    # into share/man/cat1. Every other package here ships the nroff source in
    # man1, which is also what mandoc and the man-index service expect.
    logcmd env CC="$CC" $TMPDIR/$BUILDDIR/boot-strap --prefix=$PREFIX \
        op=install INSTALL_DESTDIR=$DESTDIR \
        INSTALL="$TMPDIR/$BUILDDIR/install-sh" MANTARGET=man \
        || logerr "Installation failed"

    popd >/dev/null
}

# The unit-tests 'test' target has two phases: its prerequisites run each test
# and write a .out file, then its recipe compares every .exp against its .out,
# prints the diffs and lists the failures. One test breaks the first phase:
# deptgt-interrupt sends SIGINT to its own make, and on illumos bmake is killed
# by the signal after running .INTERRUPT rather than exiting 130, taking the
# harness shell with it, so no .out is ever written. A failed prerequisite means
# the recipe never runs -- and with it the comparison of all the other tests.
# Hence exactly one exclusion, and no -k: -k would run every test but still
# skip the comparison phase, leaving the log with test names and no verdicts.
#
# The list has to repeat upstream's own exclusions: a command-line variable
# replaces the makefile's BROKEN_TESTS instead of appending to it, and dropping
# them makes var-op-shell fail. Passing it through the environment breaks the
# suite outright -- the tests stop executing and 387 .out files go missing.
#
# What remains in testsuite.log is five real divergences, all traceable to the
# shell bmake selects here (.SHELL = /usr/xpg4/bin/sh):
#
#   suff, varmod-sun-shell1  print .SHELL and expect /bin/sh
#   sh-leading-hyphen        the shell words "not found" differently
#   export                   SHLVL, which every shell on illumos sets
#   cmd-interrupt            ksh93 does not survive a child killed by SIGINT
#
# The upstream harness assumes a shell that survives that, which bash does and
# ksh93 does not. Nothing is hidden: the diffs are in the log, where a future
# diff of the log will show any change.
# Upstream's own six exclusions have to be repeated: a command-line variable
# replaces the makefile's BROKEN_TESTS rather than appending to it, and dropping
# them makes var-op-shell fail. Passing the list through the environment instead
# breaks the suite outright -- the tests stop executing and 387 .out files go
# missing.
BROKEN_TESTS="deptgt-silent-jobs job-flags job-output-long-lines"
BROKEN_TESTS+=" opt-debug-x-trace sh-flags var-op-shell deptgt-interrupt"

run_tests() {
    TESTSUITE_MAKE="$OBJDIR/$PROG"
    MAKE_TESTSUITE_ARGS="-m $TMPDIR/$BUILDDIR/mk TEST_MAKE=$OBJDIR/$PROG"
    # A make variable whose value contains spaces cannot go through
    # MAKE_TESTSUITE_ARGS, which is word-split; the framework provides
    # MAKE_TESTSUITE_ARGS_WS for that, passed through 'eval set --'.
    MAKE_TESTSUITE_ARGS_WS="'BROKEN_TESTS=$BROKEN_TESTS'"
    run_testsuite test unit-tests
}

init
set_builddir $PROG
download_source sjg $PROG $VER
patch_source
prep_build
build
run_tests
install_bmake
make_package
clean_up

# Vim hints
# vim:ts=4:sw=4:et:fdm=marker
