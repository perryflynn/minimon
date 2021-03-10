#!/bin/bash

# minimon - Minimalistic monitoring
# 2020 by Christian Blechert <christian@serverless.industries>
# https://github.com/perryflynn/minimon

set -u

# console colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
PURPLE="\033[0;35m"
BLUE="\033[0;36m"
RESET="\033[0m"
GRAY="\033[1;30m"

# check a http endpoint
check_http() {
    # ip version
    local proto=""
    local protoname=""
    if [ $2 -eq 4 ]; then
        proto="-4"
        protoname="4"
    elif [ $2 -eq 6 ]; then
        proto="-6"
        protoname="6"
    fi

    # http redirect
    local rediropts=( --max-redirs 32 -L )
    if [ $ARG_NOFOLLOWREDIR -eq 1 ]; then
        rediropts=()
    fi

    # tls
    local tlsopts=()
    if [ $ARG_INVALTLS -eq 1 ]; then
        tlsopts=( -k )
    fi

    # execute check
    local out=$(( curl --silent $proto "${rediropts[@]}" "${tlsopts[@]}" \
        --max-time 5 --connect-timeout 5  \
        -w "\n%{time_total}\t%{http_code}\t%{num_connects}" \
        "$1"; echo -e "\t$?" 2> /dev/null ) | tail -n 1)

    # result
    local time=$(echo -e "$out" | awk '{print $1}')
    local status=$(echo -e "$out" | awk '{print $2}')
    local code=$(echo -e "$out" | awk '{print $4}')

    local cmkcode=2
    local cmktext="CRIT"
    if [ ! -z "$code" ] && [ $code -eq 0 ] && [[ $status = 2* ]]; then
        cmkcode=0
        cmktext="OK"
    elif [ ! -z "$code" ] && [ $code -eq 0 ]; then
        cmkcode=1
        cmktext="WARN"
    fi

    if [ $ARG_VERBOSE -eq 1 ] || ( [ $ARG_ERRORS -eq 1 ] && [ $cmkcode -eq 2 ] ) || ( [ $ARG_WARNINGS -eq 1 ] && [ $cmkcode -eq 1 ] ); then
        >&2 echo -e "${PURPLE}[DEBUG] check_http$protoname $1${RESET}"
        >&2 echo -e -n "$BLUE"
        >&2 echo -e "time_spend\thttp_status\tconnection_count\texit_code"
        >&2 echo -e "$out"
        >&2 echo -n -e "$RESET"
    fi

    echo "$cmkcode http - HTTP $status" #; ${time} seconds"
    return $cmkcode
}

# check a generic tcp endpoint
check_tcp() {
    local proto=""
    local protoname=""
    if [ $2 -eq 4 ]; then
        proto="-4"
        protoname="4"
    elif [ $2 -eq 6 ]; then
        proto="-6"
        protoname="6"
    fi

    local out=$( echo "$(timeout 2 curl -v $proto telnet://$1 2>&1)" )

    out=$( echo "$out" | grep -F "* Connected to " > /dev/null; echo $? )

    local cmkcode=2
    local cmktext="CRIT"
    local text="Connect failed"
    if [ $out -eq 0 ]; then
        cmkcode=0
        cmktext="OK"
        text="Connect successful"
    fi

    if [ $ARG_VERBOSE -eq 1 ] || ( [ $ARG_ERRORS -eq 1 ] && [ $cmkcode -ne 0 ] ); then
        >&2 echo -e "${PURPLE}[DEBUG] check_tcp$protoname $1${RESET}"
        >&2 echo -e -n "$BLUE"
        >&2 echo -e "$out"
        >&2 echo -n -e "$RESET"
    fi

    echo "$cmkcode tcp - $text"
    return $cmkcode
}

# check via icmp
check_icmp() {
    local proto=""
    local protoname=""
    local pingcmd=""

    local pingargs=()

    if [ $2 -eq 4 ] && [[ "$(uname)" = MINGW* ]]; then
        # Windows IPv4
        pingargs=( ping -4 -n 3 )
        protoname="4"
    elif [ $2 -eq 6 ] && [[ "$(uname)" = MINGW* ]]; then
        # Windows IPv6
        pingargs=( ping -6 -n 3 )
        protoname="6"
    elif [ $2 -eq 6 ]; then
        # Linux IPv6
        pingargs=( ping6 -c 3 )
        protoname="6"
    else
        # Linux IPv4
        pingargs=( ping -c 3 )
        protoname="4"
    fi

    local out=$( "${pingargs[@]}" -w 5 $1 2>&1 )

    local re='^[0-9]+$'
    loss=$( echo "$out" | grep -o -P "[0-9]+%" | cut -d'%' -f1 )

    local cmkcode=2
    local cmktext="CRIT"
    local text="Ping failed"

    if [[ $loss =~ $re ]] && [ $loss -gt 0 ] && [ $loss -lt 100 ]; then
        cmkcode=1
        cmktext="WARN"
        text="Ping succeeded (${loss}% loss)"
    elif [[ $loss =~ $re ]] && [ $loss -le 0 ]; then
        cmkcode=0
        cmktext="OK"
        text="Ping succeeded (${loss}% loss)"
    elif [[ $loss =~ $re ]]; then
        text="$text (${loss}% loss)"
    fi

    if [ $ARG_VERBOSE -eq 1 ] || ( [ $ARG_ERRORS -eq 1 ] && [ $cmkcode -eq 2 ] ) || ( [ $ARG_WARNINGS -eq 1 ] && [ $cmkcode -eq 1 ] ); then
        >&2 echo -e "${PURPLE}[DEBUG] check_icmp$protoname $1${RESET}"
        >&2 echo -e -n "$BLUE"
        >&2 echo -e "$out"
        >&2 echo -n -e "$RESET"
    fi

    echo "$cmkcode icmp - $text"
    return $cmkcode
}

# handle output of check, print update when it is a change
handle_result() {
    local index=$1
    local out="$2"
    local url="$3"
    local servicename="$4"
    local proto="$5"
    local timespend="$6"

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
    if [ ! "${laststatus[$index]:-}" == "$statusmsghash;$exitcode" ]
    then
        # timestamp
        echo -n "[$(date --iso-8601=seconds)]"
        echo -n -e " $statecolor$checktype$RESET"

        # ip version
        if [ $proto -gt 0 ]
        then
            echo -n -e "${statecolor}$proto$RESET"
        fi

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

        # time
        echo -n " -"
        echo -n -e " $GRAY${timespend}s$RESET"

        # protocol status code
        if [ ! -z "$statusmessage" ]
        then
            echo -n -e " - $GRAY$statusmessage$RESET"
        fi

        # duration until this change
        if [ ! -z "${statusts[$index]:-}" ]
        then
            echo -n -e " - changed after ${PURPLE}$(($(date +%s)-${statusts[$index]}))s${RESET}"
        fi

        echo

        # update state variables
        laststatus[$index]="$statusmsghash;$exitcode"
        statusts[$index]=$(date +%s)
        return 1

    else
        if [ $ARG_VERBOSE -eq 1 ]; then
            >&2 echo -e "${PURPLE}[DEBUG] State of check_$checktype $url unchanged${RESET}"
        fi

        return 0
    fi
}

# execute a check
exec_check() {
    local method=$1
    local urlname=$2
    local index=$3
    local proto=$4

    # split url and service name
    # echo "scale=3; $(($(date +%s%N | cut -b1-13) - $start))/1000" | bc
    local url=$(echo "$urlname" | awk -F  ";" '{print $1}')
    local servicename=$(echo "$urlname" | awk -F  ";" '{print $2}')

    local starttime=$(date +%s%N | cut -b1-13)
    local out; out=$($method "$url" "$proto")
    local check_res=$?

    local timespend=$(( ($(date +%s%N | cut -b1-13) - $starttime) / 1000 ))
    if command -v bc &> /dev/null
    then
        timespend=$(echo "scale=3; x=($(date +%s%N | cut -b1-13) - $starttime) / 1000; if(x<1 && x > 0) print 0; x" | bc -l)
    fi

    # execute check and give it to handler
    local ischanged
    handle_result $index "$out" "$url" "$servicename" "$proto" "$timespend"
    ischanged=$?

    if [ $ischanged -eq 1 ]
    then
        CHANGED=1
    fi

    return $check_res
}


# Arguments
ARG_HELP=0
ARG_VERBOSE=0
ARG_ERRORS=0
ARG_WARNINGS=0
ARG_NOFOLLOWREDIR=0
ARG_INVALTLS=0
ARG_INTERVAL=30
ARG_MAXCHECKS=-1
UNKNOWN_OPTION=0
URLS_HTTP=()
URLS_TCP=()
URLS_ICMP=()

if [ $# -ge 1 ]
then
    while [[ $# -ge 1 ]]
    do
        key="$1"
        case $key in
            --tcp4|--tcp6)
                shift
                URLS_TCP+=("${key: -1}$1")
                ;;
            --tcp)
                shift
                URLS_TCP+=("0$1")
                ;;
            --http4|--http6)
                shift
                URLS_HTTP+=("${key: -1}$1")
                ;;
            --http)
                shift
                URLS_HTTP+=("0$1")
                ;;
            --icmp4|--icmp6)
                shift
                URLS_ICMP+=("${key: -1}$1")
                ;;
            --icmp)
                shift
                URLS_ICMP+=("0$1")
                ;;
            --interval)
                shift
                ARG_INTERVAL=$1
                ;;
            --max-checks)
                shift
                ARG_MAXCHECKS=$1
                ;;
            -h|--help)
                ARG_HELP=1
                ;;
            -e|--errors)
                ARG_ERRORS=1
                ;;
            -w|--warnings)
                ARG_WARNINGS=1
                ;;
            -v|--verbose)
                ARG_VERBOSE=1
                ;;
            --no-redirect)
                ARG_NOFOLLOWREDIR=1
                ;;
            --invalid-tls)
                ARG_INVALTLS=1
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

    echo "minimon by Christian Blechert"
    echo "https://github.com/perryflynn/minimon"
    echo
    echo "Usage: $0 [--interval 30] [--tcp \"example.com:4242[;aliasname]\"]"
    echo
    echo "--interval n       Delay between two checks"
    echo "--tcp host:port    Check a generic TCP port"
    echo "--tcp4 host:port   Check a generic TCP port, force IPv4"
    echo "--tcp6 host:port   Check a generic TCP port, force IPv6"
    echo "--http url         Check a HTTP(S) URL"
    echo "--http4 url        Check a HTTP(S) URL, force IPv4"
    echo "--http6 url        Check a HTTP(S) URL, force IPv6"
    echo "--icmp host        Ping a Hostname/IP"
    echo "--icmp4 host       Ping a Hostname/IP, force IPv4"
    echo "--icmp6 host       Ping a Hostname/IP, force IPv6"
    echo
    echo "Append a alias name to a check separated by a semicolon:"
    echo "--icmp \"8.8.8.8;google\""
    echo
    echo "--max-checks n     Only test n times"
    echo "exit 0 = all ok; exit 1 = partially ok; exit 2 = all failed"
    echo
    echo "--no-redirect      Do not follow HTTP redirects"
    echo "--invalid-tls      Ignore invalid TLS certificates"
    echo
    echo "-v, --verbose      Enable verbose mode"
    echo "-w, --warnings     Show warning output"
    echo "-e, --errors       Show error output"
    echo "-h, --help         Print this help"
    echo
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
loop_i=$ARG_MAXCHECKS
successful_i=0
witherrors_i=0

while [ $loop_i -eq -1 ] || [ $loop_i -gt 0 ]
do
    I=0
    CHANGED=0
    HASERRORS=0

    # http checks
    for value in "${URLS_HTTP[@]}"
    do
        exec_check "check_http" "${value: 1}" "$I" "${value: :1}"
        if [ $? -ne 0 ]; then HASERRORS=1; fi
        I=$(($I+1))
    done

    # tcp checks
    for value in "${URLS_TCP[@]}"
    do
        exec_check "check_tcp" "${value: 1}" "$I" "${value: :1}"
        if [ $? -ne 0 ]; then HASERRORS=1; fi
        I=$(($I+1))
    done

    # tcp icmp
    for value in "${URLS_ICMP[@]}"
    do
        exec_check "check_icmp" "${value: 1}" "$I" "${value: :1}"
        if [ $? -ne 0 ]; then HASERRORS=1; fi
        I=$(($I+1))
    done

    # ascii bell when change
    if [ $CHANGED -eq 1 ]
    then
        echo -ne "\007"
    fi

    # update error counters
    if [ $HASERRORS -eq 0 ]; then
        successful_i=$(($successful_i+1))
    else
        witherrors_i=$(($witherrors_i+1))
    fi

    # interval counter
    if [ $ARG_MAXCHECKS -gt 0 ]; then
        loop_i=$(($loop_i-1))
    fi

    # sleep for given interval
    if [ $ARG_MAXCHECKS -lt 0 ] || [ $loop_i -gt 0 ]; then
        sleep $ARG_INTERVAL
    fi
    
done

if [ $successful_i -gt 0 ] && [ $witherrors_i -le 0 ]; then
    # all okay
    exit 0
elif [ $successful_i -le 0 ] && [ $witherrors_i -gt 0 ]; then
    # all failed
    exit 2
else
    # partially failed
    exit 1
fi
