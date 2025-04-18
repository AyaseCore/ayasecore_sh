#!/bin/bash

# 全局变量声明
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_INSTALL_DIR="$SCRIPT_DIR/mysql"
INSTALL_DIR=""
PORT="3308"
MYSQL_USER="root"
MYSQL_PASSWORD=""
MY_CNF=""
CURRENT_STATUS="未运行"
ALLOW_REMOTE=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 检查sudo权限
check_sudo() {
    if ! sudo -v &>/dev/null; then
        echo -e "${RED}错误：当前用户没有sudo权限，无法安装mariadb-server。${NC}"
        exit 1
    fi
}

install_mariadb_server() {
    if command -v mysql &>/dev/null; then
        mysql_full_info=$(mysql --version)
        client_ver=$(awk '{print $3}' <<< "$mysql_full_info")  # 客户端版本
        server_ver=$(awk -F 'Distrib |,' '{print $2}' <<< "$mysql_full_info")  # 服务端版本
        platform=$(awk -F 'for | using' '{print $2}' <<< "$mysql_full_info")   # 平台信息

        # 格式化输出
        echo -e "${YELLOW}检测到已安装的Mysql/MariaDB数据库："
        echo -e "客户端版本：${client_ver}"
        echo -e "服务端版本：${server_ver}"
        echo -e "运行平台：${platform}"
        return
    fi

    if ! dpkg -s mariadb-server &>/dev/null; then
        echo -e "${YELLOW}未安装mariadb-server，正在安装...${NC}"
        sudo apt-get update
        sudo apt-get install -y mariadb-server
        echo -e "${GREEN}mariadb-server 安装完成。${NC}"
    else
        echo -e "${GREEN}mariadb-server 已经安装。${NC}"
    fi
}


# 获取安装目录
get_install_dir() {
    read -p "请输入数据库安装目录（默认为 $DEFAULT_INSTALL_DIR）: " user_input
    user_input=${user_input:-$DEFAULT_INSTALL_DIR}
    INSTALL_DIR=$(realpath -m "$user_input")
    
    if [[ "$INSTALL_DIR" != */mysql ]]; then
        INSTALL_DIR="$INSTALL_DIR/mysql"
    fi
    
    echo -e "安装目录设置为：${YELLOW}$INSTALL_DIR${NC}"
}

# 检查数据库状态
check_database_status() {
    if [ -f "$INSTALL_DIR/mysql.pid" ]; then
        local pid=$(cat "$INSTALL_DIR/mysql.pid")
        if ps -p "$pid" > /dev/null 2>&1; then
            CURRENT_STATUS="运行中（PID: $pid）"
            return 0
        else
            CURRENT_STATUS="未运行(PID文件残留)"
            return 1
        fi
    else
        CURRENT_STATUS="未运行"
        return 1
    fi
}

check_port() {
    # 使用Python尝试绑定端口验证可用性
    if python3 -c "import socket; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', $1)); s.close()" 2>/dev/null
    then
        echo -e "${GREEN}端口 $1 可用。${NC}"
        return 0
    else
        echo -e "${RED}端口 $1 已被占用，请更换其他端口。${NC}"
        return 1
    fi
}


# 修改端口函数
change_port() {
    # 检查是否已经初始化
    if [ -z "$MY_CNF" ] || [ ! -f "$MY_CNF" ]; then
        echo -e "${RED}错误：请先初始化数据库实例${NC}"
        return 1
    fi

    # 检查运行状态
    check_database_status
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}需要先停止数据库才能修改端口${NC}"
        read -p "是否立即停止数据库？[Y/n]: " stop_confirm
        stop_confirm=${stop_confirm:-Y}
        if [[ "$stop_confirm" =~ [Yy] ]]; then
            stop_database || return 1
        else
            echo -e "${RED}已取消端口修改操作${NC}"
            return 1
        fi
    fi

    # 获取新端口
    local old_port=$PORT
    get_port

    # 修改配置文件
    sed -i "s/^port\s*=.*/port = $PORT/" "$MY_CNF"
    echo -e "${GREEN}端口已从 $old_port 修改为 $PORT${NC}"

    # 询问是否启动
    read -p "是否立即启动数据库？[Y/n]: " start_confirm
    start_confirm=${start_confirm:-Y}
    if [[ "$start_confirm" =~ [Yy] ]]; then
        start_database
    else
        echo -e "${YELLOW}请手动启动数据库使新端口生效${NC}"
    fi
}


# 创建目录结构
create_directories() {
    echo -e "${YELLOW}正在创建目录结构...${NC}"
    mkdir -p "$INSTALL_DIR"/{data,logs/{binlog,error},tmp}
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}目录创建失败，请检查权限设置。${NC}"
        exit 1
    fi
}

# 生成配置文件
generate_my_cnf() {
    MY_CNF="$INSTALL_DIR/my.cnf"
    cat > "$MY_CNF" <<EOF
[mysqld]
bind-address    = 127.0.0.1
port            = $PORT
socket          = $INSTALL_DIR/mysql.sock
pid-file        = $INSTALL_DIR/mysql.pid
datadir         = $INSTALL_DIR/data
tmpdir          = $INSTALL_DIR/tmp
log-bin         = $INSTALL_DIR/logs/binlog/mysql-bin
log-error       = $INSTALL_DIR/logs/error/mysql-error.log

max_binlog_size = 512M

lower_case_table_names=1
character-set-server  = utf8mb4
collation-server      = utf8mb4_unicode_ci
skip-external-locking
skip-name-resolve
server-id       = 1
EOF
    echo -e "${GREEN}配置文件已生成：$MY_CNF${NC}"
}

# 查找命令的真实路径（处理链接文件）
find_command_path() {
    local cmd=$1
    local path=$(which "$cmd" 2>/dev/null)
    
    [ -z "$path" ] && return 1
    
    while [ -L "$path" ]; do
        path=$(readlink -f "$path")
    done
    
    echo "$(dirname "$path")"
    return 0
}

# 查找关联命令路径并验证可执行性
get_related_command_path() {
    local base_cmd=$1
    local sub_cmd=$2

    # 先检查子命令是否存在
    if command -v "$sub_cmd" &>/dev/null; then
        echo "$sub_cmd"
        return 0
    fi

    # 查找基础命令目录
    local base_dir=$(find_command_path "$base_cmd")
    [ $? -ne 0 ] && return 1

    # 拼接子命令完整路径
    local sub_path="${base_dir}/${sub_cmd}"

    # 验证可执行文件
    if [ ! -x "$sub_path" ]; then
        echo -e "${RED}错误：未找到可执行的 ${sub_cmd}${NC}" >&2
        echo -e "${YELLOW}请确保该文件存在于: ${sub_path}${NC}" >&2
        return 1
    fi

    echo "$sub_path"
    return 0
}

# 初始化数据库
initialize_database() {
    echo -e "${YELLOW}正在初始化数据库...${NC}"

    # 获取mysql_install_db路径
    local install_db_path
    install_db_path=$(get_related_command_path mysql mysql_install_db) || exit 1

    local basedir="$(dirname "$install_db_path")/.."
    if [ "$install_db_path" == "mysql_install_db" ]; then
        basedir="/usr"
    fi

    # 使用mysql_install_db初始化
    sudo "$install_db_path" --defaults-file="$MY_CNF" --user=$(whoami) --basedir="$basedir" --datadir="$INSTALL_DIR/data"

    [ $? -ne 0 ] && {
        echo -e "${RED}数据库初始化失败，请检查日志文件。${NC}"
        exit 1
    }
    
    echo -e "${GREEN}数据库初始化成功。${NC}"
}


# 启动数据库服务
start_database() {
    # 检查是否存在残留的PID文件
    if [ -f "$INSTALL_DIR/mysql.pid" ]; then
        local pid=$(cat "$INSTALL_DIR/mysql.pid")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "${YELLOW}数据库已经在运行（PID: $pid）。${NC}"
            CURRENT_STATUS="运行中（PID: $pid）"
            return 1
        else
            echo -e "${YELLOW}发现残留的PID文件，但进程未运行，清理中...${NC}"
            rm -f "$INSTALL_DIR/mysql.pid"
            rm -f "$INSTALL_DIR/mysql.sock"
        fi
    fi

    echo -e "${YELLOW}正在启动数据库...${NC}"
    local mysqld_path
    mysqld_path=$(get_related_command_path mysql mysqld) || exit 1
    sudo "$mysqld_path" --defaults-file="$MY_CNF" --user=$(whoami) &
    return  
}

toggle_remote_access() {
    # 检查配置文件存在性
    [ ! -f "$MY_CNF" ] && echo -e "${RED}请先初始化实例${NC}" && return 1

    # 检查数据库运行状态
    check_database_status || {
        echo -e "${RED}数据库未运行，无法修改权限${NC}"
        return 1
    }

    # 获取当前绑定地址
    local current_bind=$(grep -Po 'bind-address\s*=\s*\K[^\s]+' "$MY_CNF")
    current_bind=${current_bind:-127.0.0.1}
    local new_bind

    # 确认操作
    if [[ "$current_bind" == "127.0.0.1" ]]; then
        new_bind="0.0.0.0"
        echo -e "${YELLOW}警告：开放外网访问存在安全风险！${NC}"
        read -p "确认要允许外网访问？[y/N]: " confirm
        [[ ! "$confirm" =~ [yY] ]] && return
    else
        new_bind="127.0.0.1"
    fi

    # 先执行权限变更
    if mysql_cmd="sudo mysql --socket=$INSTALL_DIR/mysql.sock -u root -p"$MYSQL_PASSWORD""; then
        # 执行权限修改SQL
        if [[ "$new_bind" == "0.0.0.0" ]]; then
            if ! $mysql_cmd <<EOF
GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' WITH GRANT OPTION;
GRANT ALL ON *.* TO 'root'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASSWORD' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
            then
                echo -e "${RED}权限授予失败，已取消操作${NC}"
                return 1
            fi
        else
            if ! $mysql_cmd <<EOF
DELETE FROM mysql.user WHERE User='root' AND Host='%';
GRANT ALL ON *.* TO 'root'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASSWORD' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
            then
                echo -e "${RED}权限撤销失败，已取消操作${NC}"
                return 1
            fi
        fi

        # 权限修改成功后再改配置文件
        sed -i "s/^bind-address\s*=.*/bind-address = $new_bind/" "$MY_CNF"
        echo -e "${GREEN}配置已更新，新绑定地址将在重启后生效${NC}"

        # 立即重启确认
        read -p "是否立即重启使配置生效？[Y/n]: " restart_confirm
        if [[ ! "$restart_confirm" =~ [nN] ]]; then
            stop_database
            start_database
        else
            echo -e "${YELLOW}请手动重启服务使新配置生效${NC}"
        fi
    else
        echo -e "${RED}数据库连接失败，请检查密码和服务状态${NC}"
        return 1
    fi
}

# 设置root密码
set_root_password() {
    local old_password new_password
    local password_file="$INSTALL_DIR/root.password"
    local mysql_secret_path="$HOME/.mysql_secret"
    local has_mysql_secret=0
    local mysql_options=()  # 新增选项数组

    if [ -f "$mysql_secret_path" ]; then
        old_password=$(sed -n '2p' "$mysql_secret_path")
        has_mysql_secret=1
        mysql_options+=(--connect-expired-password)  # 添加特殊选项
    else
        [ -f "$password_file" ] && old_password=$(cat "$password_file") || old_password=""
    fi

    while true; do
        read -sp "请输入root用户的新密码: " new_password
        echo
        if [ -z "$new_password" ]; then
            echo -e "${RED}密码不能为空，请重新输入。${NC}"
            continue
        fi
        break
    done

    if [ -n "$old_password" ]; then
        sudo mysql --socket="$INSTALL_DIR/mysql.sock" "${mysql_options[@]}" -u root -p"$old_password" \
            -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_password';" &>/dev/null
    else
        sudo mysql --socket="$INSTALL_DIR/mysql.sock" -u root \
            -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_password';" &>/dev/null
    fi

    if [ $? -eq 0 ]; then
        [ $has_mysql_secret -eq 1 ] && rm -f "$mysql_secret_path"
        echo "$new_password" > "$password_file"
        MYSQL_PASSWORD=$new_password
        echo -e "${GREEN}密码设置成功！${NC}"
    else
        echo -e "${RED}密码设置失败，可能原因：${NC}"
        [ $has_mysql_secret -eq 1 ] && \
        echo -e "0. MySQL临时密码已过期（使用来自 $mysql_secret_path 的旧密码: $old_password）。"
        echo -e "1. 旧密码不正确（当前使用旧密码文件: $password_file）"
        echo -e "2. 数据库服务未运行"
        echo -e "3. 缺少sudo权限"
    fi
}


get_port() {
    local default_port=$PORT
    while true; do
        read -p "请输入数据库端口号（当前为 $default_port）: " port_input
        port_input=${port_input:-$default_port}
        if [[ ! $port_input =~ ^[0-9]+$ ]] || [ $port_input -lt 1 ] || [ $port_input -gt 65535 ]; then
            echo -e "${RED}错误：端口号必须是1-65535之间的整数。${NC}"
            continue
        fi
        if check_port "$port_input"; then
            PORT=$port_input
            break
        else
            echo -e "${RED}端口 $port_input 已被占用，请选择其他端口。${NC}"
        fi
    done
}

# 数据库初始化流程
database_init() {
    get_install_dir
    create_directories
    get_port
    generate_my_cnf
    initialize_database
    start_database
}

# 导入SQL数据
import_sql_data() {
    clear
    local socket="$INSTALL_DIR/mysql.sock"
    local user="root"
    local password="$MYSQL_PASSWORD"
    local sql_dir="$SCRIPT_DIR/sql"
    local error_msg=""
    
    # 检查pv安装
    local HAS_PV=true
    if ! command -v pv &>/dev/null; then
        echo -e "${YELLOW}未检测到pv工具，进度显示不可用${NC}"
        read -p "是否立即安装pv？[y/N]: " install_pv
        if [[ "$install_pv" =~ [yY] ]]; then
            echo "正在安装pv..."
            sudo apt-get -qq install pv || sudo yum -q install pv
            HAS_PV=true
        else
            HAS_PV=false
        fi
    fi

    # 检查sql目录是否存在
    if [ ! -d "$sql_dir" ]; then
        echo -e "${RED}错误：SQL目录 $sql_dir 不存在${NC}"
        read -n1 -r -p "按任意键返回..."
        return
    fi

    # 获取所有SQL文件及大小
    declare -A file_sizes
    for file in "$sql_dir"/*.sql; do
        if [ -f "$file" ]; then
            size_bytes=$(stat -c %s "$file")
            size_mb=$(awk "BEGIN {printf \"%.2f\", $size_bytes/1024/1024}")
            file_sizes["$(basename "$file")"]=$size_mb
        fi
    done

    # 获取所有SQL文件
    local sql_files=($(find "$sql_dir" -maxdepth 1 -name '*.sql' -exec basename {} \;))
    if [ ${#sql_files[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有找到可导入的SQL文件${NC}"
        read -n1 -r -p "按任意键返回..."
        return
    fi

    while true; do
        clear
        echo -e "${GREEN}════════════ 导入SQL数据 ════════════${NC}"
        echo -e "${YELLOW}注意：将根据文件名创建对应数据库（示例：test.sql → 数据库test）${NC}"
        
        # 显示可导入选项
        local i=1
        for file in "${sql_files[@]}"; do
            size_mb=${file_sizes["$file"]}
            printf "50%1d. %-20s (%5.2fMB)\n" $i "${file%.*}" $size_mb
            ((i++))
        done
        
        local all_opt=$((500 + i))
        echo "${all_opt}. 导入全部SQL文件"
        echo "500. 返回上一层"

        # 显示错误信息
        [ -n "$error_msg" ] && echo -e "${RED}${error_msg}${NC}" && error_msg=""

        # 处理用户输入
        read -p "请选择要导入的SQL文件: " choice
        
        # 输入验证
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            error_msg="请输入有效数字"
            continue
        fi

        # 处理返回
        if [ "$choice" -eq 500 ]; then
            return
        fi

        # 处理导入全部
        if [ "$choice" -eq "$all_opt" ]; then
            for file in "${sql_files[@]}"; do
                process_sql_import "$file" "$sql_dir" "$socket" "$user" "$password" "$HAS_PV"
            done
            read -n1 -r -p "按任意键继续..."
            continue
        fi

        # 处理单个导入
        if [ "$choice" -ge 501 ] && [ "$choice" -le $((500 + ${#sql_files[@]})) ]; then
            local index=$((choice - 501))
            if [ $index -ge 0 ] && [ $index -lt ${#sql_files[@]} ]; then
                process_sql_import "${sql_files[$index]}" "$sql_dir" "$socket" "$user" "$password" "$HAS_PV"
                read -n1 -r -p "按任意键继续..."
                continue
            fi
        fi

        error_msg="无效选项，请重新输入"
    done
}

# SQL导入处理函数
process_sql_import() {
    local file="$1"
    local sql_dir="$2"
    local socket="$3"
    local user="$4"
    local password="$5"
    local has_pv="$6"
    local db_name="${file%.*}"
    local sql_file="$sql_dir/$file"
    
    echo -e "\n${GREEN}════════════ 处理 $db_name ════════════${NC}"

    # 检查数据库是否存在
    local db_exists=$(mysql --socket="$socket" -u "$user" -p"$password" \
        -e "SHOW DATABASES LIKE '$db_name'" 2>/dev/null | grep -o "$db_name")

    if [ -n "$db_exists" ]; then
        echo -e "${YELLOW}数据库 $db_name 已存在！${NC}"
        while true; do
            echo -e "请选择操作："
            echo "1. 直接导入（可能覆盖现有数据）"
            echo "2. 删除数据库后重新导入"
            echo "3. 取消当前导入"
            read -p "请输入选项 [1-3]: " action
            case $action in
                1)
                    read -p "直接导入可能造成数据冲突，是否继续？[y/N]: " confirm
                    [[ ! "$confirm" =~ [yY] ]] && return
                    break
                    ;;
                2)
                    read -p "将永久删除数据库 $db_name，确认吗？[y/N]: " confirm
                    if [[ "$confirm" =~ [yY] ]]; then
                        echo -e "${YELLOW}正在删除数据库...${NC}"
                        if ! mysql --socket="$socket" -u "$user" -p"$password" \
                            -e "DROP DATABASE \`$db_name\`"; then
                            echo -e "${RED}数据库删除失败！${NC}"
                            read -n1 -r -p "按任意键继续..."
                            return
                        fi
                        # 删除后重新创建
                        mysql --socket="$socket" -u "$user" -p"$password" \
                            -e "CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
                        break
                    else
                        return
                    fi
                    ;;
                3)
                    echo -e "${YELLOW}已取消导入 $db_name${NC}"
                    read -n1 -r -p "按任意键继续..."
                    return
                    ;;
                *)
                    echo -e "${RED}无效选项，请重新输入${NC}"
                    ;;
            esac
        done
    else
        # 数据库不存在时创建
        echo -e "${YELLOW}创建新数据库 $db_name...${NC}"
        if ! mysql --socket="$socket" -u "$user" -p"$password" \
            -e "CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"; then
            echo -e "${RED}数据库创建失败！${NC}"
            read -n1 -r -p "按任意键继续..."
            return
        fi
    fi

    # 开始导入数据
    echo -e "正在导入 ${YELLOW}$file${NC}..."
    import_success=false
    if $has_pv; then
        if pv -W -N "导入进度" "$sql_file" | mysql --socket="$socket" -u "$user" -p"$password" "$db_name"; then
            import_success=true
        fi
    else
        if mysql --socket="$socket" -u "$user" -p"$password" "$db_name" < "$sql_file"; then
            import_success=true
        fi
    fi

    # 处理导入结果
    if $import_success; then
        echo -e "${GREEN}成功导入 $db_name 数据！${NC}"
    else
        echo -e "${RED}$db_name 数据导入失败！${NC}"
        # 如果是新创建的数据库，建议删除空库
        if [ -z "$db_exists" ]; then
            read -p "是否删除新建的空数据库 $db_name？[y/N]: " clean_confirm
            if [[ "$clean_confirm" =~ [yY] ]]; then
                mysql --socket="$socket" -u "$user" -p"$password" -e "DROP DATABASE \`$db_name\`"
            fi
        fi
    fi
    read -n1 -r -p "按任意键继续..."
}



# 停止数据库服务
stop_database() {
    if [ ! -f "$INSTALL_DIR/mysql.pid" ]; then
        echo -e "${YELLOW}数据库似乎没有在运行。${NC}"
        CURRENT_STATUS="未运行"
        return
    fi

    local pid=$(cat "$INSTALL_DIR/mysql.pid")
    echo -e "${YELLOW}正在停止数据库...${NC}"
    local mysqladmin_path
    mysqladmin_path=$(get_related_command_path mysql mysqladmin) || exit 1

    sudo "$mysqladmin_path" --socket="$INSTALL_DIR/mysql.sock" -u root -p"$MYSQL_PASSWORD" shutdown

    # 等待进程停止
    local wait_seconds=5
    while (( wait_seconds > 0 )); do
        if ! ps -p "$pid" > /dev/null 2>&1; then
            break
        fi
        sleep 1
        ((wait_seconds--))
    done

    if ps -p "$pid" > /dev/null 2>&1; then
        echo -e "${RED}停止数据库失败，可能需要强制终止进程。${NC}"
        return 1
    else
        CURRENT_STATUS="未运行"
        # 清理残留文件
        rm -f "$INSTALL_DIR/mysql.pid"
        rm -f "$INSTALL_DIR/mysql.sock"
        echo -e "${GREEN}数据库已停止。${NC}"
        return 0
    fi
}

# 显示状态信息
show_status() {
    clear
    local bind_status

    if [ -f "$MY_CNF" ]; then
        local current_bind=$(grep -E '^bind-address[[:space:]]*=' "$MY_CNF" | awk -F'=' '{print $2}' | tr -d ' ')
        [ -z "$current_bind" ] && current_bind="127.0.0.1"
        bind_status=$([ "$current_bind" = "0.0.0.0" ] && echo "允许" || echo "禁止")
    else
        bind_status="未配置"
    fi
    
    echo -e "\n${GREEN}══════════════ 数据库状态 ══════════════${NC}"
    echo -e "安装目录：${YELLOW}$INSTALL_DIR${NC}"
    #echo -e "数据目录：${YELLOW}$INSTALL_DIR/data${NC}"
    echo -e "端口号：${YELLOW}$PORT${NC}"
    echo -e "root密码：${YELLOW}$MYSQL_PASSWORD${NC}"
    echo -e "运行状态：${YELLOW}$CURRENT_STATUS${NC}"
    echo -e "外网访问：${YELLOW}$bind_status${NC}"

    echo -e "${GREEN}═══════════  script by ayase  ══════════${NC}"
}

# 重新初始化实例
reinitialize_instance() {
    echo -e "${YELLOW}════════════ 重新初始化实例 ════════════${NC}"
    read -p "这将删除所有数据！确认吗？[y/N]: " confirm
    if [[ $confirm =~ [yY] ]]; then
        stop_database
        # 强制删除所有实例文件
        rm -rf "${INSTALL_DIR:?}/"/*
        # 重新初始化
        create_directories
        get_port
        generate_my_cnf
        initialize_database
        start_database
        echo -e "${GREEN}实例已重新初始化！${NC}"
    else
        echo -e "${YELLOW}已取消重新初始化。${NC}"
    fi
}

# 删除数据库
delete_database() {
    clear
    local socket="$INSTALL_DIR/mysql.sock"
    local user="root"
    local password="$MYSQL_PASSWORD"
    local error_msg=""

    # 尝试连接数据库以判断是否正在运行
    if ! mysql --socket="$socket" -u "$user" -p"$password" -e "SELECT 1;" &>/dev/null; then
        echo -e "${RED}数据库未运行，请先启动数据库。${NC}"
        read -n1 -r -p "按任意键返回..."
        return
    fi

    while true; do
        clear
        # 动态绘制菜单界面
        echo -e "${GREEN}════════════ 删除数据库 ════════════${NC}"
        
        # 实时获取数据库列表
        local databases=($(mysql --socket="$socket" -u "$user" -p"$password" -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "Database|information_schema|performance_schema|mysql|test"))

        if [ ${#databases[@]} -eq 0 ]; then
            echo -e "${YELLOW}没有可删除的数据库${NC}"
            echo "600. 返回上一层"
        else
            echo -e "${YELLOW}请选择要删除的数据库：${NC}"
            # 动态生成选项编号
            local i=1
            for db in "${databases[@]}"; do
                echo "$((600 + i)). $db"
                ((i++))
            done
            local all_opt=$((600 + i))
            echo "${all_opt}. 删除所有数据库"
            echo "600. 返回上一层"
        fi

        # 显示错误信息（如果有）
        [ -n "$error_msg" ] && echo -e "${RED}${error_msg}${NC}" && error_msg=""

        # 处理用户输入
        read -p "请输入选项: " choice
        
        # 输入验证
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            error_msg="请输入有效数字"
            continue
        fi

        # 处理返回
        if [ "$choice" -eq 600 ]; then
            return
        fi

        # 处理所有删除
        if [ ${#databases[@]} -gt 0 ] && [ "$choice" -eq "$all_opt" ]; then
            for db in "${databases[@]}"; do
                echo -e "删除中 ${YELLOW}${db}${NC}..."
                mysql --socket="$socket" -u "$user" -p"$password" -e "DROP DATABASE IF EXISTS $db;" 2>/dev/null
            done
            echo -e "${GREEN}所有数据库已删除${NC}"
            read -n1 -r -p "按任意键继续..."
            continue
        fi

        # 处理单个删除
        if [ ${#databases[@]} -gt 0 ] && [ "$choice" -gt 600 ]; then
            local index=$((choice - 601))
            if [ $index -ge 0 ] && [ $index -lt ${#databases[@]} ]; then
                local target_db="${databases[$index]}"
                echo -e "删除中 ${YELLOW}${target_db}${NC}..."
                mysql --socket="$socket" -u "$user" -p"$password" -e "DROP DATABASE IF EXISTS $target_db;" 2>/dev/null
                echo -e "${GREEN}数据库已删除${NC}"
                read -n1 -r -p "按任意键继续..."
                continue
            fi
        fi

        error_msg="无效选项，请重新输入"
    done
}

# 配置校验
# 配置校验和修复函数
validate_and_fix_config_paths() {
    local config_file="$1"
    local install_dir="$2"
    
    echo -e "${YELLOW}正在校验配置文件路径...${NC}"
    
    # 读取配置项并去除首尾空格和引号
    local current_datadir=$(grep '^datadir' "$config_file" | awk -F'= *' '{print $2}' | tr -d ' "' )
    local current_tmpdir=$(grep '^tmpdir' "$config_file" | awk -F'= *' '{print $2}' | tr -d ' "' )
    local old_logbin=$(grep '^log-bin' "$config_file" | awk -F'= *' '{print $2}' | tr -d ' "' )
    local current_logerror=$(grep '^log-error' "$config_file" | awk -F'= *' '{print $2}' | tr -d ' "' )

    # 生成期望路径
    local expected_datadir="$install_dir/data"
    local expected_tmpdir="$install_dir/tmp" 
    local expected_logbin="$install_dir/logs/binlog/mysql-bin"
    local expected_logerror="$install_dir/logs/error/mysql-error.log"

    # 路径比对
    if [ "$current_datadir" != "$expected_datadir" ] || \
       [ "$current_tmpdir" != "$expected_tmpdir" ] || \
       [ "$old_logbin" != "$expected_logbin" ] || \
       [ "$current_logerror" != "$expected_logerror" ]; then

        echo -e "${RED}检测到配置文件路径与实际安装目录不匹配！${NC}"
        echo -e "当前安装目录：${YELLOW}$install_dir${NC}"
        echo -e "配置文件中的路径："
        echo -e " - 数据目录: ${current_datadir:-未设置}"
        echo -e " - 临时目录: ${current_tmpdir:-未设置}"
        echo -e " - 二进制日志: ${old_logbin:-未设置}"
        echo -e " - 错误日志: ${current_logerror:-未设置}"
        
        read -p "是否自动修正为当前安装目录路径？[Y/n]: " fix_confirm
        fix_confirm=${fix_confirm:-Y}

        if [[ "$fix_confirm" =~ [Yy] ]]; then
            # 备份原配置文件
            local backup_cnf="${config_file}.bak_$(date +%s)"
            cp "$config_file" "$backup_cnf"
            
            # 更新配置文件路径
            sed -i "s|^datadir\s*=.*|datadir = \"$expected_datadir\"|" "$config_file"
            sed -i "s|^tmpdir\s*=.*|tmpdir = \"$expected_tmpdir\"|" "$config_file"
            sed -i "s|^log-bin\s*=.*|log-bin = \"$expected_logbin\"|" "$config_file"
            sed -i "s|^log-error\s*=.*|log-error = \"$expected_logerror\"|" "$config_file"
            
            # 处理二进制日志索引文件
            if [ -n "$old_logbin" ] && [ "$old_logbin" != "$expected_logbin" ]; then
                local old_index="${old_logbin}.index"
                local new_index="${expected_logbin}.index"
                
                if [ -f "$old_index" ]; then
                    echo -e "${YELLOW}更新二进制日志索引文件...${NC}"
                    # 替换索引文件路径并保留权限
                    sudo sed "s|^$old_logbin|$expected_logbin|g" "$old_index" | sudo tee "$new_index" > /dev/null
                    # 清理旧索引文件
                    sudo rm -f "$old_index"
                    echo -e "${GREEN}已更新日志索引文件: $new_index${NC}"
                fi
            fi

            # 创建目录结构
            echo -e "${YELLOW}创建必要目录结构...${NC}"
            sudo mkdir -p "$expected_datadir" "$expected_tmpdir" \
                "$(dirname "$expected_logbin")" \
                "$(dirname "$expected_logerror")"
            
            # 设置目录权限
            if [ -d "$expected_datadir" ]; then
                sudo chown -R $(whoami):$(whoami) "$expected_datadir"
            fi
            
            echo -e "${GREEN}配置文件已修正，原配置备份至: ${backup_cnf}${NC}"
        else
            echo -e "${YELLOW}已跳过路径修正，请确保配置有效性！${NC}"
        fi
        read -n 1 -s -r -p "按任意键继续..."
    else
        echo -e "${GREEN}配置文件路径校验通过${NC}"
    fi
}

# 显示主菜单
show_menu() {
    check_database_status
    show_status
    if [ "$CURRENT_STATUS" = "未运行" ]; then
        echo "1. 启动数据库"
    else
        echo "1. 停止数据库"
    fi
    echo "2. 修改root密码"
    echo "3. 切换外网访问"
    echo "4. 修改端口号"
    echo "5. 导入SQL数据库"
    echo "6. 删除数据库"
    echo "7. 重新初始化实例"
    echo "8. 退出"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
}

# 处理用户输入
handle_input() {
    while true; do
        read -p "请选择操作 [1-8]: " choice
        case $choice in
            1)
                if [ "$CURRENT_STATUS" = "未运行" ]; then
                    start_database
                else
                    stop_database
                fi
                ;;
            2) set_root_password ;;
            3) toggle_remote_access ;;
            4) change_port ;;
            5) import_sql_data ;;
            6) delete_database ;;
            7) reinitialize_instance ;;
            8) exit 0 ;;
            *) echo -e "${RED}无效的选项，请重新输入。${NC}" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
        show_menu
    done
}

# 主函数
main() {
    check_sudo
    install_mariadb_server
    INSTALL_DIR=$DEFAULT_INSTALL_DIR
    local password_file="$INSTALL_DIR/root.password"

    # 读取密码
    [ -f "$password_file" ] && MYSQL_PASSWORD=$(cat "$password_file") || MYSQL_PASSWORD=""

    if [ -d "$DEFAULT_INSTALL_DIR/data" ] && [ -f "$DEFAULT_INSTALL_DIR/my.cnf" ]; then
        echo -e "${GREEN}检测到已存在的数据库实例${NC}"
        MY_CNF="$DEFAULT_INSTALL_DIR/my.cnf"
        PORT=$(grep '^port' "$MY_CNF" | awk -F'=' '{print $2}' | tr -d ' ')
        
        # 调用校验函数
        validate_and_fix_config_paths "$MY_CNF" "$INSTALL_DIR"
        
        CURRENT_STATUS="未运行"
        show_menu
        handle_input
    else
        echo -e "${YELLOW}脚本目录下未找到数据库实例，开始新实例配置...${NC}"
        database_init
        show_menu
        handle_input
    fi
}

# 脚本入口
main