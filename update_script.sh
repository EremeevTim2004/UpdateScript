#!/bin/bash

set -euo pipefail
trap 'echo -e "${RED}Прервано!${NC}"; exit 130' SIGINT

# Config
LOG_FILE="/var/log/universal_updater.log"
YES_MODE=false
CLEAN_OLD_KERNELS=false

# Terminal color
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Определение дистрибутива
detect_distro() {
    #Для BSD-систем
    if uname | grep -iq "BSD"; then
        case $(uname -s) in
	    "FreeBSD") echo "freebsd" ;;
	    "OpenBSD") echo "openbsd" ;;
	    "NetBSD") echo "netbsd" ;;
	    *) echo "bsd" ;;
        esac
    else
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "$ID"
        elif [ -f /etc/debian_version ]; then
            echo "debian"
        elif [ -f /etc/redhat-release ]; then
            echo "rhel"
        elif [ -f /etc/arch-release ]; then
            echo "arch"
        elif [ -f /etc/SuSE-release ]; then
            echo "suse"
        else
            echo "unknown"
        fi
    fi
}

# Инициализация переменных
SYSTEM=$(detect_distro)
UPDATE_CMD=""
UPGRADE_CMD=""
AUTOREMOVE_CMD=""
AUTOCLEAN_CMD=""
KERNEL_CLEAN_CMD=""

# Настройка команд для дистрибутивов
case $SYSTEM in
    # Debian-based
    "debian" | "ubuntu" | "linuxmint" | "pop" | "kali")
        UPDATE_CMD="apt update"
        UPGRADE_CMD="apt upgrade -y"
        AUTOREMOVE_CMD="apt autoremove -y"
        AUTOCLEAN_CMD="apt autoclean"
        KERNEL_CLEAN_CMD="apt purge -y $(dpkg -l | awk '/linux-image-[0-9]/{print $2}' | grep -v $(uname -r))"
        ;;

    # RHEL-based
    "rhel" | "centos" | "fedora" | "rocky" | "almalinux")
        if command -v dnf &> /dev/null; then
            UPDATE_CMD="dnf check-update"
            UPGRADE_CMD="dnf upgrade -y"
            AUTOREMOVE_CMD="dnf autoremove -y"
            AUTOCLEAN_CMD="dnf clean all"
            KERNEL_CLEAN_CMD="package-cleanup --oldkernels --count=1 -y"
        else
            UPDATE_CMD="yum check-update"
            UPGRADE_CMD="yum update -y"
            AUTOREMOVE_CMD="yum autoremove -y"
            AUTOCLEAN_CMD="yum clean all"
        fi
        ;;

    # Arch-based
    "arch" | "manjaro")
        UPDATE_CMD="pacman -Sy"
        UPGRADE_CMD="pacman -Syu --noconfirm"
        AUTOREMOVE_CMD="pacman -Rns $(pacman -Qtdq) --noconfirm 2>/dev/null"
        AUTOCLEAN_CMD="pacman -Sc --noconfirm"
        ;;

	"alpine")
    	UPDATE_CMD="apk update"
   		UPGRADE_CMD="apk upgrade"
    	AUTOREMOVE_CMD="apk del --purge"
    	AUTOCLEAN_CMD="apk cache clean"
    	;;

    # SUSE-based
    "opensuse" | "sles")
        UPDATE_CMD="zypper refresh"
        UPGRADE_CMD="zypper update -y"
        AUTOREMOVE_CMD="zypper packages --unneeded | awk '{print \$5}' | xargs -r zypper remove -y"
        AUTOCLEAN_CMD="zypper clean"
        KERNEL_CLEAN_CMD="zypper remove-old-kernels --keep 1"
        ;;

    # BSD-based
    "freebsd")
        UPDATE_CMD="pkg update"
        UPGRADE_CMD="pkg upgrade -y"
        AUTOREMOVE_CMD="pkg autoremove -y"
        AUTOCLEAN_CMD="pkg clean -y"
        ;;

    "openbsd")
        UPDATE_CMD="pkg_add -u"
        UPGRADE_CMD="pkg_add -u"
        AUTOREMOVE_CMD="pkg_delete -a"
        AUTOCLEAN_CMD="rm -rf /var/cache/pkg/*"
    ;;

    "netbsd")
        UPDATE_CMD="pkgin update"
        UPGRADE_CMD="pkgin full-upgrade -y"
        AUTOREMOVE_CMD="pkgin autoremove -y"
        AUTOCLEAN_CMD="pkgin clean"
        ;;

    # Неподдерживаемые системы
    *)
        echo -e "${RED}Неподдерживаемый дистрибутив: $DISTRO${NC}"
        exit 1
        ;;
esac

show_help() {
    echo "Использование: $0 [ПАРАМЕТРЫ]"
    echo "Параметры:"
    echo "  -y, --yes          Автоматическое подтверждение"
    echo "  -k, --clean-kernels Удаление старых ядер"
    echo "  -l, --log <путь>   Указать лог-файл"
    echo "  --help             Показать справку"
}

# Обработка аргументов
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -y|--yes) YES_MODE=true ;;
        -k|--clean-kernels) CLEAN_OLD_KERNELS=true ;;
        -l|--log) LOG_FILE="$2"; shift ;;
        --help) show_help; exit 0 ;;
        *) echo -e "${RED}Неизвестный параметр: $1${NC}"; exit 1 ;;
    esac
    shift
done

# Функция выполнения команд
run_command() {
    local cmd="$1"
    local desc="$2"
    local log_cmd=""
    local full_cmd=""

    echo -e "${BLUE}▶ $desc...${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] START: $desc" >> "$LOG_FILE"

   if $YES_MODE; then
        sudo bash -c "$cmd" >> "$LOG_FILE" 2>&1
    else
        sudo bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"
    fi

    # Формируем команду безопасно
    full_cmd=$(printf "%s %s" "$cmd" "$log_cmd")

    sudo bash -c "$full_cmd"

    local status=$?

    if [ $status -eq 0 ] || [[ $SYSTEM =~ (rhel|centos) && $status -eq 100 ]]; then
        echo -e "${GREEN}✔ Успешно: $desc${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $desc" >> "$LOG_FILE"
        return 0
    else
        echo -e "${RED}✖ Ошибка ($status): $desc (команда: $cmd)${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR ($status): $desc (команда: $cmd)" >> "$LOG_FILE"
        exit $status
    fi
}

check_disk_space() {
    local required=100  # Минимум 100MB свободного места
    local avail=$(df -m / | awk 'NR==2 {print $4}')
    
    if [ $avail -lt $required ]; then
        echo -e "${RED}Недостаточно свободного места!${NC}"
        exit 1
    fi
}

# Проверка прав
check_sudo() {
    case $SYSTEM in
        "openbsd")
            if ! command -v doas >/dev/null; then
                echo -e "${RED}Требуется doas для OpenBSD!${NC}"
                exit 1
            fi
            SUDO="doas"
            ;;
        *)
            SUDO="sudo"
            if [[ $EUID -ne 0 ]]; then
                if ! $SUDO -n true 2>/dev/null; then
                    $SUDO -v || exit 1
                fi
            fi
            ;;
    esac
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}Запрос прав sudo...${NC}"
        if ! sudo -n true 2>/dev/null; then
            sudo -v
            if [ $? -ne 0 ]; then
                echo -e "${RED}Ошибка аутентификации. Выход.${NC}"
                exit 1
            fi
        fi
    fi
}

check_log_file() {
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -w "$log_dir" ]; then
        echo -e "${RED}Нет прав на запись в $log_dir${NC}"
        exit 1
    fi
    touch "$LOG_FILE"
}

main() {
    check_sudo
    echo -e "${BLUE}Обнаружен дистрибутив: $SYSTEM${NC}"

    # Обновление репозиториев
    run_command "$UPDATE_CMD" "Обновление списков пакетов"

    # Проверка обновлений
    case $SYSTEM in
        "debian" | "ubuntu" | "linuxmint" | "pop")
            updates=$(apt list --upgradable 2>/dev/null | wc -l)
            ;;
        "rhel" | "centos" | "fedora" | "rocky" | "almalinux")
            updates=$(dnf check-update -q | wc -l)
            ;;
        "freebsd")
            updates=$(pkg upgrade -n | grep -c "Number of packages to be upgraded")
            ;;
        "openbsd")
            updates=$(pkg_add -un | grep -c "install")
            ;;
		"arch" | "manjaro")
            updates=$(pacman -Qu | wc -l)
            ;;
    	"opensuse" | "sles")
    		updates=$(zypper --no-refresh list-updates | grep -c '|')
    		;;
        *)
            updates=1 # Пропускаем проверку для других дистрибутивов
            ;;
    esac

    if [ $updates -le 1 ]; then
        echo -e "${GREEN}Нет доступных обновлений.${NC}"
    else
        run_command "$UPGRADE_CMD" "Обновление пакетов"
        run_command "$AUTOREMOVE_CMD" "Очистка зависимостей"
    fi

    run_command "$AUTOCLEAN_CMD" "Очистка кеша"

    # Очистка старых ядер
    if $CLEAN_OLD_KERNELS; then
        case $SYSTEM in
            "debian" | "ubuntu" | "rhel" | "centos" | "fedora")
                run_command "$KERNEL_CLEAN_CMD" "Удаление старых ядер"
                ;;
            *)
                echo -e "${YELLOW}Очистка ядер не поддерживается для $SYSTEM${NC}"
                ;;
        esac
    fi

    echo -e "${GREEN}\nВсе операции завершены! Лог: $LOG_FILE${NC}"
}

main
