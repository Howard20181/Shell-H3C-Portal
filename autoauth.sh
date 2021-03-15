#!/bin/sh
init() {
    byodserverip="10.0.15.101" #imc_portal_function_readByodServerAddress
    byodserverhttpport="8080"  #imc_portal_function_readByodServerHttpPort

    v_loginType="3"
    v_is_selfLogin="0"
    uamInitCustom="1"
    uamInitLogo="H3C"

    portServFailedReason_json='{"63013":"用户已被加入黑名单","63015":"用户已失效","63018":"用户不存在或者用户没有申请该服务","63024":"端口绑定检查失败","63025":"MAC地址绑定检查失败","63026":"静态IP地址绑定检查失败","63027":"接入时段限制","63031":"用户密码错误，该用户已经被加入黑名单","63032":"密码错误，密码连续错误次数超过阈值将会加入黑名单","63634":"当前场景下绑定终端数量达到限制","63048":"设备IP绑定检查失败","63073":"用户在对应的场景下不允许接入","63100":"无效认证客户端版本"}'
    SLEEP_TIME="1"
}

alias decodeURIComponent="sed 's/%/\\\\x/g' | xargs -0 printf '%b'"

encodeURIComponent() {
    local data=$1
    if [ -n "$1" ]; then
        local data="$(echo $data | curl -Gso /dev/null -w %{url_effective} --data-urlencode @- "" | sed -E 's/..(.*).../\1/')"
    else
        echo "Usage: encodeURIComponent <string-to-urlencode>"
    fi
    echo "${data##/?}"
}

get_json_value() {
    local json=$1
    local key=$2
    if [ -z "$3" ]; then
        local num=1
    else
        local num=$3
    fi
    local value=$(echo "${json}" | awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/'${key}'\042/){print $(i+1)}}}' | tr -d '"' | sed -n "${num}"p)
    echo "${value}"
}

reflush_TIME() {
    TIME_CUR=$(date +%s)
    TIME=$(date '+%Y-%m-%d %H:%M:%S')
}
check_SHOULD_STOP() {
    reflush_TIME
    TIME_STOP=$(date -d "$(date '+%Y-%m-%d 23:15:00')" +%s)
    if [ $TIME_CUR -gt $TIME_STOP ]; then
        if [ "${portServIncludeFailedCode}" = "63027" ]; then
            SHOULD_STOP=true
        else
            SHOULD_STOP=false
        fi
    else
        SHOULD_STOP=false
        if [ "${portServIncludeFailedCode}" = "63027" ]; then
            SLEEP_TIME="60"
        else
            SLEEP_TIME="1"
        fi
    fi
}
reflush_CONNECT_TIME() {
    CONNECT_TIME=$(date +%s)
    reflush_TIME
}
check_connect() {
    if [ $(curl -sI -w "%{http_code}" -o /dev/null connect.rom.miui.com/generate_204) = 204 ]; then
        CONNECT=true
    else
        CONNECT=false
    fi
}
doHeartBeat() {
    echo "Start do HeartBeat ${TIME}"
    userDevPort=$(get_json_value $v_json userDevPort)
    userDevPort_ENCODEURL=$(encodeURIComponent $userDevPort)
    userStatus=$(get_json_value $v_json userStatus)
    serialNo=$(get_json_value $v_json serialNo)
    v_Language=$(get_json_value $v_json clientLanguage)

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
    reflush_CONNECT_TIME
    #echo doHeartBeat_INFO: $doHeartBeat_INFO #debug
}

loop() {
    while [ true ]; do
        check_connect
        if [ "$CONNECT" = true ]; then
            reflush_TIME
            TMP=$(($TIME_CUR - $CONNECT_TIME))
            if [ "${requires_heartBeat}" = true ]; then
                if [ $TMP -gt "$heartBeatCyc_TRUE" ]; then
                    doHeartBeat
                fi
            fi
        elif [ "$CONNECT" = false ]; then
            check_SHOULD_STOP
            if [ "$SHOULD_STOP" = true ]; then
                break
            elif [ "$SHOULD_STOP" = false ]; then
                echo Reconnecting
                start_auth
            fi
        fi
        sleep $SLEEP_TIME
    done
}

start_auth() {
    echo "Start auth"
    echo "Send Login request"
    PWD_BASE64="$(printf $PWD | base64)"
    PWD_BASE64_ENCODEURL=$(encodeURIComponent $PWD_BASE64)
    appRootUrl="http://$byodserverip:$byodserverhttpport/portal/"
    appRootUrl_ENCODEURL=$(encodeURIComponent $appRootUrl)
    DATA=$(curl -s ''$appRootUrl'pws?t=li' \
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
        echo "Network error"
    else #收到回应，可以连接上认证服务器
        echo "Analyzing authentication results"
        DATA_ENCODEURL=$(printf "%s" "${DATA}==" | base64 -d)
        JSON=$(echo "${DATA_ENCODEURL}" | decodeURIComponent)
        #echo JSON: "${JSON}" #debug
        v_errorNumber=$(get_json_value "${JSON}" errorNumber)

        if [ "${v_errorNumber}" = "1" ]; then #认证成功
            reflush_CONNECT_TIME
            portalLink=$(get_json_value "${JSON}" portalLink)
            v_jsonStr=${portalLink}
            echo "Login Success "${TIME}""

            if [ ! -n "${v_jsonStr}" ]; then #解码失败
                echo "ERROR: portalLink DEBASE64 error"
                start_auth
            fi

            portalLink_ENCODEURL_DEBASE64="$(printf "%s" "${v_jsonStr}" | base64 -d)"
            v_json=$(echo $portalLink_ENCODEURL_DEBASE64 | decodeURIComponent)
            if [ ! -n "${v_json}" ]; then #解码失败
                echo "ERROR: portalLink DecodeURL error"
                start_auth
            fi
            #echo v_json: "${v_json}" #debug
            ifNeedModifyPwd=$(get_json_value $v_json ifNeedModifyPwd)
            if [ "${ifNeedModifyPwd}" = true ]; then #要求修改密码
                echo Need Modify Pwd

            fi

            heartBeatCyc=$(get_json_value $v_json heartBeatCyc)
            if [ "$heartBeatCyc" -gt 0 ]; then #要求心跳
                requires_heartBeat=true
                heartBeatCyc_TRUE=$(expr $heartBeatCyc / 1000)
                SLEEP_TIME=$(expr $heartBeatCyc_TRUE / 2 - 1)
                echo "The connection requires a heartbeat every ${heartBeatCyc_TRUE} seconds. Please do not terminate the script."
                #doHeartBeat #debug
            else
                requires_heartBeat=false
            fi
            portServIncludeFailedCode=""
            portServErrorCode=""

        else #认证失败
            portServIncludeFailedCode=$(get_json_value "${JSON}" portServIncludeFailedCode)
            portServIncludeFailedReason=$(get_json_value "${JSON}" portServIncludeFailedReason)
            v_errorInfo=$(get_json_value "${JSON}" portServErrorCodeDesc)
            portServErrorCode=$(get_json_value "${JSON}" portServErrorCode)
            if [ -n "${portServIncludeFailedCode}" ]; then
                portServFailedReason=$(get_json_value "${portServFailedReason_json}" "${portServIncludeFailedCode}")
                #echo Error: "${v_errorInfo}"
                echo Info: "${portServIncludeFailedReason}": "${portServFailedReason}"
                if [ "${portServIncludeFailedCode}" = "63013" -o "${portServIncludeFailedCode}" = "63015" -o "${portServIncludeFailedCode}" = "63018" -o "${portServIncludeFailedCode}" = "63025" -o "${portServIncludeFailedCode}" = "63026" -o "${portServIncludeFailedCode}" = "63031" -o "${portServIncludeFailedCode}" = "63032" -o "${portServIncludeFailedCode}" = "63100" ]; then
                    echo EXIT!
                    exit
                fi

            elif [ -n "${portServErrorCode}" ]; then
                echo Error: "${v_errorInfo}"
                SLEEP_TIME="1"
                if [ "${portServErrorCode}" = 2 ]; then
                    reflush_CONNECT_TIME
                elif [ "${portServErrorCode}" = 3 ]; then
                    start_auth

                else #未知错误
                    echo "Unknown error, login failed."
                    exit
                fi
            fi
        fi
    fi
    loop
}

mutual_exclusion() {
    PID=$(ps | grep auto-auth:S | grep -v grep | awk '{print $1}')
    if [ ! -n "$PID" ]; then
        echo start run
        init
        start_auth
    else
        echo EXIT:程序正在运行中，请勿重复运行！
        exit
    fi
}

check_info() {
    #echo 1:$1 2:$2 USERID: $USERID auto-auth:S #debug
    if [ -n "$1" ]; then
        USERID="$1"

        if [ -n "$2" ]; then
            PWD="$2"
        else
            echo PWD_ERR! EXIT!
            exit
        fi
    else
        echo USERID_ERR! EXIT!
        exit
    fi

    mutual_exclusion
}

check_info $1 $2
