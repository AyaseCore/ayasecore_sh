#!/bin/bash

# 安装包解压
#sudo apt update && sudo apt install -y unzip && unzip -o server-core.zip && chmod +x AyaseCore.sh && sudo ./AyaseCore.sh

# 全局变量声明
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BIM_COMMAND="/usr/bin/ayasecore"
if [ "$0" == "$BIM_COMMAND" ]; then
    if [ -L "$0" ]; then
        SCRIPT_DIR=$(readlink -f "$0")
        SCRIPT_DIR=$(dirname "$SCRIPT_DIR")
    fi
fi
DEFAULT_INSTALL_DIR="$SCRIPT_DIR"
INSTALL_DIR=""
MYSQL_INSTALL_DIR=""
CORE_INSTALL_DIR=""
PORT="3333"
MYSQL_USER="root"
MYSQL_PASSWORD=""
MY_CNF=""
ALLOW_REMOTE=false
MYSQL_CURRENT_STATUS="未运行"
ALL_SERVERS_STATUS="未运行"
AUTH_CURRENT_STATUS="未运行"
WORLD_CURRENT_STATUS="未运行"
NEED_TO_COPY=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 初始化时检查并启用swap文件
init_swap() {
    local swap_file="$INSTALL_DIR/swapfile"
    if [ -f "$swap_file" ]; then
        if ! swapon --show | grep -q "$swap_file"; then
            echo -e "${YELLOW}检测到未启用的swap文件，正在启用...${NC}"
            sudo swapon "$swap_file" && echo -e "${GREEN}已启用swap文件${NC}"
        fi
    fi
}

# SWAP管理函数
manage_swap() {
    clear
    show_swap_status
    
    # 检查本脚本的swap文件
    local swap_file="$INSTALL_DIR/swapfile"
    if [ -f "$swap_file" ]; then
        if swapon --show | grep -q "$swap_file"; then
            echo -e "${GREEN}本脚本的swap文件已启用: $swap_file${NC}"
        else
            echo -e "${YELLOW}本脚本的swap文件未启用: $swap_file${NC}"
        fi
    fi

    echo -e "${BLUE}════════════ SWAP设置 ════════════${NC}"
    echo "1. 设置SWAP大小"
    echo "2. 设置swappiness(SWAP优先级)"
    echo "3. 禁用并删除本脚本的SWAP"
    echo "4. 返回主菜单"
    echo -e "${BLUE}═════════════════════════════════${NC}"
    
    read -p "请选择操作 [1-4]: " choice
    case $choice in
        1) set_swap_size ;;
        2) set_swappiness ;;
        3) disable_swap ;;
        4) return ;;
        *) echo -e "${RED}无效选项，请重新输入${NC}" ;;
    esac
    read -n 1 -s -r -p "按任意键继续..."
    manage_swap
}

# 显示SWAP状态
show_swap_status() {
    show_memoery_status
    echo -e "${YELLOW}当前swappiness值:${NC}"
    cat /proc/sys/vm/swappiness
    
    echo -e "${YELLOW}当前SWAP设备:${NC}"
    swapon --show
}

show_memoery_status() {
    echo -e "${YELLOW}当前内存使用情况:${NC}"
    free -h | awk 'NR==2 {print "总内存: " $2, "已用内存: " $3, "空闲内存: " $4, "缓冲: " $6, "缓存: " $7}'
    
    echo -e "${YELLOW}当前SWAP使用情况:${NC}"
    free -h | awk 'NR==3 {print "总SWAP: " $2, "已用SWAP: " $3, "空闲SWAP: " $4}'
}

set_terminal_title() {
    echo -ne "\033]0;AyaseCore 管理界面 -- script by ayase \007"
}

# 设置SWAP大小
set_swap_size() {
    check_sudo
    echo -e "${YELLOW}设置SWAP大小${NC}"
    
    local swap_file="$INSTALL_DIR/swapfile"
    local mem_total=$(get_memory_size)
    local swap_recommend=$((mem_total * 2))
    
    echo -e "${BLUE}当前内存: ${mem_total}MB${NC}"
    echo -e "${BLUE}推荐SWAP大小: ${swap_recommend}MB (内存的2倍)${NC}"
    
    read -p "请输入SWAP大小(MB): " swap_size
    if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 请输入有效的数字${NC}"
        return 1
    fi
    
    # 检查磁盘空间
    local avail_space=$(df -m "$INSTALL_DIR" | awk 'NR==2 {print $4}')
    if [ "$avail_space" -lt "$swap_size" ]; then
        echo -e "${RED}错误: 磁盘空间不足!${NC}"
        echo -e "${YELLOW}可用空间: ${avail_space}MB, 需要空间: ${swap_size}MB${NC}"
        return 1
    fi
    
    read -p "确认在 $swap_file 创建 ${swap_size}MB swap文件? [y/N]: " confirm
    [[ "$confirm" =~ [yY] ]] || return
    
    # 禁用现有swap
    if [ -f "$swap_file" ]; then
        if swapon --show | grep -q "$swap_file"; then
            sudo swapoff "$swap_file"
        fi
        sudo rm -f "$swap_file"
    fi
    
    # 创建swap文件
    echo -e "${YELLOW}正在创建swap文件...${NC}"
    sudo dd if=/dev/zero of="$swap_file" bs=1M count=$swap_size status=progress
    sudo chmod 600 "$swap_file"
    
    # 设置swap
    echo -e "${YELLOW}设置swap文件...${NC}"
    sudo mkswap "$swap_file"
    sudo swapon "$swap_file"
    
    echo -e "${GREEN}SWAP设置完成!${NC}"
}

# 设置swappiness值
set_swappiness() {
    check_sudo
    echo -e "${YELLOW}设置swappiness值${NC}"
    
    echo -e "${BLUE}当前swappiness值: $(cat /proc/sys/vm/swappiness)${NC}"
    echo -e "${BLUE}该值控制系统内存不足时，使用Swap的优先级。${NC}"
    echo -e "${BLUE}值越高，系统内存不足时，越倾向于使用Swap。${NC}"

    echo -e "${BLUE}建议值: 10-60 (默认60)${NC}"
    echo -e "${BLUE}对于数据库服务器建议10-30${NC}"
    
    read -p "请输入新的swappiness值(0-100): " swappiness
    if ! [[ "$swappiness" =~ ^[0-9]+$ ]] || [ "$swappiness" -gt 100 ]; then
        echo -e "${RED}错误: 请输入0-100之间的数字${NC}"
        return 1
    fi
    
    # 临时设置
    echo -e "${YELLOW}临时设置swappiness值...${NC}"
    sudo sysctl vm.swappiness=$swappiness
    
    # 持久化设置
    echo -e "${YELLOW}持久化swappiness设置...${NC}"
    if grep -q "vm.swappiness" /etc/sysctl.conf; then
        sudo sed -i "s/vm.swappiness = .*/vm.swappiness = $swappiness/" /etc/sysctl.conf
    else
        echo "vm.swappiness = $swappiness" | sudo tee -a /etc/sysctl.conf
    fi
    
    echo -e "${GREEN}swappiness设置完成!${NC}"
}

# 禁用SWAP
disable_swap() {
    check_sudo
    echo -e "${YELLOW}禁用并删除本脚本的SWAP${NC}"
    
    local swap_file="$INSTALL_DIR/swapfile"
    
    if [ ! -f "$swap_file" ]; then
        echo -e "${YELLOW}未找到本脚本的swap文件${NC}"
        return
    fi

    echo -e "${RED}警告: 禁用SWAP可能会影响系统性能${NC}"
    read -p "确认要禁用并删除本脚本的SWAP吗? [y/N]: " confirm
    [[ "$confirm" =~ [yY] ]] || return
    
    # 禁用swap
    if swapon --show | grep -q "$swap_file"; then
        sudo swapoff "$swap_file"
    fi
    
    # 删除swap文件
    sudo rm -f "$swap_file"
    echo -e "${GREEN}已禁用并删除本脚本的SWAP${NC}"
}

# 获取内存大小(MB)
get_memory_size() {
    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo $((mem_total_kb / 1024))
}



# 检查sudo权限
check_sudo() {
    if ! sudo -v &>/dev/null; then
        echo -e "${RED}错误：当前用户没有sudo权限。${NC}"
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
        read -p "是否要安装mariadb-server？[Y/n]: " install_confirm
        install_confirm=${install_confirm:-Y}
        if [[ "$install_confirm" =~ [Yy] ]]; then
            sudo apt-get update && sudo apt-get install -y mariadb-server
            if [ $? -ne 0 ]; then
                echo -e "${RED}安装mariadb-server失败，请手动安装后重试${NC}"
                exit 1
            fi
        else
            echo -e "${YELLOW}请先安装mariadb-server或Mysql数据库后再运行本脚本${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}mariadb-server 已经安装。${NC}"
    fi
}


# 设置安装目录
set_install_dir() {
    local confirmed="n"
    while [ "$confirmed" != "y" ]; do
        read -p "请输入AyaseCore安装目录（默认为: $DEFAULT_INSTALL_DIR）: " user_input
        user_input=${user_input:-$DEFAULT_INSTALL_DIR}
        INSTALL_DIR=$(realpath -m "$user_input")
        
        MYSQL_INSTALL_DIR="$INSTALL_DIR/mysql"
        CORE_INSTALL_DIR="$INSTALL_DIR/core"
        MY_CNF="$MYSQL_INSTALL_DIR/my.cnf"
        
        echo -e "安装目录设置为：${GREEN}$INSTALL_DIR${NC}"
        echo -e "核心(core)目录设置为：${GREEN}$INSTALL_DIR${YELLOW}/core${NC}"
        echo -e "数据库(mysql)目录设置为：${GREEN}$INSTALL_DIR${YELLOW}/mysql${NC}"
        
        read -p "确认路径是否正确 (y/N): " confirmed
        if [ "$confirmed" == "n" ]; then
            echo "请重新输入安装目录。"
        fi
    done
}


# 检查核心服务是否安装
check_core_installed() {
    if [ -f "$CORE_INSTALL_DIR/authserver" ] && [ -f "$CORE_INSTALL_DIR/worldserver" ]; then
        return 0
    fi
    return 1
}

# 初始化核心服务
init_core() {
    echo -e "${YELLOW}正在初始化核心服务...${NC}"
    
    # 检查core.zip是否存在
    if [ ! -f "$SCRIPT_DIR/core.zip" ]; then
        echo -e "${RED}错误：找不到core.zip文件${NC}"
        return 1
    fi
    
    # 检查core_data.zip是否存在
    if [ ! -f "$SCRIPT_DIR/core_data.zip" ]; then
        echo -e "${RED}错误：找不到core_data.zip文件${NC}"
        return 1
    fi

    # 解压core.zip
    echo -e "${YELLOW}正在解压core.zip...${NC}"
    unzip -o "$SCRIPT_DIR/core.zip" -d "$INSTALL_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压core.zip失败${NC}"
        return 1
    fi
    
    # 解压core_data.zip
    echo -e "${YELLOW}正在解压core_data.zip...${NC}"
    unzip -o "$SCRIPT_DIR/core_data.zip" -d "$CORE_INSTALL_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压core_data.zip失败${NC}"
        return 1
    fi

    # 设置执行权限
    chmod +x "$CORE_INSTALL_DIR/authserver"
    chmod +x "$CORE_INSTALL_DIR/worldserver"
    
    echo -e "${GREEN}核心服务初始化完成${NC}"
    return 0
}

# 检查安装状态
check_installation() {
    local core_need_init=false
    local mysql_need_init=false
    
    # 检查核心服务
    if ! check_core_installed; then
        echo -e "${YELLOW}核心服务未安装${NC}"
        read -p "是否初始化核心服务？[Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ [Yy] ]]; then
            core_need_init=true
        else
            echo -e "${YELLOW}已跳过核心服务初始化${NC}"
            return 1
        fi
    fi
    
    # 检查数据库
    if [ ! -d "$MYSQL_INSTALL_DIR/data" ] || [ ! -f "$MYSQL_INSTALL_DIR/my.cnf" ]; then
        echo -e "${YELLOW}数据库未初始化${NC}"
        read -p "是否初始化数据库？[Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ [Yy] ]]; then
            mysql_need_init=true
        else
            echo -e "${YELLOW}已跳过数据库初始化${NC}"
            return 1
        fi
    fi
    
    # 如果需要初始化但安装目录未设置
    if { $core_need_init || $mysql_need_init; }; then
        set_install_dir
        if [ "$INSTALL_DIR" != "$DEFAULT_INSTALL_DIR" ]; then
            NEED_TO_COPY=true
        fi
    fi
    
    # 执行初始化
    if $core_need_init; then
        init_core || return 1
    fi
    
    if $mysql_need_init; then
        echo -e "${YELLOW}正在初始化数据库服务...${NC}"
        database_init || return 1
    fi
    
    # 如果需要复制文件
    if $NEED_TO_COPY; then
        echo -e "${YELLOW}正在复制必要文件到安装目录...${NC}"
        cp "$SCRIPT_DIR/AyaseCore.sh" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/core.zip" "$INSTALL_DIR/"
        [ -f "$SCRIPT_DIR/mysql_data.zip" ] && cp "$SCRIPT_DIR/mysql_data.zip" "$INSTALL_DIR/"
        [ -f "$SCRIPT_DIR/core_data.zip" ] && cp "$SCRIPT_DIR/core_data.zip" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/AyaseCore.sh"
        echo -e "${GREEN}文件复制完成${NC}"
    fi
    
    if { $core_need_init || $mysql_need_init; }; then
        read -p "是否建立命令'ayasecore'？创建后可在终端任意位置输入'ayasecore'来启动AyaseCore。[Y/n]: " link_confirm
        link_confirm=${link_confirm:-Y}
        if [[ "$link_confirm" =~ [Yy] ]]; then
            [ -L "$BIM_COMMAND" ] && sudo rm -f "$BIM_COMMAND"
            sudo ln -s "$INSTALL_DIR/AyaseCore.sh" "$BIM_COMMAND"
            echo -e "${GREEN}软链接创建成功${NC}"
        else
            echo -e "${YELLOW}已跳过软链接创建${NC}"
        fi
    fi
    return 0
}

# 检查数据库状态
check_database_status() {
    MYSQL_CURRENT_STATUS="未运行"
    if [ -f "$MYSQL_INSTALL_DIR/mysql.pid" ]; then
        local pid=$(cat "$MYSQL_INSTALL_DIR/mysql.pid")
        if ps -p "$pid" > /dev/null 2>&1; then
            MYSQL_CURRENT_STATUS="运行中（PID: $pid）"
            return 0
        fi
    fi
    return 1
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

    read -p "是否更新AyaseCore主程序authserver和worldserver配置文件的端口？[Y/n]: " update_confirm
    update_confirm=${update_confirm:-Y}
    if [[ "$update_confirm" =~ [Yy] ]]; then
        update_database_configs || return 1
    fi

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
    mkdir -p "$MYSQL_INSTALL_DIR"/{data,logs/binlog,tmp}
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}目录创建失败，请检查权限设置。${NC}"
        exit 1
    fi
}

# 生成配置文件
generate_my_cnf() {
    MY_CNF="$MYSQL_INSTALL_DIR/my.cnf"
    cat > "$MY_CNF" <<EOF
[mysqld]
bind-address    = 127.0.0.1
port            = $PORT
socket          = $MYSQL_INSTALL_DIR/mysql.sock
pid-file        = $MYSQL_INSTALL_DIR/mysql.pid
datadir         = $MYSQL_INSTALL_DIR/data
tmpdir          = $MYSQL_INSTALL_DIR/tmp
log-bin         = $MYSQL_INSTALL_DIR/logs/binlog/mysql-bin
log-error       = $MYSQL_INSTALL_DIR/logs/mysql-error.log

max_binlog_size = 512M
query_cache_size=186M
table_cache=1520
tmp_table_size=607M
thread_cache_size=38
default-storage-engine=MyISAM
read_buffer_size=64K
read_rnd_buffer_size=256K
sort_buffer_size=256K
innodb_flush_log_at_trx_commit=1
innodb_log_buffer_size=6M
innodb_buffer_pool_size=563M
innodb_log_file_size=113M
innodb_thread_concurrency=18
max_allowed_packet=500M
wait_timeout=288000
interactive_timeout = 288000
lower_case_table_names=1
character-set-server  = utf8mb4
collation-server      = utf8mb4_unicode_ci
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
    sudo "$install_db_path" --defaults-file="$MY_CNF" --user=$(whoami) --basedir="$basedir" --datadir="$MYSQL_INSTALL_DIR/data" 

    [ $? -ne 0 ] && {
        echo -e "${RED}数据库初始化失败，请检查日志文件。${NC}"
        exit 1
    }
    
    echo -e "${GREEN}数据库初始化成功。${NC}"
    
    # 询问是否解压数据库文件
    if [ -f "$SCRIPT_DIR/mysql_data.zip" ]; then
        read -p "是否要解压数据库文件到$MYSQL_INSTALL_DIR/data目录？[Y/n]: " unzip_confirm
        unzip_confirm=${unzip_confirm:-Y}
        if [[ "$unzip_confirm" =~ [Yy] ]]; then
            echo -e "${YELLOW}正在解压数据库文件...${NC}"
            if unzip -o "$SCRIPT_DIR/mysql_data.zip" -d "$MYSQL_INSTALL_DIR/data"; then
                echo -e "${GREEN}数据库文件解压成功${NC}"
            else
                echo -e "${RED}数据库文件解压失败${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}未找到数据库文件 $SCRIPT_DIR/mysql_data.zip${NC}"
    fi
    
}


# 启动数据库服务
start_database() {
    # 检查是否存在残留的PID文件
    if [ -f "$MYSQL_INSTALL_DIR/mysql.pid" ]; then
        local pid=$(cat "$MYSQL_INSTALL_DIR/mysql.pid")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "${YELLOW}数据库已经在运行（PID: $pid）。${NC}"
            MYSQL_CURRENT_STATUS="运行中（PID: $pid）"
            return 1
        else
            echo -e "${YELLOW}发现残留的PID文件，但进程未运行，清理中...${NC}"
            rm -f "$MYSQL_INSTALL_DIR/mysql.pid"
            rm -f "$MYSQL_INSTALL_DIR/mysql.sock"
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
    if mysql_cmd="sudo mysql --socket=$MYSQL_INSTALL_DIR/mysql.sock -u root -p"$MYSQL_PASSWORD""; then
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
    check_database_status || {
        echo -e "${RED}数据库未运行，无法设置密码。${NC}"
        return 1
    }
    local old_password new_password
    local password_file="$MYSQL_INSTALL_DIR/root.password"
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
        sudo mysql --socket="$MYSQL_INSTALL_DIR/mysql.sock" "${mysql_options[@]}" -u root -p"$old_password" \
            -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_password';" &>/dev/null
    else
        sudo mysql --socket="$MYSQL_INSTALL_DIR/mysql.sock" -u root \
            -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_password';" &>/dev/null
    fi

    if [ $? -eq 0 ]; then
        [ $has_mysql_secret -eq 1 ] && rm -f "$mysql_secret_path"
        echo "$new_password" > "$password_file"
        MYSQL_PASSWORD=$new_password
        echo -e "${GREEN}密码设置成功！${NC}"
        read -p "是否更新AyaseCore主程序authserver和worldserver配置文件的密码？[Y/n]: " update_confirm
        update_confirm=${update_confirm:-Y}
        if [[ "$update_confirm" =~ [Yy] ]]; then
            update_database_configs || return 1
        fi
    else
        echo -e "${RED}密码设置失败，可能原因：${NC}"
        [ $has_mysql_secret -eq 1 ] && \
        echo -e "0. MySQL临时密码已过期（使用来自 $mysql_secret_path 的旧密码: $old_password）。"
        echo -e "1. 旧密码不正确（当前使用旧密码文件: $password_file）"
        echo -e "2. 数据库服务未运行"
        echo -e "3. 缺少sudo权限"
    fi
}

# 更新数据库配置文件
update_database_configs() {
    local auth_conf="$CORE_INSTALL_DIR/config/authserver.conf"
    local world_conf="$CORE_INSTALL_DIR/config/worldserver.conf"
    if [ -f "$auth_conf" ]; then
        sed -i -r "s/^(LoginDatabaseInfo\s+=\s+)\"127\.0\.0\.1;[0-9]+;root;[^;]*;auth\"/\1\"127.0.0.1;$PORT;root;$MYSQL_PASSWORD;auth\"/" "$auth_conf"
        echo -e "${GREEN}AuthServer配置文件已更新。${NC}"
    fi

    if [ -f "$world_conf" ]; then
        sed -i -r "s/^(LoginDatabaseInfo\s+=\s+)\"127\.0\.0\.1;[0-9]+;root;[^;]*;auth\"/\1\"127.0.0.1;$PORT;root;$MYSQL_PASSWORD;auth\"/" "$world_conf"
        sed -i -r "s/^(WorldDatabaseInfo\s+=\s+)\"127\.0\.0\.1;[0-9]+;root;[^;]*;world\"/\1\"127.0.0.1;$PORT;root;$MYSQL_PASSWORD;world\"/" "$world_conf"
        sed -i -r "s/^(CharacterDatabaseInfo\s+=\s+)\"127\.0\.0\.1;[0-9]+;root;[^;]*;characters\"/\1\"127.0.0.1;$PORT;root;$MYSQL_PASSWORD;characters\"/" "$world_conf"
        echo -e "${GREEN}WorldServer配置文件已更新。${NC}"
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
    create_directories
    get_port
    generate_my_cnf
    initialize_database
    #start_database
}

# 停止数据库服务
stop_database() {
    if [ ! -f "$MYSQL_INSTALL_DIR/mysql.pid" ]; then
        echo -e "${YELLOW}数据库似乎没有在运行。${NC}"
        MYSQL_CURRENT_STATUS="未运行"
        return
    fi

    local pid=$(cat "$MYSQL_INSTALL_DIR/mysql.pid")
    echo -e "${YELLOW}正在停止数据库...${NC}"
    local mysqladmin_path
    mysqladmin_path=$(get_related_command_path mysql mysqladmin) || exit 1

    sudo "$mysqladmin_path" --socket="$MYSQL_INSTALL_DIR/mysql.sock" -u root -p"$MYSQL_PASSWORD" shutdown

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
        MYSQL_CURRENT_STATUS="未运行"
        # 清理残留文件
        rm -f "$MYSQL_INSTALL_DIR/mysql.pid"
        rm -f "$MYSQL_INSTALL_DIR/mysql.sock"
        echo -e "${GREEN}数据库已停止。${NC}"
        return 0
    fi
}

# 显示状态信息
show_status() {
    clear
    local bind_status
    AUTH_CURRENT_STATUS="未运行"
    WORLD_CURRENT_STATUS="未运行"
    check_database_status

    # 检查AuthServer进程
    local auth_pid_file="$CORE_INSTALL_DIR/pid/authserver.pid"
    if [ -f "$auth_pid_file" ]; then
        local auth_pid=$(cat "$auth_pid_file")
        if ps -p "$auth_pid" > /dev/null 2>&1; then
            AUTH_CURRENT_STATUS="运行中 (PID: $auth_pid)"
        else
            rm -f "$auth_pid_file"
        fi
    fi

    # 检查WorldServer进程
    local world_pid_file="$CORE_INSTALL_DIR/pid/worldserver.pid"
    if [ -f "$world_pid_file" ]; then
        local world_pid=$(cat "$world_pid_file")
        if ps -p "$world_pid" > /dev/null 2>&1; then
            WORLD_CURRENT_STATUS="运行中 (PID: $world_pid)"
        else
            rm -f "$world_pid_file"
        fi
    fi

    # 检查外网访问配置
    if [ -f "$MY_CNF" ]; then
        local current_bind=$(grep -E '^bind-address[[:space:]]*=' "$MY_CNF" | awk -F'=' '{print $2}' | tr -d ' ')
        [ -z "$current_bind" ] && current_bind="127.0.0.1"
        bind_status=$([ "$current_bind" = "0.0.0.0" ] && echo "允许" || echo "禁止")
    else
        bind_status="未配置"
    fi
    
    echo -e "${GREEN}══════════════ 服务器状态 ══════════════${NC}"
    show_memoery_status
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "数据库状态：${YELLOW}$MYSQL_CURRENT_STATUS${NC}"
    echo -e "AuthServer状态：${YELLOW}$AUTH_CURRENT_STATUS${NC}"
    echo -e "WorldServer状态：${YELLOW}$WORLD_CURRENT_STATUS${NC}"
    
    echo -e "安装目录：${YELLOW}$INSTALL_DIR${NC}"
    echo -e "端口号：${YELLOW}$PORT${NC}"
    echo -e "root密码：${YELLOW}$MYSQL_PASSWORD${NC}"
    echo -e "Mysql远程访问：${YELLOW}$bind_status${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
}

# 重新初始化实例
reinitialize_instance() {
    echo -e "${YELLOW}════════════ 重新初始化实例 ════════════${NC}"
    read -p "这将删除所有数据！确认吗？[y/N]: " confirm
    if [[ $confirm =~ [yY] ]]; then
        stop_database
        # 强制删除所有实例文件
        rm -rf "${MYSQL_INSTALL_DIR:?}/"/*
        # 重新初始化
        create_directories
        get_port
        generate_my_cnf
        initialize_database
        #start_database
        echo -e "${GREEN}实例已重新初始化！${NC}"
    else
        echo -e "${YELLOW}已取消重新初始化。${NC}"
    fi
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

# 服务状态检查
service_is_running() {
    local pid_file="$1"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            rm -f "$pid_file"
        fi
    fi
    return 1
}

# 启动服务
start_service() {
    local service_name="$1"
    local pid_file="$2"
    local start_cmd="$3"
    
    if service_is_running "$pid_file"; then
        echo -e "${YELLOW}$service_name已经在运行${NC}"
        return 1
    fi

    echo -e "${YELLOW}正在启动$service_name...${NC}"
    eval "$start_cmd"
    echo $! > "$pid_file"
    echo -e "${GREEN}$service_name启动成功${NC}"
    return 0
}

# 停止服务
stop_service() {
    local service_name="$1"
    local pid_file="$2"
    
    if ! service_is_running "$pid_file"; then
        echo -e "${YELLOW}$service_name未在运行${NC}"
        return 1
    fi

    local pid=$(cat "$pid_file")
    echo -e "${YELLOW}正在停止$service_name...${NC}"
    kill "$pid"
    
    # 等待3秒检查是否停止
    for i in {1..3}; do
        sleep 1
        if ! ps -p "$pid" > /dev/null 2>&1; then
            rm -f "$pid_file"
            echo -e "${GREEN}$service_name已停止${NC}"
            return 0
        fi
    done

    # 如果仍未停止，尝试强制终止
    if ps -p "$pid" > /dev/null 2>&1; then
        echo -e "${YELLOW}尝试强制终止$service_name...${NC}"
        kill -9 "$pid"
        sleep 1
    fi

    if ps -p "$pid" > /dev/null 2>&1; then
        echo -e "${RED}无法停止$service_name (PID: $pid)${NC}"
        return 1
    else
        rm -f "$pid_file"
        echo -e "${GREEN}$service_name已停止${NC}"
        return 0
    fi
}

# 启动AuthServer
start_auth_server() {
    check_database_status || {
        echo -e "${RED}数据库未运行，无法启动AuthServer${NC}"
        return 1
    }
    local pid_file="$CORE_INSTALL_DIR/pid/authserver.pid"
    local start_cmd="(cd \"$CORE_INSTALL_DIR\" && ./authserver &> /dev/null &)"
    if start_service "AuthServer" "$pid_file" "$start_cmd"; then
        AUTH_CURRENT_STATUS="运行中"
    fi
}

# 停止AuthServer
stop_auth_server() {
    local pid_file="$CORE_INSTALL_DIR/pid/authserver.pid"
    if stop_service "AuthServer" "$pid_file"; then
        AUTH_CURRENT_STATUS="未运行"
    fi
}

# 启动WorldServer
start_world_server() {
    check_database_status || {
        echo -e "${RED}数据库未运行，无法启动WorldServer${NC}"
        return 1
    }
    local free_memory=$(free -m | awk 'NR==2 {print $4}')
    local swap_free_memory=$(free -m | awk 'NR==3 {print $4}')

    local total_free_memory=$((free_memory + swap_free_memory))

    echo -e "${YELLOW}检测到可用内存: $total_free_memory M, 其中空闲内存: $free_memory M, 交换内存: $swap_free_memory M${NC}"

    local need_memory=2500 # 2.5G
    if [ "$total_free_memory" -lt "$need_memory" ]; then
        echo -e "${RED}可用内存小于2.5G！worldserver可能无法启动, 请设置swap或增加内存。${NC}"
        return 1
    fi
    local pid_file="$CORE_INSTALL_DIR/pid/worldserver.pid"
    local start_cmd="(cd \"$CORE_INSTALL_DIR\" && ./worldserver &> /dev/null &)"
    if start_service "WorldServer" "$pid_file" "$start_cmd"; then
        WORLD_CURRENT_STATUS="运行中"
    fi
}

# 停止WorldServer
stop_world_server() {
    local pid_file="$CORE_INSTALL_DIR/pid/worldserver.pid"
    if stop_service "WorldServer" "$pid_file"; then
        WORLD_CURRENT_STATUS="未运行"
    fi
}

# 修改realmlist远程地址
modify_realmlist_address() {
    # 检查数据库状态
    check_database_status || {
        echo -e "${RED}数据库未运行，无法修改realmlist${NC}"
        return 1
    }

    # 查询realmlist表
    local query="SELECT id, name, address FROM auth.realmlist ORDER BY id"
    local result=$(sudo mysql --socket="$MYSQL_INSTALL_DIR/mysql.sock" -u root -p"$MYSQL_PASSWORD" -e "$query" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}查询realmlist失败，请检查数据库连接${NC}"
        return 1
    fi
    clear
    # 显示服务器列表
    echo -e "${GREEN}══════════ Realmlist服务器列表 ══════════${NC}"
    echo "$result" | awk 'NR==1 {printf "%-5s %-20s %-15s\n", $1, $2, $3; next} 
                          {printf "%-5s %-20s %-15s\n", $1, $2, $3}'
    echo -e "${GREEN}════════════════════════════════════════${NC}"

    # 获取最大ID
    local max_id=$(echo "$result" | awk 'NR>1 {print $1}' | sort -nr | head -1)
    local back_option=$((max_id + 1))

    # 获取用户选择
    while true; do
        read -p "请输入要修改的服务器ID(输入$back_option返回): " choice
        if [ "$choice" -eq "$back_option" ]; then
            return
        fi

        # 验证选择
        if ! echo "$result" | awk '{print $1}' | grep -q "^$choice$"; then
            echo -e "${RED}无效的服务器ID，请重新输入${NC}"
            continue
        fi

        # 获取当前地址
        local current_address=$(echo "$result" | awk -v id="$choice" '$1==id {print $3}')
        echo -e "当前服务器地址: ${YELLOW}$current_address${NC}"

        # 获取新地址
        read -p "请输入新的服务器地址: " new_address

        # 验证IP地址格式
        if ! [[ $new_address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo -e "${RED}无效的IP地址格式${NC}"
            continue
        fi

        # 确认更新
        read -p "确认将服务器ID $choice 的地址修改为 $new_address? [y/N]: " confirm
        if [[ "$confirm" =~ [yY] ]]; then
            local update_query="UPDATE auth.realmlist SET address='$new_address' WHERE id=$choice"
            sudo mysql --socket="$MYSQL_INSTALL_DIR/mysql.sock" -u root -p"$MYSQL_PASSWORD" -e "$update_query" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}服务器地址更新成功${NC}"
            else
                echo -e "${RED}服务器地址更新失败${NC}"
            fi
        else
            echo -e "${YELLOW}已取消修改${NC}"
        fi
        return
    done
}

# 检查和修复ICU库
check_and_fix_icu_libs() {
    local icu_libs=("libicudata.so.70" "libicui18n.so.70" "libicuuc.so.70")
    local script_lib_dir="$CORE_INSTALL_DIR/lib"
    local system_lib_dir="/usr/lib"

    for lib in "${icu_libs[@]}"; do
        local lib_path="$system_lib_dir/$lib"
        local real_lib_path="$script_lib_dir/${lib}.1"

        if [ -L "$lib_path" ]; then
            local link_target=$(realpath "$lib_path")
            if [ ! -f "$link_target" ]; then
                sudo rm -f "$lib_path"
                sudo ln -s "$real_lib_path" "$lib_path"
                echo -e "${YELLOW}修复ICU库链接: $lib_path -> $real_lib_path${NC}"
            fi
        elif [ ! -f "$lib_path" ]; then
            sudo ln -s "$real_lib_path" "$lib_path"
            echo -e "${YELLOW}创建ICU库链接: $lib_path -> $real_lib_path${NC}"
        else
            echo -e "${GREEN}ICU库检查通过: $lib_path${NC}"
        fi
    done
}

# 显示主菜单
show_menu() {
    check_database_status
    check_and_fix_icu_libs  
    show_status

    if [ "$MYSQL_CURRENT_STATUS" = "未运行" ]; then
        echo "1. 启动数据库"
    else
        echo "1. 停止数据库"
    fi
    if [ "$AUTH_CURRENT_STATUS" = "未运行" ]; then
        echo "2. 启动AuthServer"
    else
        echo "2. 停止AuthServer"
    fi
    if [ "$WORLD_CURRENT_STATUS" = "未运行" ]; then
        echo "3. 启动WorldServer"
    else
        echo "3. 停止WorldServer"
    fi
    echo "4. 修改root密码"
    echo "5. 切换Mysql远程访问"
    echo "6. 修改端口号"
    echo "7. 重新初始化实例" 
    echo "8. 修改realmlist远程地址"
    echo "9. 管理SWAP设置"
    echo "10. 退出"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
}

# 处理用户输入
handle_input() {
    while true; do
        read -p "请选择操作 [1-10]: " choice
        case $choice in
            1)
                if [ "$MYSQL_CURRENT_STATUS" = "未运行" ]; then
                    start_database
                else
                    stop_database
                fi
                ;;
            2)
                if [ "$AUTH_CURRENT_STATUS" = "未运行" ]; then
                    start_auth_server
                else
                    stop_auth_server
                fi
                ;;
            3)
                if [ "$WORLD_CURRENT_STATUS" = "未运行" ]; then
                    start_world_server
                else
                    stop_world_server
                fi
                ;;
            4) set_root_password ;;
            5) toggle_remote_access ;;
            6) change_port ;;
            7) reinitialize_instance ;;
            8) modify_realmlist_address ;;
            9) manage_swap ;;
            10) exit 0 ;;
            *) echo -e "${RED}无效的选项，请重新输入。${NC}" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
        show_menu
    done
}

# 检查软件包是否安装
check_package() {
    local package_name=$1
    if ! command -v "$package_name" &>/dev/null && ! dpkg -s "$package_name" &>/dev/null; then
        echo -e "${RED}错误：$package_name 未安装${NC}"
        read -p "是否要安装$package_name？[Y/n]: " install_confirm
        install_confirm=${install_confirm:-Y}
        if [[ "$install_confirm" =~ [Yy] ]]; then
            sudo apt-get update && sudo apt-get install -y "$package_name"
            if [ $? -ne 0 ]; then
                echo -e "${RED}安装$package_name失败，请手动安装后重试${NC}"
                exit 1
            fi
        else
            echo -e "${YELLOW}请先安装$package_name后再运行本脚本${NC}"
            exit 1
        fi
    fi
}

# 主函数
main() {
    check_sudo
    check_package unzip
    check_package python3
    install_mariadb_server
    set_terminal_title

    # 设置默认安装目录
    MYSQL_INSTALL_DIR="$DEFAULT_INSTALL_DIR/mysql"
    CORE_INSTALL_DIR="$DEFAULT_INSTALL_DIR/core"
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    MY_CNF="$MYSQL_INSTALL_DIR/my.cnf"
    local password_file="$MYSQL_INSTALL_DIR/root.password"
    init_swap

    # 读取密码
    [ -f "$password_file" ] && MYSQL_PASSWORD=$(cat "$password_file") || MYSQL_PASSWORD=""

    #读取端口号
    [ -f "$MY_CNF" ] && PORT=$(grep "^port" "$MY_CNF" | awk -F'=' '{print $2}' | tr -d '[:space:]')

    # 启动时更新主程序authserver和worldserver的配置文件
    update_database_configs

    # 检查并初始化服务
    if ! check_installation; then
        echo -e "${RED}服务初始化失败或已取消${NC}"
        exit 1
    fi

    show_menu
    handle_input
}

main