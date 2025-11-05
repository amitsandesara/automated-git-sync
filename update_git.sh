#!/bin/bash

cd ~/code

echo "Start: `date "+%Y-%m-%d %H:%M:%S"`"
echo "-------------------------------------------------------------------------------------------------------------------"
ls
echo "-------------------------------------------------------------------------------------------------------------------"

for dir in */ ; do
    if [ "$dir" == "logs" ]
    then
        continue
    fi

	cd $dir
    echo "Repo: $dir"
    
    current_branch=$(git symbolic-ref HEAD | sed -e 's,.*/\(.*\),\1,')
    echo "Current branch: $current_branch"
    
    local_changes=false
    if [ $(git status --porcelain | wc -l) -eq "0" ]; 
    then
        echo "  No local changes."
    else
    local_changes=true
        echo "  Stashing Changes."
	    git stash
    fi
    
    if [ `git rev-parse --verify master 2>/dev/null` ] 
    then
        if [ "$current_branch" != "master" ]
        then
            git checkout master
        fi
    else
        if [ "$current_branch" != "main" ]
        then
            git checkout main
        fi
    fi

    git pull

    git checkout $current_branch
    if [ "$local_changes" == true ]
    then
        echo "  Popping stash back to $current_branch"
        git stash pop
    fi

    cd ..
    
    echo "---------------------------------------------------------------------------------------------------------------------------------------------------------"
done

echo "Finished github repo sync"
echo "End: `date "+%Y-%m-%d %H:%M:%S"`"
