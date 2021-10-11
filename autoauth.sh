#!/bin/bash
BasePath=$(
    cd $(dirname ${BASH_SOURCE})
    pwd
)
#DEBUG=1
CONF="${BasePath}"/user.conf
BaseName=$(basename $BASH_SOURCE)
function LOG() {
    if [ -n "${2}" ]; then
        if [ "${1}" == "E" ]; then
            logger -t "${BaseName}" -p user.err "${2}"
            echo "Error : ${2}"
        elif [ "${1}" == "I" ]; then
            logger -t "${BaseName}" -p user.info "${2}"
            echo "Info  : ${2}"
        elif [ "${1}" == "N" ]; then
            logger -t "${BaseName}" -p user.notice "${2}"
            echo "Notice: ${2}"
        elif [ "${1}" == "W" ]; then
            logger -t "${BaseName}" -p user.warn "${2}"
            echo "Warn  : ${2}"
        elif [ -n "${DEBUG}" ] && [ "${1}" == "D" ]; then
            logger -t "${BaseName}" -p user.debug "${2}"
            echo "Debug : ${2}"
        fi
    else
        logger -t "${BaseName}" -p user.info "${1}"
        echo "Info: ${1}"
    fi
}
if [ -f "${CONF}" ]; then
    USERID=$(cat "${BasePath}"/user.conf | grep -v grep | awk '{print $1}')
    PWD=$(cat "${BasePath}"/user.conf | grep -v grep | awk '{print $2}')
    if [ ! -n "$USERID" ] || [ ! -n "$PWD" ]; then
        LOG E "PWD or USERID NULL! EXIT!"
        exit
    fi
else
    LOG E "user.conf not found! EXIT!"
    exit
fi

byodserverip="10.0.15.101" #imc_portal_function_readByodServerAddress
byodserverhttpport="8080"  #imc_portal_function_readByodServerHttpPort

v_loginType="3"
v_is_selfLogin="0"
uamInitCustom="1"
uamInitLogo="H3C"

portServFailedReason_json='{"63013":"用户已被加入黑名单","63015":"用户已失效","63018":"用户不存在或者用户没有申请该服务","63024":"端口绑定检查失败","63025":"MAC地址绑定检查失败","63026":"静态IP地址绑定检查失败","63027":"接入时段限制","63031":"用户密码错误，该用户已经被加入黑名单","63032":"密码错误，密码连续错误次数超过阈值将会加入黑名单","63634":"当前场景下绑定终端数量达到限制","63048":"设备IP绑定检查失败","63073":"用户在对应的场景下不允许接入","63100":"无效认证客户端版本"}'
SLEEP_TIME="1"
RECONN_COUNT="0"

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
    #This function has many errors and its output is unreliable
    local json="${1}"
    local key="${2}"
    if [ -z "${3}" ]; then
        local num="1"
    else
        local num="${3}"
    fi
    local value=$(echo "${json}" | awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/'${key}'\042/){print $(i+1)}}}' | tr -d '"' | sed -n "${num}"p)
    echo "${value}"
}

function check_SHOULD_STOP() {
    SHOULD_STOP=false
    local TIME_STOP1=$(date -d "$(date '+%Y-%m-%d 23:59:59')" +%s)
    local TIME_STOP2=$(date -d "$(date '+%Y-%m-%d 07:00:00')" +%s)
    local TIME_CUR=$(date +%s)
    if [ "${portServIncludeFailedCode}" = "63027" ]; then
        if [ ${TIME_CUR} -gt ${TIME_STOP1} ] || [ ${TIME_CUR} -lt ${TIME_STOP2} ]; then
            SHOULD_STOP=true
        fi
    fi
    if [ "$SHOULD_STOP" = true ]; then
        LOG I "EXIT!"
        exit
    fi
}

function check_connect() {
    if [ $(curl -sI -w "%{http_code}" -o /dev/null connect.rom.miui.com/generate_204) = 204 ]; then
        CONNECT=true
        RECONN_COUNT="0"
    else
        CONNECT=false
    fi
}

function doHeartBeat() {
    local TIME=$(date '+%Y-%m-%d %H:%M:%S')
    LOG I "Start do HeartBeat ${TIME}"
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
    LOG D "doHeartBeat_INFO: $doHeartBeat_INFO"
}
function restart_auth() {
    let RECONN_COUNT++
    SLEEP_TIME=$(expr $SLEEP_TIME \* $RECONN_COUNT)
    LOG N "Wait ${SLEEP_TIME}s"
    sleep $SLEEP_TIME
    LOG N "Reconnecting: $RECONN_COUNT TIME"
    start_auth
}
function start_auth() {
    LOG I "Start auth"
    LOG I "Send Login request"
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
        LOG E "Network error"
        restart_auth
    else #收到回应，可以连接上认证服务器
        LOG I "Analyzing authentication results"
        local DATA_ENCODEURL=$(printf "%s" "${DATA}==" | base64 -d)
        local JSON=$(urldecode "${DATA_ENCODEURL}")
        LOG D "JSON: ${JSON}"
        local v_errorNumber=$(get_json_value "${JSON}" errorNumber)
        LOG D "v_errorNumber=$v_errorNumber"
        if [ "${v_errorNumber}" = "1" ]; then #认证成功
            CONNECT_TIME=$(date +%s)
            portalLink=$(get_json_value "${JSON}" portalLink)
            local v_jsonStr=${portalLink}
            local TIME=$(date '+%Y-%m-%d %H:%M:%S')
            LOG I "Login Success ${TIME}"
            if [ ! -n "${v_jsonStr}" ]; then #解码失败
                LOG E "portalLink DEBASE64 error"
                restart_auth
            fi

            local portalLink_ENCODEURL_DEBASE64="$(printf "%s" "${v_jsonStr}" | base64 -d)"
            v_json=$(urldecode "${portalLink_ENCODEURL_DEBASE64}")
            if [ ! -n "${v_json}" ]; then #解码失败
                LOG E "portalLink DecodeURL error"
                restart_auth
            fi
            LOG D "v_json: ${v_json}"
            local ifNeedModifyPwd=$(get_json_value $v_json ifNeedModifyPwd)
            if [ "${ifNeedModifyPwd}" = true ]; then #要求修改密码
                LOG W "Need Modify Pwd"
            fi

            local heartBeatCyc=$(get_json_value $v_json heartBeatCyc)
            if [ $heartBeatCyc -gt 0 ]; then #要求心跳
                requires_heartBeat=true
                heartBeatCyc_TRUE=$(expr $heartBeatCyc / 1000)
                SLEEP_TIME=$(expr $heartBeatCyc_TRUE / 2)
                LOG I "The connection requires a heartbeat every ${heartBeatCyc_TRUE} seconds. Please do not terminate the script."
                [ -n "${DEBUG}" ] && doHeartBeat
            else
                requires_heartBeat=false
                SLEEP_TIME="60"
            fi
            portServIncludeFailedCode=""
            portServErrorCode=""

        else #认证失败
            portServIncludeFailedCode=$(get_json_value "${JSON}" portServIncludeFailedCode)
            local portServIncludeFailedReason=$(get_json_value "${JSON}" portServIncludeFailedReason)
            local v_errorInfo=$(get_json_value "${JSON}" portServErrorCodeDesc)
            portServErrorCode=$(get_json_value "${JSON}" portServErrorCode)
            if [ -n "${portServIncludeFailedCode}" ]; then
                LOG E "${portServIncludeFailedReason}"
                if [ "${portServIncludeFailedCode}" = "63013" -o "${portServIncludeFailedCode}" = "63015" -o "${portServIncludeFailedCode}" = "63018" -o "${portServIncludeFailedCode}" = "63025" -o "${portServIncludeFailedCode}" = "63026" -o "${portServIncludeFailedCode}" = "63031" -o "${portServIncludeFailedCode}" = "63032" -o "${portServIncludeFailedCode}" = "63100" ]; then
                    LOG E "EXIT!"
                    exit
                fi
                check_SHOULD_STOP
            elif [ -n "${portServErrorCode}" ]; then
                LOG E "${v_errorInfo}"
                SLEEP_TIME="1"
                if [ "${portServErrorCode}" = 2 ]; then
                    CONNECT_TIME=$(date +%s)
                elif [ "${portServErrorCode}" = 3 ]; then
                    restart_auth

                else #未知错误
                    LOG E "Unknown error $portServErrorCode, login failed. EXIT!"
                    exit
                fi
            fi
            if [ "${v_errorNumber}" = "-1" ]; then
                local e_c=$(get_json_value "${JSON}" e_c)
                local e_d=$(get_json_value "${JSON}" e_d)
                local portal_error=$(get_json_value "${JSON}" "${e_c}")
                local errorDescription=$(get_json_value "${JSON}" "${e_d}")
                LOG D "e_c=$e_c e_d=$e_d portal_error=$portal_error errorDescription=$errorDescription"
                LOG E "${BaseName}" -p user.err "$portal_error $errorDescription EXIT!"
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
            restart_auth
        fi
    fi
    sleep $SLEEP_TIME
done
