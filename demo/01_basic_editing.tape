# Basic Editing with Multilingual and Emoji
Output demo/01_basic_editing.gif
Set FontSize 18
Set Width 800
Set Height 400
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Set Shell "bash"
Env PS1 "$ "
# Start ze
Type "ze"
Enter
Sleep 1s
# Type Title
Type@40ms "# Basic Editing with Multilingual and Emoji"
Enter
Enter
Sleep 1s
# Type multilingual text
Type@40ms "Hello, ze! 🚀"
Enter
Type@40ms "日本語 한국어 中文"
Enter
Type@40ms "Привет Γεια σου"
Enter
Type@40ms "Emoji: 🚀 🎉 🔥 💯 ⚡"
Sleep 3s
# Exit without saving
Ctrl+x
Ctrl+c
Type "n"
Sleep 500ms

# Clear screen for clean loop
#Type "clear"
#Enter
#Sleep 300ms
