# Shell Integration - ASCII Art with figlet
Output demo/04_shell_figlet.gif

Set FontSize 18
Set Width 900
Set Height 500
Set Theme "Catppuccin Mocha"
Set Padding 8
Set TypingSpeed 50ms
Set Shell "bash"
Env PS1 "$ "

# Start ze
Type "ze"
Enter
Sleep 800ms

# Type Title
Type@40ms "# Shell Integration - ASCII Art with figlet"
Enter
Enter
Sleep 1s

# Type text
Type@40ms "Welcome to ze!"
Sleep 500ms

# Select text
Ctrl+a
Ctrl+Space
Ctrl+e
Sleep 500ms

# Explain: shell pipe with +>
Escape
Type@40ms "  # M-| with '+>' : insert at cursor"
Sleep 3s
Backspace 35

# Shell pipe
Escape
Type "|"
Sleep 500ms
Type@60ms "figlet +>"
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
