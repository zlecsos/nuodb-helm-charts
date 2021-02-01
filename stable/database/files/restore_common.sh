#!/bin/bash

[ "$NUODB_DEBUG" = "verbose" ] && set -x
[ "$NUOSM_VALIDATE" = "true" ] && set -e

. "${NUODB_HOME}/etc/nuodb_setup.sh"

: ${NUODB_ARCHIVEDIR:=/var/opt/nuodb/archive}
: ${NUODB_BACKUPDIR:=/var/opt/nuodb/backup}
: ${NUODB_STORAGE_PASSWORDS_DIR:=/etc/nuodb/tde}
: ${NUODB_DOMAIN:="nuodb"}
: ${DB_NAME:="demo"}

DB_PARENTDIR=${NUODB_ARCHIVEDIR}/${NUODB_DOMAIN}
DB_DIR=${DB_PARENTDIR}/${DB_NAME}

LOGFILE=${NUODB_LOGDIR:=/var/log/nuodb}/restore.log

#=======================================
# function - log messages
#
function log() {
  local message="$@"
  if [ -n "$message" ]; then
    echo "$( date "+%Y-%m-%dT%H:%M:%S.%3N%z" ) $message" | tee -a $LOGFILE
  fi
}

#=======================================
# function - wrap a log file around so it doesn't grow infinitely
#
function wrapLogfile() {
  logsize=$( du -sb $LOGFILE | grep -o '^ *[0-9]\+' )
  maxlog=5000000
  log "logsize=$logsize; maxlog=$maxlog"
  if [ ${logsize:=0} -gt $maxlog ]; then
    lines=$(wc -l $LOGFILE)
    tail -n $(( lines / 2 )) $LOGFILE > ${LOGFILE}-new
    rm -rf $LOGFILE
    mv $LOGFILE-new $LOGFILE
    log "log file wrapped around"
  fi
}

function isUrl() {
  local url="$1"
  echo "$url" | grep -q '^[a-z]\+:/[^ ]\+'
  return $?
}

function isRestoreSourceAvailable() {
  local source="$1"
  isUrl "$source" || [ -d "$NUODB_BACKUPDIR/$source" ]
  return $?
}

#=======================================
# function - NuoDB 4.2.2+ supports new way of requesting database in-place
# restore build into nuodocker.
#
function isRestoreRequestSupported() {
   nuodocker request restore -h > /dev/null 2>&1
   if [ $? -eq 2 ]; then
      return 1
   else
      return 0
   fi
}

#=======================================
# function to perform archive restore
#
# If the restore is successful:
# * the archive dir contents will have been copied in;
# * the archive dir metadata will have been reset;
# * a new corresponding archive object will have been created in Raft.
#
# On error, any copy of the replaced archive is retained.
#
function perform_restore() {
  local restore_source_encoded="$1"
  local restore_credentials_encoded="$2"
  local restore_type="$3"
  local strip_levels="$4"

  local restore_source="$(printf "%s" "${restore_source_encoded}" | base64 -d)"
  local restore_credentials="$(printf "%s" "${restore_credentials_encoded}" | base64 -d)"
  local retval=0
  local archSize=
  local archSpace=
  local saveName=
  local undo=
  local tarfile=
  local download_dir=
  local curl_creds=

  # Global variable used to hold the restore error message
  error=

  log "Restoring $restore_source; existing archive directores: $( ls -l $DB_PARENTDIR )"

  # work out available space
  archSize="$(du -s $DB_DIR | grep -o '^ *[0-9]\+')"
  archSpace="$(df --output=avail $DB_DIR | grep -o ' *[0-9]\+')"

  if [ $(( archSpace > archSize * 2)) ]; then
    saveName="${DB_DIR}-save-$( date +%Y%m%dT%H%M%S )"
    undo="mv $saveName $DB_DIR"
    mv $DB_DIR $saveName
     
    retval=$?
    if [ $retval -ne 0 ]; then
      $undo
      error="Error moving archive in preparation for restore"
      return $retval
    fi
  else
    tarfile="${DB_DIR}-$( date +%Y%m%dT%H%M%S ).tar.gz"
    tar czf $tarfile -C $DB_PARENTDIR $DB_NAME

    retval=$?
    if [ $retval -ne 0 ]; then
      rm -rf $tarfile
      error="Restore: unable to save existing archive to TAR file"
      return $retval
    fi

    archSpace="$(df --output=avail $DB_DIR | grep -o ' *[0-9]\+')"
    if [ $(( archSize + 1024000 > archSpace )) ]; then
      rm -rf $tarfile
      error="Insufficient space for restore after archive has been saved to TAR."
      return 1
    fi

    undo="tar xf $tarfile -C $DB_PARENTDIR"
    rm -rf $DB_DIR
  fi

  mkdir $DB_DIR

  log "(restore) recreated $DB_DIR; atoms=$( ls -l $DB_DIR/*.atm 2>/dev/null | wc -l)"

  # restore request is a URL - so retrieve the backup using curl
  if isUrl "$restore_source"; then

    # define the download directory depending on the type of source
    if [ "$restore_type" = "stream" ]; then
      download_dir=$DB_DIR
    else
      # It is a backupset so switch the download to somewhere temporary available on all SMs (it will be removed later)
      # This will also run if TYPE is unrecognised, since it works for either type, but will be less efficient.
      download_dir=$(basename $restore_source)
      download_dir="${DB_PARENTDIR}/$(basename $download_dir .${download_dir#*.})-downloaded"
      mkdir $download_dir
    fi

    [ -n "$restore_credentials" -a "$restore_credentials" != ":" ] && curl_creds="--user $restore_credentials"
    [ -n "$curl_creds" ] && curl_opts="--user *:*"

    log "curl -k $curl_opts $restore_source | tar xzf - --strip-components $strip_levels -C $download_dir"
    curl -k $curl_creds "$restore_source" | tar xzf - --strip-components $strip_levels -C $download_dir

    retval=$?
    if [ $retval -ne 0 ]; then
      $undo
      error="Restore: unable to download/unpack backup $restore_source"
      return $retval
    fi

    chown -R $(echo "${NUODB_OS_USER:-1000}:${NUODB_OS_GROUP:-0}" | tr -d '"') $download_dir

    # restore data and/or fix the metadata
    log "restoring archive and/or clearing restored archive physical metadata"
    status="$(nuodocker restore archive \
      --origin-dir $download_dir \
      --restore-dir $DB_DIR \
      --db-name $DB_NAME \
      --clean-metadata 2>&1)"
    retval=$?
    log "$status"

    if [ "$download_dir" != "$DB_DIR" ]; then
      log "removing $download_dir"
      rm -rf $download_dir
    fi

  else
    # log "Calling nuoarchive to restore $restore_source into $DB_DIR"
    log "Calling nuodocker to restore $restore_source into $DB_DIR"
    status="$(nuodocker restore archive \
      --origin-dir $NUODB_BACKUPDIR/$restore_source \
      --restore-dir $DB_DIR \
      --db-name $DB_NAME \
      --clean-metadata 2>&1)"
    retval=$?
    log "$status"
  fi

  if [ $retval -ne 0 ]; then
    $undo
    error="Restore: unable to restore source=$restore_source type=$restore_type into $DB_DIR"
    return $retval
  fi
  
  [ -n "$NUODB_DEBUG" ] && ls -l $DB_DIR

  return 0
}