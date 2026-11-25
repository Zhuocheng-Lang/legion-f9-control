# bash 补全：安装到 $(pkg-config --variable=completionsdir bash-completion) 或
# /usr/share/bash-completion/completions/f9ctl
_f9ctl() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$prev" in
        --link)
            COMPREPLY=($(compgen -W "usb ble" -- "$cur"))
            return 0
            ;;
        --socket)
            COMPREPLY=($(compgen -f -- "$cur"))
            return 0
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--json --link --socket --help --version -h -V" -- "$cur"))
        return 0
    fi

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "status gear" -- "$cur"))
        return 0
    fi

    if [[ "${COMP_WORDS[1]}" == "gear" && ${COMP_CWORD} -eq 2 ]]; then
        COMPREPLY=($(compgen -W "quiet balanced beast turbo 0 1 2 3" -- "$cur"))
        return 0
    fi

    return 0
}
complete -F _f9ctl f9ctl
