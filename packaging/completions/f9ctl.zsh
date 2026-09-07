#compdef f9ctl
# f9ctl zsh 补全（手工维护）。
_f9ctl() {
    local -a global_cmds
    global_cmds=('devices:list devices' 'status:read live status' 'info:read device info' 'mode:gear get/set' 'monitor:continuous monitoring' 'daemon:daemon control' 'config:config file ops' 'debug:raw debugging')
    _arguments -C \
        '--transport[transport]: :(auto usb ble)' \
        '--device[device selector]' \
        '--output[output format]: :(human json)' \
        '--timeout[timeout]' \
        '(-v --verbose)'{-v,--verbose}'[verbose]' \
        '--no-daemon[bypass f9d IPC]' \
        '--show-device-identifiers[show device identifiers]' \
        '--help[help]' \
        '--version[version]' \
        '1:cmd:->cmds' \
        '*::arg:->args'
    case $state in
        cmds)
            _describe 'command' global_cmds ;;
        args)
            case ${words[1]} in
                mode) _values 'action' get set quiet balanced beast turbo ;;
                devices) _values 'action' list ;;
                daemon) _values 'action' install uninstall start stop restart status logs run ;;
                config) _values 'action' path show validate ;;
                debug) _values 'action' raw ;;
            esac ;;
    esac
}
_f9ctl "$@"
