# syntax.zig 構造改善提案

## 概要
言語定義の構造化

## 問題
40言語が個別グローバル変数として定義されている (行 232-981)

```zig
// 現状
pub const lang_shell = LanguageDef{ ... };
pub const lang_python = LanguageDef{ ... };
// ... 38個続く ...

pub const all_languages = [_]*const LanguageDef{
    &lang_shell,
    &lang_python,
    // ... 手作業で順序付け ...
};
```

## 提案
```zig
pub const all_languages = [_]LanguageDef{
    .{
        .name = "Shell",
        .extensions = &.{ "sh", "bash", ... },
        // ...
    },
    .{
        .name = "Python",
        // ...
    },
    // ...
};

pub fn detectLanguage(...) *const LanguageDef {
    for (all_languages) |*lang| {
        if (...) return lang;
    }
    return &all_languages[all_languages.len - 1];
}
```

## 効果
- 新言語追加時に1箇所のみ編集
- グローバル変数削減
- ポインタ参照の削減

## 影響範囲
- 言語検出システム全体
- detectLanguage() の呼び出し元すべて
