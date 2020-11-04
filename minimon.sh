#!/bin/bash

# console colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
PURPLE="\033[0;35m"
RESET="\033[0m"
GRAY="\033[1;30m"

# check a http endpoint
check_http() {
    local out=$(( curl --silent \
        --max-time 5 --connect-timeout 5 -k --max-redirs 32 -L \
        -w "\n%{time_total}\t%{http_code}\t%{num_connects}" \
        "$1"; echo -e "\t$?" 2> /dev/null ) | tail -n 1)

    local time=$(echo -e "$out" | awk '{print $1}')
    local status=$(echo -e "$out" | awk '{print $2}')
    local code=$(echo -e "$out" | awk '{print $4}')

    local cmkcode=2
    local cmktext="CRIT"
    if [ $code -eq 0 ] && [[ $status = 2* ]]; then
        cmkcode=0
        cmktext="OK"
    elif [ $code -eq 0 ]; then
        cmkcode=1
        cmktext="WARN"
    fi

    echo "$cmkcode http - HTTP $status" #; ${time} seconds"
    return $code
}

# check a generic tcp endpoint
check_tcp() {
    local out=$( echo "$(timeout 1 curl -v telnet://$1 2>&1)" | grep -F "* Connected to " > /dev/null; echo $? )

    local cmkcode=2
    local cmktext="CRIT"
    local text="Connect failed"
    if [ $out -eq 0 ]; then
        cmkcode=0
        cmktext="OK"
        text="Connect successful"
    fi

    echo "$cmkcode tcp - $text"
    return $out
}

# handle output of check, print update when it is a change
handle_result() {
    local index=$1
    local out="$2"
    local url="$3"
    local servicename="$4"

    # split check output
    local exitcode=$(echo "$out" | awk '{print $1}')
    local checktype=$(echo "$out" | awk '{print $2}')
    local statusmessage=$(echo "$out" | cut -d ' ' -f 4-)
    local statusmsghash=$(echo "$statusmessage" | sha256sum | awk '{print $1}')

    # check result
    local statecolor="$RED"
    local statename="NOK"

    if [ $exitcode -eq 0 ]; then
        statecolor="$GREEN"
        statename="OK"
    elif [ $exitcode -eq 1 ]; then
        statecolor="$YELLOW"
        statename="WARN"
    fi

    # print update when status was changed
    if [ ! "${laststatus[$index]}" == "$statusmsghash;$exitcode" ]
    then
        # timestamp
        echo -n "[$(date --iso-8601=seconds)]"
        echo -n -e " $statecolor$checktype$RESET"

        # service description
        if [ ! -z "$servicename" ]
        then
            echo -n -e "${statecolor}_$servicename$RESET"
        fi

        # url
        echo -n " -"
        echo -n " $url"

        # state
        echo -n " -"
        echo -n -e " ${statecolor}${statename} ($exitcode)${RESET}"

        # protocol status code
        if [ ! -z "$statusmessage" ]
        then
            echo -n -e " - $GRAY$statusmessage$RESET"
        fi

        # duration until this change
        if [ ! -z "${statusts[$index]}" ]
        then
            echo -n -e " - changed after ${PURPLE}$(($(date +%s)-${statusts[$index]}))s${RESET}"
        fi

        echo

        # update state variables
        laststatus[$index]="$statusmsghash;$exitcode"
        statusts[$index]=$(date +%s)
        return 1
    fi

    return 0
}

# execute a check
exec_check() {
    local method=$1
    local urlname=$2
    local index=$3

    # split url and service name
    local url=$(echo "$urlname" | awk -F  ";" '{print $1}')
    local servicename=$(echo "$urlname" | awk -F  ";" '{print $2}')

    # execute check and give it to handler
    handle_result $index "$($method "$url")" "$url" "$servicename"
    check_res=$?

    if [ $check_res -eq 1 ]
    then
        CHANGED=1
    fi
}


# Arguments
ARG_HELP=0
ARG_INTERVAL=30
UNKNOWN_OPTION=0
URLS_HTTP=()
URLS_TCP=()

if [ $# -ge 1 ]
then
    while [[ $# -ge 1 ]]
    do
        key="$1"
        case $key in
            --tcp)
                shift
                URLS_TCP+=("$1")
                ;;
            --http)
                shift
                URLS_HTTP+=("$1")
                ;;
            --interval)
                shift
                ARG_INTERVAL=$1
                ;;
            -h|--help)
                ARG_HELP=1
                ;;
            *)
                # unknown option
                ARG_HELP=1
                UNKNOWN_OPTION=1
                ;;
        esac
        shift # past argument or value
    done
else
    # no arguments passed, show help
    ARG_HELP=1
fi


# Help
if [ $ARG_HELP -eq 1 ]
then
    if [ $UNKNOWN_OPTION -eq 1 ]
    then
        echo "Unknown option."
    fi

    echo "Usage: $0 [--interval 30] [--tcp example.com:4242[;optsrvname]] [--http https://example.com]"
    exit
fi


# check parameters
if [ -z "$ARG_INTERVAL" ] || [ $ARG_INTERVAL -lt 1 ]
then
    ARG_INTERVAL=1
fi


# Monitoring
laststatus=()
statusts=()

while true
do
    I=0
    CHANGED=0

    # http checks
    for value in "${URLS_HTTP[@]}"
    do
        exec_check "check_http" "$value" "$I"
        I=$(($I+1))
    done

    # tcp checks
    for value in "${URLS_TCP[@]}"
    do
        exec_check "check_tcp" "$value" "$I"
        I=$(($I+1))
    done

    # ascii bell when change
    if [ $CHANGED -eq 1 ]
    then
        echo -ne "\007"
    fi

    # sleep for given interval
    sleep $ARG_INTERVAL
done
