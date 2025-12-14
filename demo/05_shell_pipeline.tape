# Shell Integration - Pipeline (grep)
Output demo/05_shell_pipeline.gif

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
Sleep 1s

# Type Title
Type@40ms "# Shell Integration - Extract TODOs with grep"
Sleep 3s
Ctrl+a
Ctrl+k
Sleep 300ms

# Type some lines with TODOs
Type@30ms "// TODO: Add feature A"
Enter
Type@30ms "function doSomething() {"
Enter
Type@30ms "  // TODO: Implement"
Enter
Type@30ms "}"
Enter
Type@30ms "// TODO: Refactor"
Sleep 500ms

# Explain: shell pipe to new buffer
Enter
Ctrl+a
Type@40ms "# M-| with 'n>' : output to new buffer"
Sleep 3s

# Delete explanation
Ctrl+a
Ctrl+k
Sleep 300ms

# Shell: extract TODOs to new buffer
Escape
Type "|"
Sleep 500ms
Type@60ms "% | grep TODO n>"
Sleep 2s
Enter
Sleep 1.5s

# Show new buffer with results
Sleep 3s

# Exit
Ctrl+x
Ctrl+c
Type "n"
Sleep 300ms
#Type "n"
#Sleep 500ms
