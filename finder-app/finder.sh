#!/bin/sh

if [ $# -ne 2 ]
then
	echo "Error: Two arguments required"
	exit 1
fi

filesdir=$1
searchstr=$2

if [ ! -d "$filesdir" ]
then
	echo "Error: $filesdir is not a directory"
	exit 1
fi

filecount=$(find "$filesdir" -type f | wc -l)
matchcount=$(grep -r "$searchstr" "$filesdir" | wc -l)

echo "The number of files are $filecount and the number of matching lines are $matchcount"
