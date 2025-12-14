# Multi-window and Buffer Demo
Output demo/02_multi_window.gif

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
Type@40ms "# Multi-window and Buffer Demo"
Enter
Enter
Sleep 1s

# Type content with key explanation
Type@40ms "# C-x 2 : Split horizontal"
Enter
Sleep 800ms

# Split window horizontally
Ctrl+x
Type "2"
Sleep 1s

# Move end of buffer
Escape
Type ">"
Sleep 500ms

# Type in second window
Type@40ms "# M-o : Switch window"
Enter
Sleep 800ms

# Switch between windows
Escape
Type "o"
Sleep 600ms
Escape
Type "o"
Sleep 600ms

# Explain next action
Type@40ms "# C-x 3 : Split vertical"
Enter
Sleep 800ms

# Split vertically
Ctrl+x
Type "3"
Sleep 3s

# Exit
Ctrl+x
Ctrl+c
Sleep 300ms
Type "n"
Sleep 500ms
