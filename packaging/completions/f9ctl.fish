# fish 补全：安装到 /usr/share/fish/vendor_completions.d/f9ctl.fish
complete -c f9ctl -f
complete -c f9ctl -l json -d '以 JSON 输出结果'
complete -c f9ctl -l link -x -a 'usb ble' -d '只走指定链路（不回落）'
complete -c f9ctl -l socket -r -d '连接指定 socket'
complete -c f9ctl -s h -l help -d '显示帮助'
complete -c f9ctl -s V -l version -d '显示版本'
complete -c f9ctl -n '__fish_use_subcommand' -a status -d '读取实时状态（flag、RPM）'
complete -c f9ctl -n '__fish_use_subcommand' -a gear -d '读取或设置挡位'
complete -c f9ctl -n '__fish_seen_subcommand_from gear' -a 'quiet balanced beast turbo 0 1 2 3' -d '挡位'
