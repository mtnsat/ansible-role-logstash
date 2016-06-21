#!/bin/bash

#  script that will be scheduled to run in cron by chef and it will:
#   - create 'current-run' file
#   - create a list of all files that have been modified since last run,
#     if no old current-run file,  assume its never been run and process
#     all files
#   - copy list of files to new location (copy!  not move!  copy!)
#   +NOTE! just going to push them up to S3.  its fine, whatever, the OS will
#     serialize access to the file.  each record is timestamped and we're doing
#     a full overwrite each time so just, you know, whatever's there can go
#     up
#   - check list of copied files against what exists in S3, if any duplicates,
#     append the next digit (starting with .1 for the first copy) to the
#     filename, then push to S3
#   +NOTE! do not need to check if file exists in S3.  each upload is a full copy
#     of the file.  overwrite is preferred.
#   - move 'current-run' file to 'last-run' file
#   - drop a status file with GOOD/BAD/OTHER after run
#     - GOOD: no errors
#     - BAD:  any errors, include errors
#     - OTHER:  something happened but it wasn't explicity caught

#  TODO:  collapse into a single for loop over 'file_list'

# set globals/command line processing
OPTIND=1
remove_archived_files=false
while getopts "a:h:b:f" opt; do
case "$opt" in
a)
  archive_directory=$OPTARG
  ;;
h)
  host_name=$OPTARG
  ;;
b)
  s3bucket=$OPTARG
  ;;
f)
  remove_archived_files=true
  ;;
esac
done

#  check 'em
if [[ ! -d $archive_directory ]]; then
echo "CRITICAL: specified archive directory ${archive_directory} is not a directory or does not exist"
exit 1
elif [[ "X${host_name}" == "X" ]]; then
echo "CRITICAL: did not pass in host_name from chef!"
exit 1
elif [[ "X${s3bucket}" == "X" ]]; then
echo "CRITICAL: did not pass in bucket name"
exit 1
fi


#  check another backup run isn't going now
dummy=`ls $archive_directory/current-run 2>&1 >> /dev/null`
currun_exists=$?
if [[ $currun_exists -eq 0 ]]; then
echo "WARNING: archiver already running"
exit 0
fi

#  begin backup alg
#   need to put something in it or aws cli will bomb trying to shove up an empty file
echo "fine me and exclude me, I am a timing file" > $archive_directory/current-run

declare -a file_list
#  find all files to copy!
for arch_file in `ls $archive_directory`; do
if [[ -f $archive_directory/last-run ]]; then
  if [[ $archive_directory/last-run -ot $archive_directory/$arch_file ]]; then
    file_list[${#file_list[@]}]=$arch_file
  fi
else
  file_list[${#file_list[@]}]=$arch_file
fi
done

#  copy them to s3!
count=0
for copy_file in "${file_list[@]}"; do
# grep for pattern 20YY-MM-DD.
# head -1 was added since incorrect file name e.g."2014-06-24T02,2014-06-24T02.gz" resolves to day_marker="2014-06-24 2014-06-24"
  day_marker=$(echo $copy_file|grep -Eo "20[0-9]{2}-[0-9]{2}-[0-9]{2}"|head -1)
  if [ ${#day_marker} != 10 ]; then
    continue
  fi
  root_key="hourly-logstash-dumps/${day_marker}/${host_name}"

  copy_to_s3_status=1
  retry_count=0
  source_file=${archive_directory}/${copy_file}
  destination_file="s3://${s3bucket}/${root_key}/${copy_file}"
  until [ $copy_to_s3_status -eq 0 ] || [ $retry_count -ge 3 ]; do
    err=`/usr/local/bin/aws --region us-east-1 s3 cp ${source_file} ${destination_file}`
    copy_to_s3_status=$?
    if [[ $copy_to_s3_status -ne 0 ]]; then
      echo "WARNING: Failed to archive file $copy_file: $copy_to_s3_status - ${err}"
    fi
    let "retry_count=retry_count+1"
  done

  if [[ $copy_to_s3_status -ne 0 ]]; then
    echo "CRITICAL: Failed to archive file $copy_file: $copy_to_s3_status - ${err}"
    break
  else
    echo "OK: archived ${source_file} to ${destination_file}"
  fi
  count=$(($count + 1))
done

if [[ $copy_to_s3_status -ne 0 ]]; then
  rm $archive_directory/current-run
else
  mv $archive_directory/current-run $archive_directory/last-run
  if $remove_archived_files; then
    echo "OK: removing successfully archived files"
    find ${archive_directory} \
      -not -newer ${archive_directory}/last-run \
      -not -name last-run \
      -not -name $(basename $0) \
      -not -name aws_cli_profile.conf \
      -type f \
      -exec rm -v {} \;
  fi
fi
echo "OK: Successfully archived ${count} files to S3.  Done."
