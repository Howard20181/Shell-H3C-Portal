#!/bin/bash
BasePath=$(
    cd $(dirname ${BASH_SOURCE})
    pwd
)

CONF="${BasePath}"/user.conf
BaseName=$(basename $BASH_SOURCE)
if [ -f "${CONF}" ]; then
    USERID=$(cat "${BasePath}"/user.conf | grep -v grep | awk '{print $1}')
    PWD=$(cat "${BasePath}"/user.conf | grep -v grep | awk '{print $2}')
    if [ ! -n "$USERID" ] || [ ! -n "$PWD" ]; then
        logger -t "${BaseName}" -p user.err "PWD or USERID NULL! EXIT!"
        echo USERID or PWD NULL! EXIT!
        exit
    fi
else
    logger -t "${BaseName}" -p user.err "user.conf not found! EXIT!"
    echo "user.conf not found! EXIT!"
    exit
fi

byodserverip="10.0.15.101" #imc_portal_function_readByodServerAddress
byodserverhttpport="8080"  #imc_portal_function_readByodServerHttpPort

v_loginType="3"
v_is_selfLogin="0"
uamInitCustom="1"
uamInitLogo="H3C"

SLEEP_TIME="1"

function urldecode() {
    if [ -n "${1}" ]; then
        : "${*//+/ }"
        echo -e "${_//%/\\x}"
    else
        echo "Usage: urldecode <string-to-urldecode>"
    fi
}

function encodeURIComponent() {
    local data=$1
    if [ -n "$1" ]; then
        local data="$(echo $data | curl -Gso /dev/null -w %{url_effective} --data-urlencode @- "" | sed -E 's/..(.*).../\1/')"
    else
        echo "Usage: encodeURIComponent <string-to-urlencode>"
    fi
    echo "${data##/?}"
}

function get_json_value() {
    local json="${1}"
    local key="${2}"
    local value=$(jsonfilter -e "$.$key" <<<$json)
    echo "${value}"
}

function check_SHOULD_STOP() {
    SHOULD_STOP=false
    SLEEP_TIME="1"
    local TIME_STOP1=$(date -d "$(date '+%Y-%m-%d 23:15:00')" +%s)
    local TIME_STOP2=$(date -d "$(date '+%Y-%m-%d 07:00:00')" +%s)
    local TIME_CUR=$(date +%s)
    if [ "${portServIncludeFailedCode}" = "63027" ]; then
        if [ ${TIME_CUR} -gt ${TIME_STOP1} ] || [ ${TIME_CUR} -lt ${TIME_STOP2} ]; then
            SHOULD_STOP=true
            logger -t "${BaseName}" -p user.info "EXIT!"
            echo "EXIT!"
            exit
        fi
    fi
}

function check_connect() {
    if [ $(curl -sI -w "%{http_code}" -o /dev/null connect.rom.miui.com/generate_204) = 204 ]; then
        CONNECT=true
    else
        CONNECT=false
    fi
}

function doHeartBeat() {
    logger -t "${BaseName}" -p user.info "Start do HeartBeat"
    local TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "Start do HeartBeat ${TIME}"
    local userDevPort=$(get_json_value $v_json userDevPort)
    local userDevPort_ENCODEURL=$(encodeURIComponent $userDevPort)
    local userStatus=$(get_json_value $v_json userStatus)
    local serialNo=$(get_json_value $v_json serialNo)
    local v_Language=$(get_json_value $v_json clientLanguage)

    doHeartBeat_INFO=$(curl -s ''$appRootUrl'page/doHeartBeat.jsp' \
        -H 'Origin: http://'$byodserverip':'$byodserverhttpport'' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'User-Agent: Mozilla/5.0 (Linux; Android; wv)' \
        -H 'Accept: text/html,application/xhtml+xml,application/xml;' \
        -H 'Referer: '$appRootUrl'page/online_heartBeat.jsp?pl='$portalLink'&uamInitCustom='$uamInitCustom'&uamInitLogo='$uamInitLogo'' \
        -H 'Accept-Language: zh-CN,zh;' \
        -H 'Cookie: hello1='$USERID'; hello2=false; i_p_c_op=false; i_p_c_un='$USERID'' \
        --data-raw 'userip=&basip=&userStatus='$userStatus'&userDevPort='$userDevPort_ENCODEURL'&serialNo='$serialNo'&language='$v_Language'&t=hb' \
        --insecure)
    CONNECT_TIME=$(date +%s)
    #echo doHeartBeat_INFO: $doHeartBeat_INFO #debug
}

function start_auth() {
    logger -t "${BaseName}" -p user.info "Start auth"
    echo "Start auth"
    logger -t "${BaseName}" -p user.info "Send Login request"
    echo "Send Login request"
    local PWD_BASE64="$(printf $PWD | base64)"
    local PWD_BASE64_ENCODEURL=$(encodeURIComponent $PWD_BASE64)
    appRootUrl="http://$byodserverip:$byodserverhttpport/portal/"
    local appRootUrl_ENCODEURL=$(encodeURIComponent $appRootUrl)
    local DATA=$(curl -s ''$appRootUrl'pws?t=li' \
        -H 'Accept: text/plain, */*;' \
        -H 'User-Agent: Mozilla/5.0 (Linux; Android; wv)' \
        -H 'Content-Type: application/x-www-form-urlencoded;' \
        -H 'Origin: http://'$byodserverip':'$byodserverhttpport'' \
        -H 'Referer: '$appRootUrl'index_default.jsp' \
        -H 'Accept-Language: zh-CN,zh;' \
        -H 'Cookie: hello1='$USERID'; hello2=false; i_p_c_op=false; i_p_c_un='$USERID'' \
        --data-raw 'userName='$USERID'&userPwd='$PWD_BASE64_ENCODEURL'&language=Chinese&customPageId='$uamInitLogo'&pwdMode=0&portalProxyIP='$byodserverip'&portalProxyPort=50200&dcPwdNeedEncrypt=1&assignIpType=0&appRootUrl='$appRootUrl_ENCODEURL'' \
        --insecure)
    if [ ! -n "${DATA}" ]; then #未收到回应，网络错误
        logger -t "${BaseName}" -p user.err "Network error"
        echo "Network error"
        start_auth
    else #收到回应，可以连接上认证服务器
        logger -t "${BaseName}" -p user.info "Analyzing authentication results"
        echo "Analyzing authentication results"
        local DATA_ENCODEURL=$(printf "%s" "${DATA}==" | base64 -d)
        local JSON=$(urldecode "${DATA_ENCODEURL}")
        #echo JSON: "${JSON}" #debug
        local v_errorNumber=$(get_json_value "${JSON}" errorNumber)
        #echo v_errorNumber=$v_errorNumber     #debug
        if [ "${v_errorNumber}" = "1" ]; then #认证成功
            CONNECT_TIME=$(date +%s)
            portalLink=$(get_json_value "${JSON}" portalLink)
            local v_jsonStr=${portalLink}
            logger -t "${BaseName}" -p user.info "Login Success"
            local TIME=$(date '+%Y-%m-%d %H:%M:%S')
            echo "Login Success "${TIME}""

            if [ ! -n "${v_jsonStr}" ]; then #解码失败
                logger -t "${BaseName}" -p user.err "portalLink DEBASE64 error"
                echo "ERROR: portalLink DEBASE64 error"
                start_auth
            fi

            local portalLink_ENCODEURL_DEBASE64="$(printf "%s" "${v_jsonStr}" | base64 -d)"
            v_json=$(urldecode "${portalLink_ENCODEURL_DEBASE64}")
            if [ ! -n "${v_json}" ]; then #解码失败
                logger -t "${BaseName}" -p user.err "portalLink DecodeURL error"
                echo "ERROR: portalLink DecodeURL error"
                start_auth
            fi
            #echo v_json: "${v_json}" #debug
            local ifNeedModifyPwd=$(get_json_value $v_json ifNeedModifyPwd)
            if [ "${ifNeedModifyPwd}" = true ]; then #要求修改密码
                logger -t "${BaseName}" -p user.warn "Need Modify Pwd"
                echo Need Modify Pwd

            fi

            local heartBeatCyc=$(get_json_value $v_json heartBeatCyc)
            if [ $heartBeatCyc -gt 0 ]; then #要求心跳
                requires_heartBeat=true
                heartBeatCyc_TRUE=$(expr $heartBeatCyc / 1000)
                SLEEP_TIME=$(expr $heartBeatCyc_TRUE / 2)
                logger -t "${BaseName}" -p user.info "The connection requires a heartbeat every ${heartBeatCyc_TRUE} seconds. Please do not terminate the script."
                echo "The connection requires a heartbeat every ${heartBeatCyc_TRUE} seconds. Please do not terminate the script."
                #doHeartBeat #debug
            else
                requires_heartBeat=false
            fi
            unset portServIncludeFailedCode
            unset portServErrorCode

        else #认证失败
            portServIncludeFailedCode=$(get_json_value "${JSON}" portServIncludeFailedCode)
            local portServIncludeFailedReason=$(get_json_value "${JSON}" portServIncludeFailedReason)
            local v_errorInfo=$(get_json_value "${JSON}" portServErrorCodeDesc)
            portServErrorCode=$(get_json_value "${JSON}" portServErrorCode)
            if [ -n "${portServIncludeFailedCode}" ]; then
                logger -t "${BaseName}" -p user.err "${portServIncludeFailedReason}"
                echo Info: "${portServIncludeFailedReason}"
                if [ "${portServIncludeFailedCode}" = "63013" -o "${portServIncludeFailedCode}" = "63015" -o "${portServIncludeFailedCode}" = "63018" -o "${portServIncludeFailedCode}" = "63025" -o "${portServIncludeFailedCode}" = "63026" -o "${portServIncludeFailedCode}" = "63031" -o "${portServIncludeFailedCode}" = "63032" -o "${portServIncludeFailedCode}" = "63100" ]; then
                    logger -t "${BaseName}" -p user.err "EXIT!"
                    echo EXIT!
                    exit
                fi
                check_SHOULD_STOP
            elif [ -n "${portServErrorCode}" ]; then
                logger -t "${BaseName}" -p user.err "${v_errorInfo}"
                echo Error: "${v_errorInfo}"
                SLEEP_TIME="1"
                if [ "${portServErrorCode}" = 2 ]; then
                    CONNECT_TIME=$(date +%s)
                elif [ "${portServErrorCode}" = 3 ]; then
                    start_auth

                else #未知错误
                    logger -t "${BaseName}" -p user.err "Unknown error $portServErrorCode, login failed. EXIT!"
                    echo "Unknown error $portServErrorCode, login failed. EXIT!"
                    exit
                fi
            fi
            if [ "${v_errorNumber}" = "-1" ]; then
                local e_c=$(get_json_value "${JSON}" e_c)
                local e_d=$(get_json_value "${JSON}" e_d)
                local portal_error=$(get_json_value "${JSON}" "${e_c}")
                local errorDescription=$(get_json_value "${JSON}" "${e_d}")
                #echo e_c=$e_c e_d=$e_d portal_error=$portal_error errorDescription=$errorDescription #get_json_value unreliable
                logger -t "${BaseName}" -p user.err "$portal_error $errorDescription EXIT!"
                echo $portal_error $errorDescription EXIT!
                exit
            fi
        fi
    fi
}
start_auth

while [ true ]; do
    check_connect
    if [ "$CONNECT" = true ]; then
        TIME_CUR=$(date +%s)
        TMP=$(($TIME_CUR - $CONNECT_TIME))
        if [ "${requires_heartBeat}" = true ]; then
            if [ ${TMP} -ge ${heartBeatCyc_TRUE} ]; then
                doHeartBeat
            fi
        fi
    elif [ "$CONNECT" = false ]; then
        check_SHOULD_STOP
        if [ "$SHOULD_STOP" = true ]; then
            break
        elif [ "$SHOULD_STOP" = false ]; then
            logger -t "${BaseName}" -p user.notice "Reconnecting"
            echo Reconnecting
            start_auth
        fi
    fi
    sleep $SLEEP_TIME
done
