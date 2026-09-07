# f9ctl bash 补全（手工维护，随发布更新）。
_f9ctl() {
    local cur prev words cword
    _init_completion || return
    case "$prev" in
    --transport)
        COMPREPLY=($(compgen -W "auto usb ble" -- "$cur"))
        return
        ;;
    --output)
        COMPREPLY=($(compgen -W "human json" -- "$cur"))
        return
        ;;
    -o | --timeout)
        return
        ;;
    esac
    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--transport --device --output --timeout --verbose --no-daemon --show-device-identifiers --help --version" -- "$cur"))
        return
    fi
    case "${COMP_WORDS[1]}" in
    mode)
        if [[ "${COMP_WORDS[2]}" == "set" ]]; then
            COMPREPLY=($(compgen -W "quiet balanced beast turbo" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "get set" -- "$cur"))
        fi
        return
        ;;
    devices)
        COMPREPLY=($(compgen -W "list" -- "$cur"))
        return
        ;;
    daemon)
        COMPREPLY=($(compgen -W "install uninstall start stop restart status logs run" -- "$cur"))
        return
        ;;
    config)
        COMPREPLY=($(compgen -W "path show validate" -- "$cur"))
        return
        ;;
    debug)
        COMPREPLY=($(compgen -W "raw" -- "$cur"))
        return
        ;;
    *)
        COMPREPLY=($(compgen -W "devices status info mode monitor daemon config debug --help --version" -- "$cur"))
        return
        ;;
    esac
}
complete -F _f9ctl f9ctl
