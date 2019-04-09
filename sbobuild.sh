#!/bin/bash
set -e

# This must be run as root.
if [ $UID -ne 0 ]; then
    echo This program must be run as root, invoking sudo... >&2
    exec sudo "$0" "$@"
fi
# But, there are commands that should be invoked as the original user
# to avoid creating root-owned files in user-owned directories.
if [ -n "$SUDO_USER" ]; then
    MAYBE_SUDO="sudo -u $SUDO_USER"
fi

function usage () {
    echo Usage: sbobuild.sh PACKAGE-NAME ... >&2
    exit 1
}

# Get the default value for a variable from a SlackBuild file.
function sbvar ()
{
    pattern="\${$1:-"
    grep "$pattern" $PRG.SlackBuild | sed "s|.*$pattern||;s|}||"
}

while [ $# -gt 1 ]; do
    "$0" "$1"
    shift
done

if [ $# -ne 1 ]; then usage; fi
PRG="$1"

GIT="$MAYBE_SUDO git"
if [ ! -d slackbuilds ]; then
    echo "Slackbuild repository not found... " >&2
    $GIT clone --depth 1 git://git.slackbuilds.org/slackbuilds.git
else
    (cd slackbuilds; $GIT fetch)
fi
source /etc/os-release
TAG=$(cd slackbuilds; git tag | grep ^$VERSION | tail -n 1)
(cd slackbuilds; $GIT checkout $TAG 2>/dev/null)

basedir=$(pwd)
function pkgdir () {
    find $basedir/slackbuilds -name "$1" -type d
}

function libfile () {
    echo $(pkgdir "$1" | sed 's=/slackbuilds/=/lib/=').$2
}

PKGDIR=$(pkgdir "$PRG")
if [ -z "$PKGDIR" ]; then
    echo Package \"$PRG\" not found. >&2
    exit 2
fi

OUTPUTDIR=$(echo $PKGDIR | sed 's=^slackbuilds/=packages/=' | xargs dirname)
if [ ! -d "$OUTPUTDIR" ]; then
    $MAYBE_SUDO mkdir -p $OUTPUTDIR
fi

source $PKGDIR/$PRG.info

# A program may have a .infovars file that will be sourced.  It can
# override values in the SlackBuild's .info file and the variables set
# in it will be set in the environment of the SlackBuild.
IVFILE=$(libfile $PRG infovars)
if [ -f "$IVFILE" ]; then
    source $IVFILE
fi

if [ x"$PRG" != x"$PRGNAM" ]; then
    echo Looking for $PRG SlackBuild. Found $PRGNAM. >&2
    exit 2
fi

if [ -n "$REQUIRES" ]; then
    echo $PRG requires $REQUIRES

    # One of the tricky things in building SlackBuilds that have
    # nested dependencies is being sure that all the environment
    # changes made in a branch or leaf are passed back to all higher-
    # level dependents.  A process-specific ENVFILE will be used for
    # this purpose.
    ENVFILE=/tmp/sboenv
    touch $ENVFILE.$$

    for req in $REQUIRES; do
	$0 $req

	# If the requirement has a file that makes environment
	# changes, be sure we source it exactly once in our ENVFILE.
	REQENV=$(libfile $req env)
	REQVAR=$(echo $req | sed 's/-/_/g')
	if [ -f "$REQENV" ]; then
	    cat - >> $ENVFILE.$$ <<EOF
test -z ${REQVAR}_SOURCED || source $REQENV
export ${REQVAR}_SOURCED=true
EOF
	fi
    done

    # If our parent process has an ENVFILE, add ours to it to
    # propagate back the changes.
    if [ -f $ENVFILE.$PPID ]; then
	cat $ENVFILE.$$ >> $ENVFILE.$PPID
    fi

    # Finally source and delete our ENVFILE to pickup everything we or
    # our requirements wrote there.
    source $ENVFILE.$$
    rm $ENVFILE.$$
fi

ARCH=$(uname -m)
if [ "$ARCH" = x86_64 ]; then
    DOWNLOAD="${DOWNLOAD_x86_64:-$DOWNLOAD}"
    MD5SUM="${MD5SUM_x86_64:-$MD5SUM}"
fi

cd $PKGDIR

BUILD=$(sbvar BUILD)
TAG=$(sbvar TAG)
PKGTYPE=$(sbvar PKGTYPE)
PKGFILE=$PRG-$VERSION-$ARCH-$BUILD$TAG.$PKGTYPE

# This script only copies the package file to OUTPUTDIR after installing it.
# If it exists, the package has been built and installed already.
if [ -f $OUTPUTDIR/$PKGFILE ]; then
    exit
fi

for dl in $DOWNLOAD; do
    ARCHIVE=$(basename $dl)
    if [ -e "$ARCHIVE" ]; then
	if echo "$MD5SUM" | grep -q $(md5sum $ARCHIVE | cut -f1 -d ' '); then
	    NO_DL=1
	else
	    OPT=-c
	fi
    fi
    if [ -z "$NO_DL" ]; then
	$MAYBE_SUDO wget $OPT $dl
    else
	unset NO_DL
    fi

    if echo "$MD5SUM" | grep -q $(md5sum $ARCHIVE | cut -f1 -d ' '); then
	:
    else
	echo Checksum mismatch on $ARCHIVE in $PKGDIR. >&2
	exit 3
    fi
done

# Prefiles may be used to handle any extra setup that is needed before
# the SlackBuild is run.
PREFILE=$(libfile $PRG pre)
if [ -f $PREFILE ]; then
    eval $PREFILE
fi

chmod +x $PRG.SlackBuild
pwd
if [ -f "$IVFILE" ]; then
    # The sed expression allows for end-of-line backslash
    # continuation, removing the slash and newline, and dequoting
    # variable values to avoid problems with env.
    #     IFS='
    # ' env "`cat $IVFILE | sed '/\\\\$/{s=\\\\$==;N;s= [ \t]*= =g;s=\\n==};s/="/=/;s/"$//'`" /bin/sh -x ./$PRG.SlackBuild

    # Remove any comments and backslash escape all unescaped newlins
    # in the .infovars file and append a call to the SlackBuild
    # effectively prefixing all the variables to the command.
    (sed 's/#.*//;/[^\\]$/s/$/ \\/' $IVFILE; echo ./$PRG.SlackBuild) | sh
else
    ./$PRG.SlackBuild
fi
chmod -x $PRG.SlackBuild

echo $PRG built.
cd - >/dev/null

/sbin/installpkg /tmp/$PKGFILE
if [ -n "$SUDO_UID" ]; then
    chown $SUDO_UID:$SUDO_GID /tmp/$PKGFILE
fi

# Post install scripts should be executable and produce the same
# results when rerun.
POST=$(libfile $PRG post)
if [ -x "$POST" ]; then
    echo Executing post-install script for $PRG... >&2
    "$POST"
    echo Done. >&2
fi

# Once fullying installed
mv /tmp/$PKGFILE $OUTPUTDIR

echo
cat $PKGDIR/README

while true; do
    read -er -N 1 -p "Does anything special need to be done? [Yn]" RESPONSE

    case $RESPONSE in
	Y|y)
	    echo After taking care of it, type exit to continue. >&2
	    $SHELL
	    break
	    ;;
	N|n)
	    break
	    ;;
    esac
done
