# Shell Integration - JSON formatting with jq
Output demo/03_shell_jq.gif

Set FontSize 18
Set Width 900
Set Height 500
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Set Shell "bash"
Env PS1 "$ "

# Start ze
Type "ze"
Enter
Sleep 1s

# Type Title
Type@40ms "# Shell Integration - Format JSON with jq"
Enter
Enter
Sleep 1s

# Type messy JSON
Type@30ms '{"name":"ze","version":"1.0","features":["fast","minimal"]}'
Sleep 800ms

# Explain: shell pipe
Type@40ms "  # M-| : Shell pipe"
Sleep 3s

# Delete and do shell pipe
Backspace 19
Ctrl+a
Escape
Type "|"
Sleep 500ms

# Type the command
Type@60ms ". | jq . >"
Sleep 2s
Enter
Sleep 1.5s

# Show result
Sleep 3s

# Exit
Ctrl+x
Ctrl+c
Type "n"
Sleep 500ms
