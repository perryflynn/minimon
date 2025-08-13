#!/usr/bin/env bash

# minimon - Minimalistic monitoring
# 2023 by Christian Blechert <christian@serverless.industries>
# https://github.com/perryflynn/minimon

APPNAME=minimon
APPVERSION="2.0-alpha"

set -u

# https://stackoverflow.com/a/54335338/4161736
set +m

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
        "$1"; echo -e "\t$?" 2> /dev/null ) | tail -n 1 | tr -d '\0')

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
    local out=$(( timeout "$ARG_CONTIMEOUT" curl --silent -v $proto "telnet://$1" <<<"this is $APPNAME.sh connect test.\n\n" 2>&1 ) | tr -d '\0')

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
    local out=$(( "${pingargs[@]}" -w 5 $1 2>&1 )  | tr -d '\0')

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

    local binary=$(echo "$url" | awk '{print $1}')
    local binargs=$(echo "$url" | awk '{$1=""; print $0}')

    # find script in PATH or current directory
    local script; script=$(if [[ $url == ./* ]]; then which $binary; else which ./$binary; fi)
    local scriptcode=$?

    if [ $scriptcode -gt 0 ]; then
        script=$(which $binary)
        scriptcode=$?
    fi

    if [ $scriptcode -gt 0 ] || [ -z "$script" ]; then
        echo "3 script - no executable found"
        return 3
    fi

    # run script
    text=$(( timeout "$ARG_CONTIMEOUT" $script $binargs 2>&1 ) | tr '\n' ' ' | tr '\t' ' ' | tr -d '\r'; exit ${PIPESTATUS[0]})
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

    rm -f "${CACHEDIR}/${i}.states"

    # print update when status was changed
    if [ ! "${LASTSTATUS[$index]:-}" == "$statusmsghash;$exitcode" ]
    then
        # timestamp
        if [ $ARG_NOTIMESTAMPS -le 0 ]; then
            if [ $ARG_SHORTTIMESTAMPS -gt 0 ]; then
                echo -n "[$(date +%H:%M:%S)] "
            else
                echo -n "[$(date --iso-8601=seconds)] "
            fi
        fi

        echo -n -e "[$index] $statecolor$checktype$RESET"

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
        if [ ! -z "${STATUSTS[$index]:-}" ]
        then
            echo -n -e " - changed after ${PURPLE}$(($(date +%s)-${STATUSTS[$index]}))s${RESET}"
        fi

        echo

        # update state variables
        echo "newstatus=\"$statusmsghash;$exitcode\"" >> "${CACHEDIR}/${i}.states"
        echo "newstatusts=\"$(date +%s)\"" >> "${CACHEDIR}/${i}.states"

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

    return $check_res
}

# import property from json file
import_jsonprop() {
    local varname=$1
    local jsonpath=$2
    local json=$3

    value=$(echo "$json" | jq -c -r -M "$jsonpath")

    if [ "$value" == "true" ]; then
        eval "$varname=\"1\""
    elif [ "$value" == "false" ]; then
        eval "$varname=\"0\""
    elif [ -n "$value" ] && [ ! "$value" == "null" ]; then
        eval "$varname=\"$(echo -n "$value" | sed 's/"//g')\""
    fi
}


# Cache directory and cleanup trap
CACHEDIR=$(mktemp --suffix="${APPNAME}jobs" --directory)

cleanup() {
    rm -rf "$CACHEDIR"
}

trap cleanup EXIT


# Arguments
ARG_HELP=0
ARG_VERSION=0
ARG_VERBOSE=0
ARG_ERRORS=0
ARG_WARNINGS=0
ARG_NOFOLLOWREDIR=0
ARG_INVALTLS=0
ARG_UNSAFETLS=0
ARG_INTERVAL=30
ARG_TIMEOUT=5
ARG_CONTIMEOUT=-1
ARG_MAXCHECKS=-1
ARG_PARALLEL=10
ARG_NOTIMESTAMPS=0
ARG_SHORTTIMESTAMPS=0
ARG_TIMESPACER=0
UNKNOWN_OPTION=0
URLS=()
CONFIG=()

# Arguments from cli
if [ $# -ge 1 ]
then
    while [[ $# -ge 1 ]]
    do
        key="$1"
        case $key in
            --tcp4|--tcp6)
                shift
                URLS+=("tcp|${key: -1}|$1")
                ;;
            --tcp)
                shift
                URLS+=("tcp|0|$1")
                ;;
            --http4|--http6)
                shift
                URLS+=("http|${key: -1}|$1")
                ;;
            --http)
                shift
                URLS+=("http|0|$1")
                ;;
            --icmp4|--icmp6)
                shift
                URLS+=("icmp|${key: -1}|$1")
                ;;
            --icmp)
                shift
                URLS+=("icmp|0|$1")
                ;;
            --script)
                shift
                URLS+=("script|0|$1")
                ;;
            --config)
                shift
                CONFIG+=("$1")
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
            --parallel)
                shift
                ARG_PARALLEL=$1
                ;;
            --no-timestamps)
                ARG_NOTIMESTAMPS=1
                ;;
            --short-timestamps)
                ARG_SHORTTIMESTAMPS=1
                ;;
            --time-spacer)
                shift
                ARG_TIMESPACER=$1
                ;;
            -h|--help)
                ARG_HELP=1
                ;;
            -V|--version)
                ARG_VERSION=1
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
            --unsafe-tls)
                ARG_UNSAFETLS=1
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

# Arguments from json
if [ ${#CONFIG[@]} -gt 0 ] && ( ! command -v jq &> /dev/null ); then
    echo "Using the '--config' option requires 'jq' to be installed"
    exit 1
fi

for jsonfile in "${CONFIG[@]}"
do
    content=$(cat "$jsonfile")
    import_jsonprop ARG_INTERVAL ".\"interval\"" "$content"
    import_jsonprop ARG_TIMEOUT ".\"timeout\"" "$content"
    import_jsonprop ARG_CONTIMEOUT ".\"connect-timeout\"" "$content"
    import_jsonprop ARG_MAXCHECKS ".\"max-checks\"" "$content"
    import_jsonprop ARG_PARALLEL ".\"parallel\"" "$content"
    import_jsonprop ARG_ERRORS ".\"errors\"" "$content"
    import_jsonprop ARG_WARNINGS ".\"warnings\"" "$content"
    import_jsonprop ARG_VERBOSE ".\"verbose\"" "$content"
    import_jsonprop ARG_NOFOLLOWREDIR ".\"no-redirect\"" "$content"
    import_jsonprop ARG_INVALTLS ".\"invalid-tls\"" "$content"
    import_jsonprop ARG_NOTIMESTAMPS ".\"no-timestamps\"" "$content"
    import_jsonprop ARG_SHORTTIMESTAMPS ".\"short-timestamps\"" "$content"
    import_jsonprop ARG_UNSAFETLS ".\"unsafe-tls\"" "$content"
    import_jsonprop ARG_TIMESPACER ".\"time-spacer\"" "$content"

    while read check
    do
        URLS+=("$check")
    done <<<"$(echo "$content" | jq -r -c -M '.checks[] | (.type+"|"+(.proto//0|tostring)+"|"+.url+(if .alias then ";"+.alias else "" end))')"
done


# Version
if [ $ARG_VERSION -eq 1 ]
then
    echo "$APPNAME $APPVERSION"
    exit
fi


# Help
if [ $ARG_HELP -eq 1 ]
then
    if [ $UNKNOWN_OPTION -eq 1 ]
    then
        echo "Unknown option."
        echo
    fi

    echo "$APPNAME by Christian Blechert"
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
    echo "Load settings from json files:"
    echo "--config some-config.json"
    echo
    echo "Schema for editors like VSCode:"
    echo "https://files.serverless.industries/schemas/minimon.json"
    echo
    echo "A script must output one line of text"
    echo "and must set a exit code like so:"
    echo "0=OK; 1=WARN; 2=NOK; 3=UNKNOWN"
    echo
    echo "--max-checks n     Only test n times"
    echo "exit 0 = all ok; exit 1 = partially ok; exit 2 = all failed"
    echo
    echo "--no-redirect       Do not follow HTTP redirects"
    echo "--invalid-tls       Ignore invalid TLS certificates"
    echo "--unsafe-tls        Accept very unsafe and old crypto"
    echo "--timeout           curl operation timeout"
    echo "--connect-timeout   curl connect timeout"
    echo "--parallel 10       number of checks execute in parallel"
    echo "--no-timestamps     disable timestamps"
    echo "--short-timestamps  only show time, not the date"
    echo "--time-spacer 30    add a spacer line if n seconds was no state change"
    echo
    echo "-v, --verbose      Enable verbose mode"
    echo "-w, --warnings     Show warning output"
    echo "-e, --errors       Show error output"
    echo "-h, --help         Print this help"
    echo "-V, --version      Print the version"
    echo
    exit
fi


# use timeout for connect timeout if not specified separately
if [ $ARG_CONTIMEOUT -lt 0 ]; then
    ARG_CONTIMEOUT=$ARG_TIMEOUT
fi


# ensure positive interval
if [ -z "$ARG_INTERVAL" ] || [ $ARG_INTERVAL -lt 1 ]
then
    ARG_INTERVAL=1
fi

# allow unsafe crypto
# can/should be used with invalid-tls option
if [ $ARG_UNSAFETLS -gt 0 ]
then
    (
        cat /etc/ssl/openssl.cnf
        echo "Options = UnsafeLegacyRenegotiation"
        echo "CipherString = DEFAULT@SECLEVEL=1"
    ) > $CACHEDIR/openssl-unsafe.conf
    export OPENSSL_CONF="$CACHEDIR/openssl-unsafe.conf"
fi


# Monitoring
LASTSTATUS=()
STATUSTS=()
SUCCESSFUL_I=0
WITHERRORS_I=0

main_loop() {
    local loop_i=$ARG_MAXCHECKS
    local i=0
    local pi=0
    local haserrors=0
    local changed=0
    local jobcount=${#URLS[@]}
    local lastchange=$(date +%s)

    >&2 echo -e "${PURPLE}Execute $jobcount checks every $ARG_INTERVAL seconds, max $ARG_PARALLEL in parallel${RESET}"

    while [ $loop_i -eq -1 ] || [ $loop_i -gt 0 ]
    do
        i=0
        haserrors=0
        changed=0

        while [ $i -lt $jobcount ]
        do
            pi=0
            orgi=$i

            # start jobs
            for j in $(seq $orgi $(($jobcount - 1)))
            do
                local item=${URLS[$j]}
                local check=$(echo "$item" | cut -d'|' -f1)
                local proto=$(echo "$item" | cut -d'|' -f2)
                local urlname=$(echo "$item" | cut -d'|' -f3)

                ( exec_check "check_$check" "$urlname" "$j" "$proto" > "${CACHEDIR}/${i}.out" 2>&1 ) &
                i=$(($i+1))
                pi=$(($pi+1))

                if [ $pi -ge $ARG_PARALLEL ]; then
                    break
                fi
            done

            wait

            # process results
            for j in $(seq $orgi $(($i - 1)))
            do
                # print status
                if [ -s "${CACHEDIR}/${j}.out" ]; then
                    now=$(date +%s)
                    if [ $ARG_TIMESPACER -gt 0 ] && [ $(($lastchange + $ARG_TIMESPACER)) -lt $now ]; then
                        echo
                        echo
                    fi

                    cat "${CACHEDIR}/${j}.out"
                    lastchange=$now
                fi

                # state updates?
                if [ -f "${CACHEDIR}/${j}.states" ]
                then
                    source "${CACHEDIR}/${j}.states"
                    if [ -n "${newstatus:-}" ] && [ -n "${newstatusts:-}" ]; then
                        LASTSTATUS[$j]="${newstatus}"
                        STATUSTS[$j]="${newstatusts}"
                        changed=1

                        unset newstatus
                        unset newstatusts
                    fi
                fi

                # cleanup ststus files
                rm -f "${CACHEDIR}/${j}".*
            done
        done

        # ascii bell when change
        if [ $changed -eq 1 ]
        then
            echo -ne "\007"
        fi

        # update error counters
        if [ $haserrors -eq 0 ]; then
            SUCCESSFUL_I=$(($SUCCESSFUL_I+1))
        else
            WITHERRORS_I=$(($WITHERRORS_I+1))
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
}

main_loop

if [ $SUCCESSFUL_I -gt 0 ] && [ $WITHERRORS_I -le 0 ]; then
    # all okay
    exit 0
elif [ $SUCCESSFUL_I -le 0 ] && [ $WITHERRORS_I -gt 0 ]; then
    # all failed
    exit 2
else
    # partially failed
    exit 1
fi
