#!/bin/bash

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

REINSTALL_SUBSCRIPTION=false
INSTALL_WITH_PANEL=false

# Optional config vars (separate server)
CUSTOM_SUB_PREFIX=""
MARZBAN_LEGACY_LINK_ENABLED="false"
MARZBAN_LEGACY_SECRET_KEY=""
CADDY_AUTH_API_TOKEN=""
CF_ZERO_TRUST_CLIENT_ID=""
CF_ZERO_TRUST_CLIENT_SECRET=""

# ─────────────────────────────────────
# Helper: print a step header
# ─────────────────────────────────────
print_step() {
    local step_num="$1"
    local total="$2"
    local title="$3"
    echo
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD_CYAN}  [$step_num/$total] $title${RESET}"
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    echo
}

# ─────────────────────────────────────
# Helper: print a hint line (dim text)
# ─────────────────────────────────────
hint() {
    echo -e "${DIM}  💡 $1${RESET}"
}

# ─────────────────────────────────────
# Helper: print a summary row
# ─────────────────────────────────────
summary_row() {
    local label="$1"
    local value="$2"
    printf "  ${BOLD_CYAN}%-30s${RESET} %s\n" "$label" "$value"
}

# ─────────────────────────────────────
# Check for existing installation
# ─────────────────────────────────────
check_component() {
    if [ -f "/opt/remnawave/subscription/docker-compose.yml" ] && (cd /opt/remnawave/subscription && docker compose ps -q | grep -q "remnawave-subscription-page") || [ -f "/opt/remnawave/subscription/.env" ]; then
        info "$(get_string install_subscription_detected)"
        while true; do
            question "$(get_string install_subscription_reinstall)"
            REINSTALL="$REPLY"
            if [[ "$REINSTALL" == "y" || "$REINSTALL" == "Y" ]]; then
                warn "$(get_string install_subscription_stopping)"
                cd /opt/remnawave/subscription && docker compose down
                docker rmi remnawave/subscription-page:latest 2>/dev/null || true
                rm -f /opt/remnawave/subscription/.env
                rm -f /opt/remnawave/subscription/docker-compose.yml
                REINSTALL_SUBSCRIPTION=true
                break
            elif [[ "$REINSTALL" == "n" || "$REINSTALL" == "N" ]]; then
                info "$(get_string install_subscription_reinstall_denied)"
                read -n 1 -s -r -p "$(get_string install_subscription_press_key)"
                exit 0
            else
                warn "$(get_string install_subscription_please_enter_yn)"
            fi
        done
    else
        REINSTALL_SUBSCRIPTION=true
    fi
}

# ─────────────────────────────────────
# Install Docker if missing
# ─────────────────────────────────────
install_docker() {
    if ! command -v docker &> /dev/null; then
        info "$(get_string install_subscription_installing_docker)"
        curl -fsSL https://get.docker.com | sh
    fi
}

# ─────────────────────────────────────
# Install Caddy (reverse proxy)
# ─────────────────────────────────────
install_caddy_for_subscription() {
    if [ ! -f "/opt/remnawave/caddy/Caddyfile" ]; then
        if [ "$LANGUAGE" = "en" ]; then
            info "Installing Caddy reverse proxy..."
        else
            info "Установка Caddy reverse proxy..."
        fi

        mkdir -p /opt/remnawave/caddy
        cd /opt/remnawave/caddy

        if [ "$INSTALL_WITH_PANEL" = true ]; then
            # Same server: reverse proxy to localhost
            cat > Caddyfile << EOF
https://$SUB_DOMAIN {
    reverse_proxy * http://127.0.0.1:$SUB_PORT
}

:443 {
    tls internal
    respond 204
}
EOF

            cat > docker-compose.yml << 'COMPOSE'
services:
    caddy:
        image: caddy:2.9
        container_name: 'caddy'
        restart: always
        network_mode: host
        volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile
            - caddy-ssl-data:/data

volumes:
    caddy-ssl-data:
COMPOSE
        else
            # Separate server: reverse proxy to subscription container via Docker network
            cat > Caddyfile << EOF
https://$SUB_DOMAIN {
    reverse_proxy * http://remnawave-subscription-page:$SUB_PORT
}

:443 {
    tls internal
    respond 204
}
EOF

            cat > docker-compose.yml << 'COMPOSE'
services:
    caddy:
        image: caddy:2.9
        container_name: 'caddy'
        hostname: caddy
        restart: always
        ports:
            - '0.0.0.0:443:443'
            - '0.0.0.0:80:80'
        networks:
            - remnawave-network
        volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile
            - caddy-ssl-data:/data

networks:
    remnawave-network:
        name: remnawave-network
        driver: bridge
        external: true

volumes:
    caddy-ssl-data:
        driver: local
        external: false
        name: caddy-ssl-data
COMPOSE
        fi

        docker compose up -d
    else
        update_caddyfile_with_subscription
    fi
}

# ─────────────────────────────────────
# Update existing Caddyfile
# ─────────────────────────────────────
update_caddyfile_with_subscription() {
    local caddyfile_path="/opt/remnawave/caddy/Caddyfile"

    if [ ! -f "$caddyfile_path" ]; then
        return 1
    fi

    local proxy_target
    if [ "$INSTALL_WITH_PANEL" = true ]; then
        proxy_target="remnawave-subscription-page"
    else
        proxy_target="127.0.0.1"
    fi

    if grep -q "https://$SUB_DOMAIN" "$caddyfile_path" || grep -q "https://\$SUB_DOMAIN" "$caddyfile_path"; then
        sed -i "s|https://\$SUB_DOMAIN|https://$SUB_DOMAIN|g" "$caddyfile_path"
        sed -i "s|https://$SUB_DOMAIN {|https://$SUB_DOMAIN {|g" "$caddyfile_path"
        sed -i "s|http://remnawave-subscription-page:\$SUB_PORT|http://$proxy_target:$SUB_PORT|g" "$caddyfile_path"
        sed -i "s|http://remnawave-subscription-page:[0-9]*|http://$proxy_target:$SUB_PORT|g" "$caddyfile_path"
        sed -i "s|http://127.0.0.1:[0-9]*|http://$proxy_target:$SUB_PORT|g" "$caddyfile_path"
    else
        local temp_file=$(mktemp)
        awk -v sub_domain="$SUB_DOMAIN" -v sub_port="$SUB_PORT" -v proxy="$proxy_target" '
            /^:443 {/ {
                print "https://" sub_domain " {"
                print "    reverse_proxy * http://" proxy ":" sub_port
                print "}"
                print ""
            }
            { print }
        ' "$caddyfile_path" > "$temp_file"
        mv "$temp_file" "$caddyfile_path"
    fi

    cd /opt/remnawave/caddy
    docker compose restart 2>/dev/null || docker compose up -d
}

# ─────────────────────────────────────
# Core installation logic
# ─────────────────────────────────────
install_subscription() {
    if [ "$REINSTALL_SUBSCRIPTION" = true ]; then
        info "$(get_string install_subscription_installing)"
        mkdir -p /opt/remnawave/subscription
        cd /opt/remnawave/subscription

        cp "/opt/remnasetup/data/docker/subscription.env" .env

        if [ "$INSTALL_WITH_PANEL" = true ]; then
            cp "/opt/remnasetup/data/docker/subscription-compose.yml" docker-compose.yml
        else
            cp "/opt/remnasetup/data/docker/subscription-compose-separate.yml" docker-compose.yml
            info "$(get_string install_subscription_separate_info)"
        fi

        # Replace core env vars
        sed -i "s|\$SUB_PORT|$SUB_PORT|g" .env
        sed -i "s|\$PANEL_DOMAIN|$PANEL_DOMAIN|g" .env
        sed -i "s|\$API_TOKEN|$API_TOKEN|g" .env

        # Replace optional env vars
        sed -i "s|\$CUSTOM_SUB_PREFIX|$CUSTOM_SUB_PREFIX|g" .env
        sed -i "s|\$MARZBAN_LEGACY_LINK_ENABLED|$MARZBAN_LEGACY_LINK_ENABLED|g" .env
        sed -i "s|\$MARZBAN_LEGACY_SECRET_KEY|$MARZBAN_LEGACY_SECRET_KEY|g" .env
        sed -i "s|\$CADDY_AUTH_API_TOKEN|$CADDY_AUTH_API_TOKEN|g" .env
        sed -i "s|\$CF_ZERO_TRUST_CLIENT_ID|$CF_ZERO_TRUST_CLIENT_ID|g" .env
        sed -i "s|\$CF_ZERO_TRUST_CLIENT_SECRET|$CF_ZERO_TRUST_CLIENT_SECRET|g" .env

        sed -i "s|\$SUB_PORT|$SUB_PORT|g" docker-compose.yml

        if [ "$INSTALL_WITH_PANEL" = true ]; then
            cd /opt/remnawave
            if [ -f ".env" ]; then
                sed -i "s|SUB_DOMAIN=.*|SUB_DOMAIN=$SUB_DOMAIN|g" .env
                if grep -q "SUB_PUBLIC_DOMAIN" .env; then
                    sed -i "s|SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$SUB_DOMAIN|g" .env
                else
                    echo "SUB_PUBLIC_DOMAIN=$SUB_DOMAIN" >> .env
                fi
                info "$(get_string install_subscription_updating_panel_env)"
            fi

            update_caddyfile_with_subscription

            info "$(get_string install_subscription_restarting_panel)"
            docker compose down && docker compose up -d 2>/dev/null || true
        else
            install_caddy_for_subscription
        fi

        cd /opt/remnawave/subscription
        docker compose down && docker compose up -d
    fi
}

# ─────────────────────────────────────
# Check Docker availability
# ─────────────────────────────────────
check_docker() {
    if command -v docker >/dev/null 2>&1; then
        info "$(get_string install_subscription_docker_installed)"
        return 0
    else
        return 1
    fi
}

# ─────────────────────────────────────
# Check if panel is installed
# ─────────────────────────────────────
check_panel_installed() {
    if [ -f "/opt/remnawave/.env" ] || [ -f "/opt/remnawave/docker-compose.yml" ]; then
        return 0
    else
        return 1
    fi
}

# ─────────────────────────────────────
# Optional config (advanced settings)
# ─────────────────────────────────────
prompt_optional_config() {
    local total_steps="$1"
    local step_num="$2"

    if [ "$LANGUAGE" = "en" ]; then
        print_step "$step_num" "$total_steps" "Advanced Settings (optional)"
        echo -e "  ${YELLOW}These settings are optional. Press ${BOLD_GREEN}Enter${RESET}${YELLOW} to skip any of them.${RESET}"
        echo -e "  ${YELLOW}Most users can safely skip all of these.${RESET}"
    else
        print_step "$step_num" "$total_steps" "Дополнительные настройки (необязательно)"
        echo -e "  ${YELLOW}Эти настройки необязательны. Нажмите ${BOLD_GREEN}Enter${RESET}${YELLOW} чтобы пропустить.${RESET}"
        echo -e "  ${YELLOW}Большинство пользователей могут пропустить все эти пункты.${RESET}"
    fi
    echo

    # Custom sub prefix
    if [ "$LANGUAGE" = "en" ]; then
        hint "Adds a custom path prefix to your subscription URL"
        hint "Example: if you enter 'sub', URLs become https://domain.com/sub/<shortUuid>"
        echo
    else
        hint "Добавляет кастомный префикс к URL подписки"
        hint "Пример: если ввести 'sub', URL станет https://domain.com/sub/<shortUuid>"
        echo
    fi
    question "$(get_string install_subscription_enter_custom_prefix)"
    CUSTOM_SUB_PREFIX="$REPLY"

    echo

    # Marzban legacy links
    if [ "$LANGUAGE" = "en" ]; then
        hint "Enable this only if you are migrating from Marzban panel"
    else
        hint "Включайте только при миграции с панели Marzban"
    fi
    question "$(get_string install_subscription_enter_marzban_enabled)"
    local marzban_answer="$REPLY"
    if [[ "$marzban_answer" == "y" || "$marzban_answer" == "Y" ]]; then
        MARZBAN_LEGACY_LINK_ENABLED="true"
        question "$(get_string install_subscription_enter_marzban_secret)"
        MARZBAN_LEGACY_SECRET_KEY="$REPLY"
    fi

    echo

    # Caddy auth API token
    if [ "$LANGUAGE" = "en" ]; then
        hint "Only needed if using the 'Caddy with security' addon for panel protection"
    else
        hint "Нужен только при использовании аддона 'Caddy with security' для защиты панели"
    fi
    question "$(get_string install_subscription_enter_caddy_auth)"
    CADDY_AUTH_API_TOKEN="$REPLY"

    echo

    # Cloudflare Zero Trust
    if [ "$LANGUAGE" = "en" ]; then
        hint "Only needed if using Cloudflare Zero Trust to protect your panel"
    else
        hint "Нужен только при использовании Cloudflare Zero Trust для защиты панели"
    fi
    question "$(get_string install_subscription_enter_cf_client_id)"
    CF_ZERO_TRUST_CLIENT_ID="$REPLY"
    if [[ -n "$CF_ZERO_TRUST_CLIENT_ID" ]]; then
        question "$(get_string install_subscription_enter_cf_client_secret)"
        CF_ZERO_TRUST_CLIENT_SECRET="$REPLY"
    fi
}

# ─────────────────────────────────────
# Show confirmation summary
# ─────────────────────────────────────
show_summary() {
    local total_steps="$1"
    local step_num="$2"

    if [ "$LANGUAGE" = "en" ]; then
        print_step "$step_num" "$total_steps" "Review Your Settings"
        echo -e "  ${BOLD_GREEN}Please confirm everything looks correct before installing:${RESET}"
    else
        print_step "$step_num" "$total_steps" "Проверьте настройки"
        echo -e "  ${BOLD_GREEN}Пожалуйста, проверьте все настройки перед установкой:${RESET}"
    fi
    echo

    echo -e "  ${MAGENTA}── Core Settings ──────────────────────────────────────${RESET}"
    if [ "$INSTALL_WITH_PANEL" = true ]; then
        if [ "$LANGUAGE" = "en" ]; then
            summary_row "Installation mode:" "Same server as panel"
        else
            summary_row "Режим установки:" "На одном сервере с панелью"
        fi
    else
        if [ "$LANGUAGE" = "en" ]; then
            summary_row "Installation mode:" "Separate server"
        else
            summary_row "Режим установки:" "Отдельный сервер"
        fi
    fi
    summary_row "Panel domain:" "https://$PANEL_DOMAIN"
    summary_row "Subscription domain:" "https://$SUB_DOMAIN"
    summary_row "Subscription port:" "$SUB_PORT"
    summary_row "API Token:" "${API_TOKEN:0:8}..."

    # Show optional settings only if any are set
    local has_optional=false
    [[ -n "$CUSTOM_SUB_PREFIX" ]] && has_optional=true
    [[ "$MARZBAN_LEGACY_LINK_ENABLED" == "true" ]] && has_optional=true
    [[ -n "$CADDY_AUTH_API_TOKEN" ]] && has_optional=true
    [[ -n "$CF_ZERO_TRUST_CLIENT_ID" ]] && has_optional=true

    if [ "$has_optional" = true ]; then
        echo
        echo -e "  ${MAGENTA}── Advanced Settings ──────────────────────────────────${RESET}"
        [[ -n "$CUSTOM_SUB_PREFIX" ]] && summary_row "Custom sub prefix:" "$CUSTOM_SUB_PREFIX"
        [[ "$MARZBAN_LEGACY_LINK_ENABLED" == "true" ]] && summary_row "Marzban legacy:" "Enabled"
        [[ -n "$CADDY_AUTH_API_TOKEN" ]] && summary_row "Caddy auth token:" "${CADDY_AUTH_API_TOKEN:0:8}..."
        [[ -n "$CF_ZERO_TRUST_CLIENT_ID" ]] && summary_row "CF Zero Trust:" "Configured"
    fi

    echo
    while true; do
        if [ "$LANGUAGE" = "en" ]; then
            question "Proceed with installation? (y/n):"
        else
            question "Продолжить установку? (y/n):"
        fi
        local confirm="$REPLY"
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            return 0
        elif [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            if [ "$LANGUAGE" = "en" ]; then
                info "Installation cancelled."
            else
                info "Установка отменена."
            fi
            exit 0
        else
            if [ "$LANGUAGE" = "en" ]; then
                warn "Please enter only 'y' or 'n'"
            else
                warn "Пожалуйста, введите только 'y' или 'n'"
            fi
        fi
    done
}

# ═════════════════════════════════════
# MAIN
# ═════════════════════════════════════
main() {
    check_component

    local total_steps=6

    # ──────── STEP 1: Choose installation mode ────────
    if [ "$LANGUAGE" = "en" ]; then
        print_step 1 $total_steps "Installation Mode"
        echo -e "  ${GREEN}Choose where the subscription page will be installed:${RESET}"
        echo
        echo -e "  ${BOLD_CYAN}y)${RESET} ${WHITE}Same server${RESET} — panel and subscription page are on the same server"
        hint "Choose this if you have only one server"
        echo
        echo -e "  ${BOLD_CYAN}n)${RESET} ${WHITE}Separate server${RESET} — subscription page is on a different server"
        hint "Choose this for better security or load distribution"
        echo
    else
        print_step 1 $total_steps "Режим установки"
        echo -e "  ${GREEN}Выберите, где будет установлена страница подписок:${RESET}"
        echo
        echo -e "  ${BOLD_CYAN}y)${RESET} ${WHITE}Тот же сервер${RESET} — панель и страница подписок на одном сервере"
        hint "Выберите, если у вас только один сервер"
        echo
        echo -e "  ${BOLD_CYAN}n)${RESET} ${WHITE}Отдельный сервер${RESET} — страница подписок на другом сервере"
        hint "Выберите для лучшей безопасности или распределения нагрузки"
        echo
    fi

    while true; do
        if [ "$LANGUAGE" = "en" ]; then
            question "Same server as the panel? (y/n):"
        else
            question "На одном сервере с панелью? (y/n):"
        fi
        INSTALL_LOCATION="$REPLY"
        if [[ "$INSTALL_LOCATION" == "y" || "$INSTALL_LOCATION" == "Y" ]]; then
            INSTALL_WITH_PANEL=true
            if ! check_panel_installed; then
                if [ "$LANGUAGE" = "en" ]; then
                    warn "⚠ Panel not found on this server!"
                    hint "Install the panel first, or choose 'n' for separate server installation."
                else
                    warn "⚠ Панель не найдена на этом сервере!"
                    hint "Сначала установите панель или выберите 'n' для установки на отдельном сервере."
                fi
                echo
                continue
            fi
            break
        elif [[ "$INSTALL_LOCATION" == "n" || "$INSTALL_LOCATION" == "N" ]]; then
            INSTALL_WITH_PANEL=false
            break
        else
            if [ "$LANGUAGE" = "en" ]; then
                warn "Please enter only 'y' or 'n'"
            else
                warn "Пожалуйста, введите только 'y' или 'n'"
            fi
        fi
    done

    # ──────── STEP 2: Domain configuration ────────
    if [ "$LANGUAGE" = "en" ]; then
        print_step 2 $total_steps "Domain Configuration"
        hint "Enter domains WITHOUT http:// or https://"
        echo
    else
        print_step 2 $total_steps "Настройка доменов"
        hint "Введите домены БЕЗ http:// или https://"
        echo
    fi

    while true; do
        question "$(get_string install_subscription_enter_panel_domain)"
        PANEL_DOMAIN="$REPLY"
        # Strip protocol if user accidentally includes it
        PANEL_DOMAIN="${PANEL_DOMAIN#https://}"
        PANEL_DOMAIN="${PANEL_DOMAIN#http://}"
        PANEL_DOMAIN="${PANEL_DOMAIN%/}"
        if [[ -n "$PANEL_DOMAIN" ]]; then
            break
        fi
        warn "$(get_string install_subscription_domain_empty)"
    done

    echo

    while true; do
        question "$(get_string install_subscription_enter_sub_domain)"
        SUB_DOMAIN="$REPLY"
        # Strip protocol if user accidentally includes it
        SUB_DOMAIN="${SUB_DOMAIN#https://}"
        SUB_DOMAIN="${SUB_DOMAIN#http://}"
        SUB_DOMAIN="${SUB_DOMAIN%/}"
        if [[ -n "$SUB_DOMAIN" ]]; then
            break
        fi
        warn "$(get_string install_subscription_domain_empty)"
    done

    # ──────── STEP 3: Port configuration ────────
    if [ "$LANGUAGE" = "en" ]; then
        print_step 3 $total_steps "Port Configuration"
        hint "Default port is 3010 — press Enter to use default"
        echo
    else
        print_step 3 $total_steps "Настройка порта"
        hint "Порт по умолчанию: 3010 — нажмите Enter для использования по умолчанию"
        echo
    fi

    question "$(get_string install_subscription_enter_sub_port)"
    SUB_PORT="$REPLY"
    SUB_PORT=${SUB_PORT:-3010}

    # Validate port is a number
    while ! [[ "$SUB_PORT" =~ ^[0-9]+$ ]]; do
        if [ "$LANGUAGE" = "en" ]; then
            warn "Port must be a number."
        else
            warn "Порт должен быть числом."
        fi
        question "$(get_string install_subscription_enter_sub_port)"
        SUB_PORT="$REPLY"
        SUB_PORT=${SUB_PORT:-3010}
    done

    # ──────── STEP 4: API Token ────────
    if [ "$LANGUAGE" = "en" ]; then
        print_step 4 $total_steps "API Token"
        hint "Create your API token in the Remnawave Dashboard:"
        hint "Go to: Remnawave Settings → API Tokens → Create Token"
        echo
    else
        print_step 4 $total_steps "API Токен"
        hint "Создайте API токен в панели Remnawave:"
        hint "Перейдите: Настройки Remnawave → API токены → Создать токен"
        echo
    fi

    while true; do
        if [ "$LANGUAGE" = "en" ]; then
            question "Enter API Token:"
        else
            question "Введите API токен:"
        fi
        API_TOKEN="$REPLY"
        if [[ -n "$API_TOKEN" ]]; then
            break
        fi
        if [ "$LANGUAGE" = "en" ]; then
            warn "API Token cannot be empty. Please enter a value."
        else
            warn "API токен не может быть пустым. Пожалуйста, введите значение."
        fi
    done

    # ──────── STEP 5: Optional / Advanced settings ────────
    prompt_optional_config $total_steps 5

    # ──────── STEP 6: Confirmation summary ────────
    show_summary $total_steps 6

    # ──────── INSTALL ────────
    echo
    if [ "$LANGUAGE" = "en" ]; then
        echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
        echo -e "${BOLD_GREEN}  🚀 Starting Installation...${RESET}"
        echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    else
        echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
        echo -e "${BOLD_GREEN}  🚀 Начинаем установку...${RESET}"
        echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    fi
    echo

    if ! check_docker; then
        install_docker
    fi
    install_subscription

    echo
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    if [ "$LANGUAGE" = "en" ]; then
        echo -e "${BOLD_GREEN}  ✅ Installation Complete!${RESET}"
        echo
        echo -e "  ${CYAN}Your subscription page is now available at:${RESET}"
        echo -e "  ${BOLD_GREEN}https://${SUB_DOMAIN}/<shortUuid>${RESET}"
        if [[ -n "$CUSTOM_SUB_PREFIX" ]]; then
            echo -e "  ${BOLD_GREEN}https://${SUB_DOMAIN}/${CUSTOM_SUB_PREFIX}/<shortUuid>${RESET}"
        fi
        echo
        echo -e "  ${CYAN}Useful commands:${RESET}"
        echo -e "  ${WHITE}  View logs:      ${RESET}${DIM}cd /opt/remnawave/subscription && docker compose logs -f${RESET}"
        echo -e "  ${WHITE}  Restart:        ${RESET}${DIM}cd /opt/remnawave/subscription && docker compose restart${RESET}"
        echo -e "  ${WHITE}  Stop:           ${RESET}${DIM}cd /opt/remnawave/subscription && docker compose down${RESET}"
    else
        echo -e "${BOLD_GREEN}  ✅ Установка завершена!${RESET}"
        echo
        echo -e "  ${CYAN}Ваша страница подписок доступна по адресу:${RESET}"
        echo -e "  ${BOLD_GREEN}https://${SUB_DOMAIN}/<shortUuid>${RESET}"
        if [[ -n "$CUSTOM_SUB_PREFIX" ]]; then
            echo -e "  ${BOLD_GREEN}https://${SUB_DOMAIN}/${CUSTOM_SUB_PREFIX}/<shortUuid>${RESET}"
        fi
        echo
        echo -e "  ${CYAN}Полезные команды:${RESET}"
        echo -e "  ${WHITE}  Просмотр логов:  ${RESET}${DIM}cd /opt/remnawave/subscription && docker compose logs -f${RESET}"
        echo -e "  ${WHITE}  Перезапуск:      ${RESET}${DIM}cd /opt/remnawave/subscription && docker compose restart${RESET}"
        echo -e "  ${WHITE}  Остановка:       ${RESET}${DIM}cd /opt/remnawave/subscription && docker compose down${RESET}"
    fi
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    echo

    read -n 1 -s -r -p "$(get_string install_subscription_press_key)"
    exit 0
}

main
