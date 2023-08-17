#!/usr/bin/env bash

# minimon - Minimalistic monitoring
# 2023 by Christian Blechert <christian@serverless.industries>
# https://github.com/perryflynn/minimon

set -u

# console colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
PURPLE="\033[0;35m"
BLUE="\033[0;36m"
RESET="\033[0m"

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
        --max-time "$ARG_TIMEOUT" --connect-timeout "$ARG_CONTIMEOUT"  \
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

    # status code info
    local statusinfo=""
    if [ $status -gt 0 ]; then
        statusinfo=" HTTP::$status"
    fi

    # exit code info
    local exitinfo=""
    if [ $code -ne 0 ]; then
        exitinfo=" EXIT::$code"
    fi

    # verbose info
    if [ $ARG_VERBOSE -eq 1 ] || ( [ $ARG_ERRORS -eq 1 ] && [ $cmkcode -eq 2 ] ) || ( [ $ARG_WARNINGS -eq 1 ] && [ $cmkcode -eq 1 ] ); then
        >&2 echo -e "${PURPLE}[DEBUG] check_http$protoname $1${RESET}"
        >&2 echo -e -n "$BLUE"
        >&2 echo -e "time_spend\thttp_status\tconnection_count\texit_code"
        >&2 echo -e "$out"
        >&2 echo -n -e "$RESET"
    fi

    echo "$cmkcode http${protoname} -${statusinfo}${exitinfo}" #; ${time} seconds"
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

    # run telnet request
    local out=$(timeout "$ARG_CONTIMEOUT" curl --silent -v $proto "telnet://$1" 2>&1)

    # build result
    local cmkcode=2
    local cmktext="CRIT"
    local text="Connect failed"

    out=$( echo "$out" | grep -F "* Connected to " > /dev/null; echo $? )

    if [ $out -eq 0 ]; then
        cmkcode=0
        cmktext="OK"
        text="Connect successful"
    fi

    # debug output
    if [ $ARG_VERBOSE -eq 1 ] || ( [ $ARG_ERRORS -eq 1 ] && [ $cmkcode -ne 0 ] ); then
        >&2 echo -e "${PURPLE}[DEBUG] check_tcp$protoname $1${RESET}"
        >&2 echo -e -n "$BLUE"
        >&2 echo -e "$out"
        >&2 echo -n -e "$RESET"
    fi

    # report result
    echo "$cmkcode tcp${protoname} - $text"
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
    elif [ $2 -eq 0 ] && [[ "$(uname)" = MINGW* ]]; then
        # Windows automatic protocol detection
        pingargs=( ping -n 3 )
        protoname=""
    elif [ $2 -eq 6 ]; then
        # Linux IPv6
        pingargs=( ping6 -c 3 -w $ARG_TIMEOUT )
        protoname="6"
    elif [ $2 -eq 4 ] || [ $2 -eq 0 ]; then
        # Linux IPv4 or fallback if no protocol preference given
        pingargs=( ping -c 3 -w $ARG_TIMEOUT )
        protoname="4"
    else
        echo "3 icmp - Unexpected parameters given, abort"
        return 3
    fi

    # run ping
    local out=$( "${pingargs[@]}" -w 5 $1 2>&1 )

    # get packet loss
    local re='^[0-9]+$'
    loss=$( echo "$out" | grep -o -P "[0-9]+%" | cut -d'%' -f1 )

    # build result
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

    # debug output
    if [ $ARG_VERBOSE -eq 1 ] || ( [ $ARG_ERRORS -eq 1 ] && [ $cmkcode -eq 2 ] ) || ( [ $ARG_WARNINGS -eq 1 ] && [ $cmkcode -eq 1 ] ); then
        >&2 echo -e "${PURPLE}[DEBUG] check_icmp$protoname $1${RESET}"
        >&2 echo -e -n "$BLUE"
        >&2 echo -e "$out"
        >&2 echo -n -e "$RESET"
    fi

    # report result
    echo "$cmkcode icmp${protoname} - $text"
    return $cmkcode
}

# check via external script
check_script() {
    local url=$1
    local cmkcode=2
    local text="unable to execute script"

    # find script
    local script; script=$(if [[ $url == ./* ]]; then which $url; else which ./$url; fi)
    local scriptcode=$?

    if [ $scriptcode -gt 0 ]; then
        script=$(which $url)
        scriptcode=$?
    fi

    if [ $scriptcode -gt 0 ] || [ -z "$script" ]; then
        echo "3 script - no executable found"
        return 3
    fi

    # run script
    text=$(( timeout "$ARG_CONTIMEOUT" $script 2>&1 ) | tr '\n' ' ' | tr '\t' ' ' | tr -d '\r'; exit ${PIPESTATUS[0]})
    cmkcode=$?

    local originalcode=$cmkcode
    local originaltext=""

    # check for timeout
    if [ $cmkcode -eq 124 ]; then
        cmkcode=2
        originaltext=$text
        text="script timed out after $ARG_CONTIMEOUT seconds"
    fi

    # debug output
    if [ $ARG_VERBOSE -eq 1 ] || ( [ $ARG_ERRORS -eq 1 ] && [ $cmkcode -ne 0 ] ); then
        >&2 echo -e "${PURPLE}[DEBUG] check_script $script; Exit Code = $originalcode${RESET}"
        >&2 echo -e -n "$BLUE"
        if [ -n "$originaltext" ]; then
            >&2 echo -e "$originaltext"
        fi
        >&2 echo -e "$text"
        >&2 echo -n -e "$RESET"
    fi

    # report status
    echo "$cmkcode script - $text"
    return $cmkcode
}

curl_statuscode_to_text() {
    local code=$1
    local text=""
    local hit=0
    case $code in
        0)
            text="ok"
            ;;
        3)
            text="url malformed"
            ;;
        5)
            text="could not resolve proxy"
            ;;
        6)
            text="could not resolve host"
            ;;
        7)
            text="failed to connect to host"
            ;;
        28)
            text="operation timeout"
            ;;
        47)
            text="too many redirects"
            ;;
        51)
            text="tls certificate verification failed"
            ;;
        52)
            text="no response"
            ;;
        56)
            text="failure in receiving network data"
            ;;
        60)
            text="cannot authenticate with known ca certificates"
            ;;
        *)
            text="check https://everything.curl.dev/usingcurl/returns"
            hit=1
            ;;
    esac

    echo -n "curl exit code '$code': $text"
    return $hit
}

http_statuscode_to_text() {
    local code=$1
    local text=""
    local hit=0
    case $code in
        200)
            text="ok"
            ;;
        201)
            text="created"
            ;;
        202)
            text="accepted"
            ;;
        204)
            text="no content"
            ;;
        301)
            text="moved permanently"
            ;;
        302)
            text="found (moved temporarily)"
            ;;
        304)
            text="not modified"
            ;;
        400)
            text="bad request"
            ;;
        401)
            text="unauthorized"
            ;;
        403)
            text="forbidden"
            ;;
        404)
            text="not found"
            ;;
        405)
            text="method not allowed"
            ;;
        500)
            text="internal server error"
            ;;
        502)
            text="bad gateway"
            ;;
        503)
            text="service unavailable"
            ;;
        504)
            text="gateway timeout"
            ;;
        *)
            text="check https://en.wikipedia.org/wiki/List_of_HTTP_status_codes"
            hit=1
            ;;
    esac

    echo -n "http status code '$code': $text"
    return $hit
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
    elif [ $exitcode -eq 3 ]; then
        statecolor=""
        statename="UNKNOWN"
    fi

    # print update when status was changed
    if [ ! "${laststatus[$index]:-}" == "$statusmsghash;$exitcode" ]
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

        # time
        echo -n " -"
        echo -n -e " ${timespend}s"

        # protocol status code
        if [ ! -z "$statusmessage" ]
        then
            echo -n -e " - $statusmessage"
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

        # curl info
        if [ "${checktype:0:4}" == "http" ] && [[ $statusmessage =~ EXIT::[0-9]+ ]]; then
            curlexitcode=$(echo "$statusmessage" | grep -o -P "EXIT::[0-9]+" | cut -d: -f3)
            curltext=$(curl_statuscode_to_text "$curlexitcode")
            >&2 echo -e "    $PURPLE$curltext$RESET"
        fi

        if [ "${checktype:0:4}" == "http" ] && ! [[ $statusmessage =~ HTTP::000 ]] && ! [[ $statusmessage =~ HTTP::2[0-9]+ ]] && [[ $statusmessage =~ HTTP::[0-9]+ ]]; then
            curlexitcode=$(echo "$statusmessage" | grep -o -P "HTTP::[0-9]+" | cut -d: -f3)
            curltext=$(http_statuscode_to_text "$curlexitcode")
            >&2 echo -e "    $PURPLE$curltext$RESET"
        fi

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
ARG_TIMEOUT=5
ARG_CONTIMEOUT=-1
ARG_MAXCHECKS=-1
UNKNOWN_OPTION=0
URLS_HTTP=()
URLS_TCP=()
URLS_ICMP=()
URLS_SCRIPT=()

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
            --script)
                shift
                URLS_SCRIPT+=("0$1")
                ;;
            --interval)
                shift
                ARG_INTERVAL=$1
                ;;
            --timeout)
                shift
                ARG_TIMEOUT=$1
                ;;
            --connect-timeout)
                shift
                ARG_CONTIMEOUT=$1
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


# use timeout for connect timeout if not specified separately
if [ $ARG_CONTIMEOUT -lt 0 ]; then
    ARG_CONTIMEOUT=$ARG_TIMEOUT
fi


# Help
if [ $ARG_HELP -eq 1 ]
then
    if [ $UNKNOWN_OPTION -eq 1 ]
    then
        echo "Unknown option."
        echo
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
    echo "--script script    Path to a script to use as a check"
    echo
    echo "Append a alias name to a check separated by a semicolon:"
    echo "--icmp \"8.8.8.8;google\""
    echo
    echo "A script must output one line of text"
    echo "and must set a exit code like so:"
    echo "0=OK; 1=WARN; 2=NOK; 3=UNKNOWN"
    echo
    echo "--max-checks n     Only test n times"
    echo "exit 0 = all ok; exit 1 = partially ok; exit 2 = all failed"
    echo
    echo "--no-redirect      Do not follow HTTP redirects"
    echo "--invalid-tls      Ignore invalid TLS certificates"
    echo "--timeout          curl operation timeout"
    echo "--connect-timeout  curl connect timeout"
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

    # script
    for value in "${URLS_SCRIPT[@]}"
    do
        exec_check "check_script" "${value: 1}" "$I" "${value: :1}"
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
