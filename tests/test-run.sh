#!/bin/bash
#
# Copyright (C) 2011 Colin Walters <walters@verbum.org>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the
# Free Software Foundation, Inc., 59 Temple Place - Suite 330,
# Boston, MA 02111-1307, USA.

set -euo pipefail

. $(dirname $0)/libtest.sh

skip_without_bwrap
skip_without_user_xattrs

echo "1..8"

setup_repo
install_repo

# Verify that app is correctly installed

assert_has_dir $FL_DIR/app/org.test.Hello
assert_has_symlink $FL_DIR/app/org.test.Hello/current
assert_symlink_has_content $FL_DIR/app/org.test.Hello/current ^$ARCH/master$
assert_has_dir $FL_DIR/app/org.test.Hello/$ARCH/master
assert_has_symlink $FL_DIR/app/org.test.Hello/$ARCH/master/active
ID=`readlink $FL_DIR/app/org.test.Hello/$ARCH/master/active`
assert_has_file $FL_DIR/app/org.test.Hello/$ARCH/master/active/deploy
assert_has_file $FL_DIR/app/org.test.Hello/$ARCH/master/active/metadata
assert_has_dir $FL_DIR/app/org.test.Hello/$ARCH/master/active/files
assert_has_dir $FL_DIR/app/org.test.Hello/$ARCH/master/active/export
assert_has_file $FL_DIR/exports/share/applications/org.test.Hello.desktop
# Ensure Exec key is rewritten
assert_file_has_content $FL_DIR/exports/share/applications/org.test.Hello.desktop "^Exec=.*/flatpak run --branch=master --arch=$ARCH --command=hello.sh org.test.Hello$"
assert_has_file $FL_DIR/exports/share/icons/hicolor/64x64/apps/org.test.Hello.png

# Ensure triggers ran
assert_has_file $FL_DIR/exports/share/applications/mimeinfo.cache
assert_file_has_content $FL_DIR/exports/share/applications/mimeinfo.cache x-test/Hello
assert_has_file $FL_DIR/exports/share/icons/hicolor/icon-theme.cache
assert_has_file $FL_DIR/exports/share/icons/hicolor/index.theme

$FLATPAK list ${U} | grep org.test.Hello > /dev/null
$FLATPAK list ${U} -d | grep org.test.Hello | grep test-repo > /dev/null
$FLATPAK list ${U} -d | grep org.test.Hello | grep current > /dev/null
$FLATPAK list ${U} -d | grep org.test.Hello | grep ${ID:0:12} > /dev/null

$FLATPAK info ${U} org.test.Hello > /dev/null
$FLATPAK info ${U} org.test.Hello | grep test-repo > /dev/null
$FLATPAK info ${U} org.test.Hello | grep $ID > /dev/null

echo "ok install"

run org.test.Hello > hello_out
assert_file_has_content hello_out '^Hello world, from a sandbox$'

echo "ok hello"

run_sh cat /run/user/`id -u`/flatpak-info > fpi
assert_file_has_content fpi '^name=org.test.Hello$'

echo "ok flatpak-info"

run_sh readlink /proc/self/ns/net > unshared_net_ns
ARGS="--share=network" run_sh readlink /proc/self/ns/net > shared_net_ns
assert_not_streq `cat unshared_net_ns` `readlink /proc/self/ns/net`
assert_streq `cat shared_net_ns` `readlink /proc/self/ns/net`

run_sh readlink /proc/self/ns/ipc > unshared_ipc_ns
ARGS="--share=ipc" run_sh readlink /proc/self/ns/ipc > shared_ipc_ns
assert_not_streq `cat unshared_ipc_ns` `readlink /proc/self/ns/ipc`
assert_streq `cat shared_ipc_ns` `readlink /proc/self/ns/ipc`

# We try the filesystem namespace tests several times with different
# shared-or-not directories, because:
# - --filesystem=/foo doesn't work if /foo is read-only in the container
#   (notably, --filesystem=/usr/... won't work)
# - --filesystem=host doesn't expose either /usr or /var/... or /var/tmp
#   from the host because they're on the list of things we expect to be
#   supplied by the container

test_filesystem_binding () {
    local dir="$1"

    if run_sh cat "$dir/package_version.txt" &> /dev/null; then
        assert_not_reached "Unexpectedly allowed to access file"
    fi

    case "$dir" in
        (/home/*|/opt/*|/var/tmp/*)
            if ! ARGS="--filesystem=$dir" run_sh cat "$dir/package_version.txt" > /dev/null; then
                assert_not_reached "Failed to share --filesystem=$dir"
            fi
            ;;
        (*)
            echo "Not testing --filesystem=$dir, it won't necessarily work" >&2
            ;;
    esac

    case "$dir" in
        (/home/*|/opt/*)
            if ! ARGS="--filesystem=host" run_sh cat "$dir/package_version.txt" > /dev/null; then
                assert_not_reached "Failed to share $dir as part of host filesystem"
            fi
            ;;
        (*)
            echo "Not testing --filesystem=host with $dir, it won't necessarily work" >&2
            ;;
    esac
}

test_filesystem_binding "${test_builddir}"

mkdir "${TEST_DATA_DIR}/shareable"
cp "${test_builddir}/package_version.txt" "${TEST_DATA_DIR}/shareable/"
test_filesystem_binding "${TEST_DATA_DIR}/shareable"

# We don't want to pollute the home directory unprompted, but the user
# can opt-in by creating this directory.
if [ -e "${HOME}/.flatpak-tests" ]; then
    cp "${test_builddir}/package_version.txt" "${HOME}/.flatpak-tests/"
    test_filesystem_binding "${HOME}/.flatpak-tests"
else
    echo "not testing \$HOME binding, \$HOME/.flatpak-tests/ does not exist" >&2
fi

echo "ok namespaces"

test_overrides () {
    local dir="$1"

    if run_sh cat "$dir/package_version.txt" &> /dev/null; then
        assert_not_reached "Unexpectedly allowed to access file"
    fi

    $FLATPAK override ${U} --filesystem=host org.test.Hello

    case "$dir" in
        (/home/*|/opt/*)
            if ! run_sh cat "$dir/package_version.txt" > /dev/null; then
                assert_not_reached "Failed to share $dir as part of host filesystem"
            fi
            ;;
        (*)
            echo "Not testing --filesystem=host with $dir, it won't necessarily work" >&2
            ;;
    esac

    if ARGS="--nofilesystem=host" run_sh cat "${dir}/package_version.txt" &> /dev/null; then
        assert_not_reached "Unexpectedly allowed to access --nofilesystem=host file"
    fi

    $FLATPAK override ${U} --nofilesystem=host org.test.Hello

    if run_sh cat "${dir}/package_version.txt" &> /dev/null; then
        assert_not_reached "Unexpectedly allowed to access file"
    fi
}

test_overrides "${test_builddir}"

if [ -e "${HOME}/.flatpak-tests" ]; then
    cp "${test_builddir}/package_version.txt" "${HOME}/.flatpak-tests/"
    test_overrides "${HOME}/.flatpak-tests"
else
    echo "not testing \$HOME binding overrides, \$HOME/.flatpak-tests/ does not exist" >&2
fi

echo "ok overrides"

OLD_COMMIT=`${FLATPAK} ${U} info --show-commit org.test.Hello`

# TODO: For weird reasons this breaks in the system case. Needs debugging
if [ x${USE_SYSTEMDIR-} != xyes ] ; then
    ${FLATPAK} ${U} update -v org.test.Hello master
    ALSO_OLD_COMMIT=`${FLATPAK} ${U} info --show-commit org.test.Hello`
    assert_streq "$OLD_COMMIT" "$ALSO_OLD_COMMIT"
fi

echo "ok null update"

make_updated_app

${FLATPAK} ${U} update org.test.Hello

NEW_COMMIT=`${FLATPAK} ${U} info --show-commit org.test.Hello`

assert_not_streq "$OLD_COMMIT" "$NEW_COMMIT"

run org.test.Hello > hello_out
assert_file_has_content hello_out '^Hello world, from a sandboxUPDATED$'

echo "ok update"

DIR=`mktemp -d`
${FLATPAK} build-init ${DIR} org.test.Split org.test.Platform org.test.Platform

mkdir -p ${DIR}/files/a
echo "a" > ${DIR}/files/a/data
mkdir -p ${DIR}/files/b
echo "b" > ${DIR}/files/b/data
mkdir -p ${DIR}/files/c
echo "c" > ${DIR}/files/c/data
mkdir -p ${DIR}/files/d
echo "d" > ${DIR}/files/d/data
echo "nope" > ${DIR}/files/nope

${FLATPAK} build-finish --command=hello.sh ${DIR}
${FLATPAK} build-export ${FL_GPGARGS} repo ${DIR}
update_repo

${FLATPAK} ${U} install test-repo org.test.Split --subpath=/a --subpath=/b --subpath=/nosuchdir master

COMMIT=`${FLATPAK} ${U} info --show-commit org.test.Split`
if [ x${USE_SYSTEMDIR-} != xyes ] ; then
    # Work around bug in ostree: local pulls don't do commitpartials
    assert_has_file $FL_DIR/repo/state/${COMMIT}.commitpartial
fi

assert_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/a/data
assert_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/b/data
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/c
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/d
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/nope
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/nosuchdir

echo "aa" > ${DIR}/files/a/data2
rm  ${DIR}/files/a/data
mkdir -p ${DIR}/files/e
echo "e" > ${DIR}/files/e/data
mkdir -p ${DIR}/files/f
echo "f" > ${DIR}/files/f/data
rm -rf  ${DIR}/files/b

${FLATPAK} build-export ${FL_GPGARGS} repo ${DIR}
update_repo

${FLATPAK} ${U} update --subpath=/a --subpath=/b --subpath=/e --subpath=/nosuchdir org.test.Split

COMMIT=`${FLATPAK} ${U} info --show-commit org.test.Split`
if [ x${USE_SYSTEMDIR-} != xyes ] ; then
    # Work around bug in ostree: local pulls don't do commitpartials
    assert_has_file $FL_DIR/repo/state/${COMMIT}.commitpartial
fi

assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/a/data
assert_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/a/data2
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/b
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/c
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/d
assert_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/e/data
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/f
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/nope

${FLATPAK} build-export ${FL_GPGARGS} repo ${DIR}
update_repo

# Test reusing the old subpath list
${FLATPAK} ${U} update org.test.Split

COMMIT=`${FLATPAK} ${U} info --show-commit org.test.Split`
if [ x${USE_SYSTEMDIR-} != xyes ] ; then
    # Work around bug in ostree: local pulls don't do commitpartials
    assert_has_file $FL_DIR/repo/state/${COMMIT}.commitpartial
fi

assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/a/data
assert_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/a/data2
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/b
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/c
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/d
assert_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/e/data
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/f
assert_not_has_file $FL_DIR/app/org.test.Split/$ARCH/master/active/files/nope


echo "ok subpaths"
