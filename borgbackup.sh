#!/bin/bash
#

set -o pipefail

## short hostname w/o domain
HOST=`hostname -s`

## timestamp with date
TS=`date +%Y-%m-%d_%H:%M`

## recipient for borg mails
EMAIL_RECIPIENT=admins@mail.de

## Log-directory
LOGDIR="/var/log/borgbackup"

## write output to logfile
LOGFILE="$LOGDIR/$HOST-$TS.log"

## Database backup directory
DBBACKUPDIR="/backup/database"

## don't start a backup when disk usage is above this percentage
DISK_PCT=95

## Cleanup logfiles and database dumps after these number of days
LOCAL_RETENTION=7

## enable/disable debugging
DEBUG=1

## path to borg repository
export BORG_REPO='/mnt/storagebox/it.vabr.de'

## borg passphrase for repokey
export BORG_PASSPHRASE='password'


## write stdout and stderr to logfile and console
exec > >(tee -ai $LOGFILE)
exec 2>&1


## Create logging directory if non-existent
if ! [ -d $LOGDIR ]; then
  mkdir -pv $LOGDIR
fi


## Create directory for database backups if non-existent
if ! [ -d $DBBACKUPDIR ]; then
  mkdir -pv $DBBACKUPDIR && chmod -Rv 0700 $DBBACKUPDIR
fi


## check disk usage
DISK_USAGE=`df $BORG_REPO | tail -1 | tr -s ' ' | cut -d ' ' -f5 | tr -d '%'`
if [ "$DISK_USAGE" -ge "$DISK_PCT" ]; then
  echo "Disc usage in percent: $DISK_USAGE on $BORG_REPO" | mail -s "WARNING DISK USAGE IS ABOVE $DISK_PCT% $HOST $TS" $EMAIL_RECIPIENT
  exit 1
fi


## Dump mysql to local backup directory that is included in borgbackup
create_mysql_dump() {
  echo "`date` - Starting MySQL Backup"




  for DB in `mysql -NB information_schema -e "select schema_name from schemata where schema_name not in ('information_schema','performance_schema');"`; do
    echo "`date` - Dumping database: $DB to: $DBBACKUPDIR/$DB-$TS.sql.gz"
    mysqldump --user=root --password=root $DB | gzip > $DBBACKUPDIR/$DB-$TS.sql.gz; dump_exit=$?
    dump_global_exit=$(($dump_global_exit+$dump_exit))
  done
}


## create new archive in repository
create_backup() {
  echo "`date` - Starting Borgbackup"
  borg create --verbose --show-rc --list --filter=AME --stats --exclude-from /mnt/storagebox/EXCLUDE ::$HOST-$TS /
  create_exit=$?
}


## delete obsolete backups
prune_backup() {
  echo "`date` - Starting pruning"
  borg prune --verbose --show-rc --list --keep-within=14d --keep-weekly=8 --keep-monthly=6
  prune_exit=$?
}


## delete obsolete files
prune_files() {
  echo "`date` - Delete database dumps"
  cd $DBBACKUPDIR && find . -type f -name \*.sql.gz -ctime +$LOCAL_RETENTION -exec rm -v {} \;
  echo "`date` - Delete logfiles"
  cd $LOGDIR && find . -type f -name \*.log -ctime +$LOCAL_RETENTION -exec rm -v {} \;
}


## create weekly report and execute a consistency check
weekly_report() {
  echo "`date` - Start repository check (borg check --repository-only)"
  borg check --verbose --repository-only; check_repo_exit=$?
  echo "`date` - Finished repository check with exit-code: $check_repo_exit"

  echo ""
  echo "`date` - Start archive check (borg check --archives-only)"
  borg check --verbose --archives-only; check_archive_exit=$?
  echo "`date` - Finished archive check with exit-code: $check_archive_exit"

  echo ""
  echo "`date` - Repository information (borg info)"
  borg info --verbose; info_exit=$?

  echo ""
  echo "`date` - Archives in $BORG_REPO (borg list)"
  borg list --verbose; list_exit=$?

  report_global_exit=$(($check_repo_exit+$check_archive_exit+$info_exit+$list_exit))

  if [ $report_global_exit -gt 0 ]; then
    SUBJECT="WARNING: Backup report"
    MSG="One or more commands exited with code other than zero, check attached logfile"
  else
    SUBJECT="OK: Backup report"
    MSG=""
  fi
}


## send email if backup failed or debug is enabled
send_mail() {
  echo $MSG | mutt -s "$SUBJECT" -a $LOGFILE -- $EMAIL_RECIPIENT
}


if [ $# -gt 0 ] && [ $1 == "report" ]; then
  weekly_report
  send_mail
  exit
else
  create_mysql_dump
  create_backup
  prune_backup
  prune_files
fi


global_exit=$(($dump_global_exit+$create_exit+$prune_exit))


## construct mail
if [ $DEBUG -eq 1 ]; then
	SUBJECT="OK: Backup successfully completed on $HOST"
	MSG=""
	send_mail
elif [ $global_exit -ne 0 ]; then
	SUBJECT="WARNING: Backup failed on $HOST"
	MSG="One or more commands exited with return code other than zero, check attached logfiles"
	send_mail
fi


exit ${global_exit}
