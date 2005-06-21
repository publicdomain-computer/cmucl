#!/bin/sh 

# Build CMUCL from source.  The intent of this script is to make it a
# little easier invoke the other scripts and build CMUCL.  In the
# simplest case where your lisp is named cmulisp and no special
# bootfiles are needed, you would build CMUCL using:
#
#    src/tools/build.sh -C ""
#
# This will create a set of directories named build-2, build-3, and
# build-4 and CMUCL will be built 3 consecutive times, using the
# version of CMUCL from the previous build.
#
#
# You can control which of the builds are done by using the -1, -2, -3
# options, but it is up to you to make sure the previous builds exist.
#
# A more realistic example would be
#
#    src/tools/build.sh -v "My build" -B boot-19b.lisp -o "my-lisp -noinit"
#
# where you need to load the bootfile boot-19b.lisp and your lisp is
# not named cmulisp, but my-lisp.
#
# For more complicated builds, you will need to run create-target.sh
# manually, and adjust the bootstrap or setenv files by hand.  Once
# this is done, you can run build.sh to build everything.  Just be
# sure to leave off the -C option.
#
# Cross compiling is not supported with this script.  You will have to
# do that by hand.
#
# For more information see src/BUILDING.

ENABLE2="yes"
ENABLE3="yes"
ENABLE4="yes"

version=19a
SRCDIR=src
TOOLDIR=$SRCDIR/tools
TIMER="time"
VERSION="CVS Head `date '+%Y-%m-%d %H:%M:%S'`"
BASE=build
OLDLISP="cmulisp -noinit"

SKIPUTILS=no

usage ()
{
    echo "build-l4 [-123obvuC]"
    echo "    -1        Skip build 1"
    echo "    -2        Skip build 2"
    echo "    -3        Skip build 3"
    echo "    -o x      Use specified Lisp to build.  Default is cmulisp"
    echo "               (only applicable for build 1)"
    echo '    -b d      The different build directoris are named ${d}-2, ${d}-3 ${d}-4'
    echo '               with a default of "build"'
    echo '    -v v      Use the given string as the version.  Default is'
    echo "               today's date"
    echo "    -u        Don't build CLX, CLM, or Hemlock"
    echo '    -C [l m]  Create the build directories.  The args are what'
    echo '               you would give to create-target.sh for the lisp'
    echo '               and motif variant.'

    exit 1
}

buildit ()
{
    if [ ! -d $TARGET ]; then
	if [ -n "$CREATE_DIRS" ]; then
	    $TOOLDIR/create-target.sh $TARGET $CREATE_OPT
	fi
    fi

    if [ "$ENABLE" = "yes" ]; 
    then
	$TOOLDIR/clean-target.sh $TARGET
	$TIMER $TOOLDIR/build-world.sh $TARGET $OLDLISP $BOOT
	(cd $TARGET/lisp; make)
	#$TOOLDIR/build-world.sh $TARGET $OLDLISP
	$TOOLDIR/load-world.sh $TARGET "$VERSION"
	if [ ! -f $TARGET/lisp/lisp.core ]; then
	    echo "Failed to build $TARGET!"
	    exit 1
	fi
    fi
}

while getopts "123o:b:v:uB:C:?" arg
do
    case $arg in
	1) ENABLE2="no" ;;
	2) ENABLE3="no" ;;
	3) ENABLE4="no" ;;
	o) OLDLISP=$OPTARG ;;
	b) BASE=$OPTARG ;;
	v) VERSION="$OPTARG" ;;
	u) SKIPUTILS="yes" ;;
	C) CREATE_OPT="$OPTARG"
	   CREATE_DIRS=yes ;;
	B) bootfiles="$bootfiles $OPTARG" ;;
	\\?) usage
	    ;;
    esac
done

bootfiles_dir=$SRCDIR/bootfiles/$version
if [ -n "$bootfiles" ]; then
    for file in $bootfiles; do
	BOOT="$BOOT -load $bootfiles_dir/$file"
    done
fi

TARGET=$BASE-2
ENABLE=$ENABLE2

buildit

bootfiles=

TARGET=$BASE-3
OLDLISP="${BASE}-2/lisp/lisp -noinit -core ${BASE}-2/lisp/lisp.core"
ENABLE=$ENABLE3

buildit

TARGET=$BASE-4
OLDLISP="${BASE}-3/lisp/lisp -noinit -core ${BASE}-3/lisp/lisp.core"
ENABLE=$ENABLE4

buildit

if [ "$SKIPUTILS" = "no" ];
then
    OLDLISP="${BASE}-4/lisp/lisp -noinit -core ${BASE}-4/lisp/lisp.core"
    $TIMER $TOOLDIR/build-utils.sh $TARGET
fi
