#!/usr/bin/env bash

# of-serverclean.sh v1.00 (16th June 2023)
#  Cleans up the build server if space is getting tight.


if [[ "$#" -lt 1 ]]; then
	echo "Usage: $0 <targets_file>"
	echo
	echo "  targets_file:  Plain text file where each line represents a target directory."
	echo
	exit 1
fi


target_directories_file="$1"
threshold_space=5000000 # 5 GB in kilobytes

current_date=$(date +%s)
three_months_ago=$(date -d "12 months ago" +%s)


remove_old_directories() {

	local target_dir=$1

	for dir in "$target_dir"/*; do
		if [[ -d "$dir" ]]; then

			last_modified=$(stat -c %Y "$dir")

			if [[ $last_modified -lt $three_months_ago ]]; then
			echo "Removing directory: $dir"
			rm -rf "$dir"
			fi
			
		fi
	done

}

readarray -t target_directories < "$target_directories_file"

available_space=$(df -Pk | grep "sda1 " | awk '{print $4}')

if [[ $available_space -lt $threshold_space ]]; then

	# Loop through the target directories
	for dir in "${target_directories[@]}"; do

		remove_old_directories "$dir"

	done

else

	echo "Available disk space is sufficient."

fi
