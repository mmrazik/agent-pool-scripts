#!/bin/bash
# script for the RM extension install step
LOGFILE="/var/log/enableagent.log"


log_message()
{
    message=$1
    timestamp="$(date -u +'%F %T')"
    echo "$timestamp" "$message"
    echo "$timestamp" "$message" >> "$LOGFILE"
}

decode_string() 
{
    echo "$1" | sed 's/+/ /g; s/%/\\x/g;' | xargs -0 printf '%b' # substitute + with space and % with \x
}

log_message "version 13"

# load environment variables if file is present
if (test -f "/etc/profile.d/agent_env_vars.sh"); then
    source /etc/profile.d/agent_env_vars.sh
fi

# We require 3 inputs: $1 is url, $2 is pool, $3 is PAT
# 4th input is option $4 is either '--once' or null
url=$1
pool=$2
token=$3
runArgs=$4

log_message "Url is $url"
log_message "Pool is $pool"
log_message "RunArgs is $runArgs"

# get the folder where the script is executing
dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

log_message "Directory is $dir"

# Check if the agent was previously configured.  If so then abort
if (test -f "$dir/.agent"); then
    log_message "Agent was already configured. Doing nothing."
    exit
fi

# Create our user account if it does not exist already
if id AzDevOps &>/dev/null; then
    log_message "AzDevOps account already exists"
else
    log_message "Creating AzDevOps account"
    sudo useradd -m AzDevOps
    sudo usermod -a -G docker AzDevOps
    sudo usermod -a -G adm AzDevOps
    sudo usermod -a -G sudo AzDevOps

    log_message "Giving AzDevOps user access to the '/home' directory"
    sudo chmod -R +r /home
    setfacl -Rdm "u:AzDevOps:rwX" /home
    setfacl -Rb /home/AzDevOps
    echo 'AzDevOps ALL=NOPASSWD: ALL' >> /etc/sudoers
fi

# unzip the agent files
zipfile=$(find $dir/vsts-agent*.tar.gz)
log_message "Zipfile is $zipfile"

if !(test -f "$dir/bin/Agent.Listener"); then
    log_message "Unzipping agent"
    OUTPUT=$(tar -xvf  $zipfile -C $dir 2>&1 > /dev/null)
    retValue=$?
    log_message "$OUTPUT"
    if [ $retValue -ne 0 ]; then
        log_message "Agent unzipping failed"
        exit 100
    fi
fi

rm $zipfile
cd $dir

# grant broad permissions in the agent folder
sudo chmod -R 0775 $dir
sudo chown -R AzDevOps:AzDevOps $dir

# install dependencies
log_message "Installing dependencies"
bash -x ./bin/installdependencies.sh | tee -a /var/log/enableagent.log 2>&1
retValue=$?
log_message "Installation of dependencies completed"
if [ $retValue -ne 0 ]; then
    log_message "Dependencies installation failed"
fi


# configure the build agent
# calling bash here so the quotation marks around $pool get respected
log_message "Configuring build agent"

# extract proxy configuration if present
extra=''
proxy_url_variable=''
if [ ! -z "$http_proxy"  ]; then
    proxy_url_variable="$http_proxy"
elif [ ! -z "$https_proxy"  ]; then
    proxy_url_variable="$https_proxy"
fi

if [ ! -z "$proxy_url_variable"  ]; then
    log_message "Found a proxy configuration"
    # http://<username>:<password>@<proxy_url/_proxyip>:<port>
    proxy_username=''
    proxy_password=''
    proxy_url=''
    if [[ "$proxy_url_variable" != *"@"* ]]; then
        # no username and passowrd
        proxy_url="$proxy_url_variable"
        extra="--proxyurl $proxy_url_variable"
        log_message "Found proxy url $proxy_url"
    else
        # we need to also extract username and password and decode them (the agent will try to encode them again)
        proxy_url=$(echo "$proxy_url_variable" | cut -d'/' -f 1 )"//"$(echo "$proxy_url_variable" | cut -d'@' -f 2 )
        proxy_username=$(echo "$proxy_url_variable" | cut -d':' -f 2 | cut -d'/' -f 3)
        proxy_password=$(echo "$proxy_url_variable" | cut -d'@' -f 1 | cut -d':' -f 3)
        proxy_username=$(decode_string "$proxy_username")
        proxy_password=$(decode_string "$proxy_password")
        extra="--proxyurl $proxy_url --proxyusername $proxy_username --proxypassword $proxy_password"
        log_message "Found proxy url $proxy_url and authentication info"
    fi
fi

log_message "Configuring agent"
OUTPUT=$(sudo -E runuser AzDevOps -c "/bin/bash $dir/config.sh --unattended --url $url --pool \"$pool\" --auth pat --token $token --acceptTeeEula --replace $extra" 2>&1)
retValue=$?
log_message "$OUTPUT"
if [ $retValue -ne 0 ]; then
    log_message "Build agent configuration failed"
    exit 100
fi

# run agent in the background and detach it from the terminal
log_message "Starting agent"
sudo -E nice -n 0 runuser AzDevOps -c "/bin/bash $dir/run.sh $runArgs" > /dev/null 2>&1 &
log_message "disown"
disown
log_message "after disown"
