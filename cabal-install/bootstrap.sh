#!/usr/bin/env sh

# A script to bootstrap cabal-install.

# It works by downloading and installing the Cabal, zlib and
# HTTP packages. It then installs cabal-install itself.
# It expects to be run inside the cabal-install directory.

# install settings, you can override these by setting environment vars
#VERBOSE
#EXTRA_CONFIGURE_OPTS
#EXTRA_BUILD_OPTS
#EXTRA_INSTALL_OPTS

die () { printf "\nError during cabal-install bootstrap:\n$1\n" >&2 && exit 2 ;}

# programs, you can override these by setting environment vars
GHC="${GHC:-ghc}"
GHC_PKG="${GHC_PKG:-ghc-pkg}"
GHC_VER="$(${GHC} --numeric-version)"
HADDOCK=${HADDOCK:-haddock}
WGET="${WGET:-wget}"
CURL="${CURL:-curl}"
FETCH="${FETCH:-fetch}"
TAR="${TAR:-tar}"
GZIP="${GZIP:-gzip}"
SCOPE_OF_INSTALLATION="--user"
DEFAULT_PREFIX="${HOME}/.cabal"

# Try to respect $TMPDIR but override if needed - see #1710.
[ -"$TMPDIR"- = -""- ] || echo "$TMPDIR" | grep -q ld &&
  export TMPDIR=/tmp/cabal-$(echo $(od -XN4 -An /dev/random)) && mkdir $TMPDIR

# Check for a C compiler.
[ ! -x "$CC" ] && for ccc in gcc clang cc icc; do
  ${ccc} --version > /dev/null 2>&1 && CC=$ccc &&
  echo "Using $CC for C compiler. If this is not what you want, set CC." >&2 &&
  break
done

# None found.
[ ! -x `which "$CC"` ] &&
  die "C compiler not found (or could not be run).
       If a C compiler is installed make sure it is on your PATH,
       or set the CC variable."

# Check the C compiler/linker work.
LINK="$(for link in collect2 ld; do
  echo 'main;' | ${CC} -v -x c - -o /dev/null -\#\#\# 2>&1 | grep -q $link &&
  echo 'main;' | ${CC} -v -x c - -o /dev/null -\#\#\# 2>&1 | grep    $link |
  sed -e "s|\(.*$link\).*|\1|" -e 's/ //g' -e 's|"||' && break
done)"

# They don't.
[ -z "$LINK" ] &&
  die "C compiler and linker could not compile a simple test program.
       Please check your toolchain."

## Warn that were's overriding $LD if set (if you want).

[ -x "$LD" ] && [ "$LD" != "$LINK" ] &&
  echo "Warning: value set in $LD is not the same as C compiler's $LINK." >&2
  echo "Using $LINK instead." >&2

# Set LD, overriding environment if necessary.
LD=$LINK

# Check we're in the right directory, etc.
grep "cabal-install" ./cabal-install.cabal > /dev/null 2>&1 ||
  die "The bootstrap.sh script must be run in the cabal-install directory"

${GHC} --numeric-version > /dev/null 2>&1  ||
  die "${GHC} not found (or could not be run).
       If ghc is installed,  make sure it is on your PATH,
       or set the GHC and GHC_PKG vars."

${GHC_PKG} --version     > /dev/null 2>&1  || die "${GHC_PKG} not found."

GHC_VER="$(${GHC} --numeric-version)"
GHC_PKG_VER="$(${GHC_PKG} --version | cut -d' ' -f 5)"

[ ${GHC_VER} = ${GHC_PKG_VER} ] ||
  die "Version mismatch between ${GHC} and ${GHC_PKG}.
       If you set the GHC variable then set GHC_PKG too."

for arg in "$@"
do
  case "${arg}" in
    "--user")
      SCOPE_OF_INSTALLATION=${arg}
      shift;;
    "--global")
      SCOPE_OF_INSTALLATION=${arg}
      DEFAULT_PREFIX="/usr/local"
      shift;;
    "--no-doc")
      NO_DOCUMENTATION=1
      shift;;
    *)
      echo "Unknown argument or option, quitting: ${arg}"
      echo "usage: bootstrap.sh [OPTION]"
      echo
      echo "options:"
      echo "   --user    Install for the local user (default)"
      echo "   --global  Install systemwide (must be run as root)"
      echo "   --no-doc  Do not generate documentation for installed packages"
      exit;;
  esac
done

# Check for haddock unless no documentation should be generated.
if [ ! ${NO_DOCUMENTATION} ]
then
  ${HADDOCK} --version     > /dev/null 2>&1  || die "${HADDOCK} not found."
fi

PREFIX=${PREFIX:-${DEFAULT_PREFIX}}

# Versions of the packages to install.
# The version regex says what existing installed versions are ok.
PARSEC_VER="3.1.5";    PARSEC_VER_REGEXP="[23]\."
                       # == 2.* || == 3.*
DEEPSEQ_VER="1.3.0.2"; DEEPSEQ_VER_REGEXP="1\.[1-9]\."
                       # >= 1.1 && < 2
TEXT_VER="1.1.0.1";    TEXT_VER_REGEXP="((1\.[01]\.)|(0\.([2-9]|(1[0-1]))\.))"
                       # >= 0.2 && < 1.2
NETWORK_VER="2.5.0.0"; NETWORK_VER_REGEXP="2\."
                       # == 2.*
CABAL_VER="1.19.2";    CABAL_VER_REGEXP="1\.1[9]\."
                       # >= 1.19 && < 1.20
TRANS_VER="0.3.0.0";   TRANS_VER_REGEXP="0\.[23]\."
                       # >= 0.2.* && < 0.4.*
MTL_VER="2.1.3.1";     MTL_VER_REGEXP="[2]\."
                       #  == 2.*
HTTP_VER="4000.2.12";  HTTP_VER_REGEXP="4000\.2\.([5-9]|1[0-9]|2[0-9])"
                       # >= 4000.2.5 && < 4001
ZLIB_VER="0.5.4.1";    ZLIB_VER_REGEXP="0\.[45]\."
                       # == 0.4.* || == 0.5.*
TIME_VER="1.4.2"       TIME_VER_REGEXP="1\.[1234]\.?"
                       # >= 1.1 && < 1.5
RANDOM_VER="1.0.1.1"   RANDOM_VER_REGEXP="1\.0\."
                       # >= 1 && < 1.1
STM_VER="2.4.3";       STM_VER_REGEXP="2\."
                       # == 2.*

HACKAGE_URL="https://hackage.haskell.org/package"

# Cache the list of packages:
echo "Checking installed packages for ghc-${GHC_VER}..."
${GHC_PKG} list --global ${SCOPE_OF_INSTALLATION} > ghc-pkg.list ||
  die "running '${GHC_PKG} list' failed"

# Will we need to install this package, or is a suitable version installed?
need_pkg () {
  PKG=$1
  VER_MATCH=$2
  if egrep " ${PKG}-${VER_MATCH}" ghc-pkg.list > /dev/null 2>&1
  then
    return 1;
  else
    return 0;
  fi
  #Note: we cannot use "! grep" here as Solaris 9 /bin/sh doesn't like it.
}

info_pkg () {
  PKG=$1
  VER=$2
  VER_MATCH=$3

  if need_pkg ${PKG} ${VER_MATCH}
  then
    echo "${PKG}-${VER} will be downloaded and installed."
  else
    echo "${PKG} is already installed and the version is ok."
  fi
}

fetch_pkg () {
  PKG=$1
  VER=$2

  URL=${HACKAGE_URL}/${PKG}-${VER}/${PKG}-${VER}.tar.gz
  if which ${CURL} > /dev/null
  then
    # TODO: switch back to resuming curl command once
    #       https://github.com/haskell/hackage-server/issues/111 is resolved
    #${CURL} -L --fail -C - -O ${URL} || die "Failed to download ${PKG}."
    ${CURL} -L --fail -O ${URL} || die "Failed to download ${PKG}."
  elif which ${WGET} > /dev/null
  then
    ${WGET} -c ${URL} || die "Failed to download ${PKG}."
  elif which ${FETCH} > /dev/null
    then
      ${FETCH} ${URL} || die "Failed to download ${PKG}."
  else
    die "Failed to find a downloader. 'curl', 'wget' or 'fetch' is required."
  fi
  [ -f "${PKG}-${VER}.tar.gz" ] ||
     die "Downloading ${URL} did not create ${PKG}-${VER}.tar.gz"
}

unpack_pkg () {
  PKG=$1
  VER=$2

  rm -rf "${PKG}-${VER}.tar" "${PKG}-${VER}"
  ${GZIP} -d < "${PKG}-${VER}.tar.gz" | ${TAR} -x
  [ -d "${PKG}-${VER}" ] || die "Failed to unpack ${PKG}-${VER}.tar.gz"
}

install_pkg () {
  PKG=$1

  [ -x Setup ] && ./Setup clean
  [ -f Setup ] && rm Setup

  ${GHC} --make Setup -o Setup ||
    die "Compiling the Setup script failed."

  [ -x Setup ] || die "The Setup script does not exist or cannot be run"

  args="${SCOPE_OF_INSTALLATION} --prefix=${PREFIX} --with-compiler=${GHC}"
  args="$args --with-hc-pkg=${GHC_PKG} --with-gcc=${CC} --with-ld=${LD}"
  args="$args ${EXTRA_CONFIGURE_OPTS} ${VERBOSE}"

  ./Setup configure $args || die "Configuring the ${PKG} package failed."

  ./Setup build ${EXTRA_BUILD_OPTS} ${VERBOSE} ||
     die "Building the ${PKG} package failed."

  if [ ! ${NO_DOCUMENTATION} ]
  then
    ./Setup haddock --with-ghc=${GHC} --with-haddock=${HADDOCK} ${VERBOSE} ||
      die "Documenting the ${PKG} package failed."
  fi

  ./Setup install ${SCOPE_OF_INSTALLATION} ${EXTRA_INSTALL_OPTS} ${VERBOSE} ||
     die "Installing the ${PKG} package failed."
}

do_pkg () {
  PKG=$1
  VER=$2
  VER_MATCH=$3

  if need_pkg ${PKG} ${VER_MATCH}
  then
    echo
    echo "Downloading ${PKG}-${VER}..."
    fetch_pkg ${PKG} ${VER}
    unpack_pkg ${PKG} ${VER}
    cd "${PKG}-${VER}"
    install_pkg ${PKG} ${VER}
    cd ..
  fi
}

# Actually do something!

info_pkg "deepseq"      ${DEEPSEQ_VER} ${DEEPSEQ_VER_REGEXP}
info_pkg "time"         ${TIME_VER}    ${TIME_VER_REGEXP}
info_pkg "Cabal"        ${CABAL_VER}   ${CABAL_VER_REGEXP}
info_pkg "transformers" ${TRANS_VER}   ${TRANS_VER_REGEXP}
info_pkg "mtl"          ${MTL_VER}     ${MTL_VER_REGEXP}
info_pkg "text"         ${TEXT_VER}    ${TEXT_VER_REGEXP}
info_pkg "parsec"       ${PARSEC_VER}  ${PARSEC_VER_REGEXP}
info_pkg "network"      ${NETWORK_VER} ${NETWORK_VER_REGEXP}
info_pkg "HTTP"         ${HTTP_VER}    ${HTTP_VER_REGEXP}
info_pkg "zlib"         ${ZLIB_VER}    ${ZLIB_VER_REGEXP}
info_pkg "random"       ${RANDOM_VER}  ${RANDOM_VER_REGEXP}
info_pkg "stm"          ${STM_VER}     ${STM_VER_REGEXP}

do_pkg   "deepseq"      ${DEEPSEQ_VER} ${DEEPSEQ_VER_REGEXP}
do_pkg   "time"         ${TIME_VER}    ${TIME_VER_REGEXP}
do_pkg   "Cabal"        ${CABAL_VER}   ${CABAL_VER_REGEXP}
do_pkg   "transformers" ${TRANS_VER}   ${TRANS_VER_REGEXP}
do_pkg   "mtl"          ${MTL_VER}     ${MTL_VER_REGEXP}
do_pkg   "text"         ${TEXT_VER}    ${TEXT_VER_REGEXP}
do_pkg   "parsec"       ${PARSEC_VER}  ${PARSEC_VER_REGEXP}
do_pkg   "network"      ${NETWORK_VER} ${NETWORK_VER_REGEXP}
do_pkg   "HTTP"         ${HTTP_VER}    ${HTTP_VER_REGEXP}
do_pkg   "zlib"         ${ZLIB_VER}    ${ZLIB_VER_REGEXP}
do_pkg   "random"       ${RANDOM_VER}  ${RANDOM_VER_REGEXP}
do_pkg   "stm"          ${STM_VER}     ${STM_VER_REGEXP}

install_pkg "cabal-install"

echo
echo "==========================================="
CABAL_BIN="$PREFIX/bin"
if [ -x "$CABAL_BIN/cabal" ]
then
    echo "The 'cabal' program has been installed in $CABAL_BIN/"
    echo "You should either add $CABAL_BIN to your PATH"
    echo "or copy the cabal program to a directory that is on your PATH."
    echo
    echo "The first thing to do is to get the latest list of packages with:"
    echo "  cabal update"
    echo "This will also create a default config file (if it does not already"
    echo "exist) at $HOME/.cabal/config"
    echo
    echo "By default cabal will install programs to $HOME/.cabal/bin"
    echo "If you do not want to add this directory to your PATH then you can"
    echo "change the setting in the config file, for example you could use:"
    echo "symlink-bindir: $HOME/bin"
else
    echo "Sorry, something went wrong."
    echo "The 'cabal' executable was not successfully installed into"
    echo "$CABAL_BIN/"
fi
echo

rm ghc-pkg.list
