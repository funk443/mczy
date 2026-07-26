# mczy-engine

McBopomofo 的互動編輯控制器(`KeyHandler`)+ 組句引擎,接成一個獨立 binary,
對 stdio 講 sexp,取代 fcitx5 前端。這是 **M1 spike**(可行性閘門),已驗證
餵 key → 讀回 state → 選字 / 回改 / 整句重排 / commit 全程跑通。

接縫設計見 [`../docs/m0-seam-notes.md`](../docs/m0-seam-notes.md)。

## 組成

| 檔 | 作用 |
| --- | --- |
| `vendor/fcitx5-mcbopomofo/` | 上游 submodule(釘 `c29fd08`)。重用 `KeyHandler` / `InputState` / `Engine/*`,**未改一行**。 |
| `main.cpp` | sexp-over-stdio 迴圈 + `StateCallback`→sexp 序列化(取代 `McBopomofo.cpp` 前端)。 |
| `DictionaryService.cpp` | no-op stub,取代上游唯一與 compose 無關卻纏 fcitx 的 .cpp。 |
| `fcitx-shim/fcitx-utils/*.h` | ~15 行 no-op 標頭,讓上游碼在無 fcitx 下編譯(angle-include,`-I` 覆蓋)。 |

唯一外部相依:**ICU**(僅 `Big5Utils` 用到)。

## 編譯

```sh
git submodule update --init                 # 取得 vendor/fcitx5-mcbopomofo
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DICU_ROOT=$(brew --prefix icu4c@78)   # macOS;Linux 多半免設(libicu-dev)
cmake --build build -j
```

## 跑

```sh
./build/mczy-engine vendor/fcitx5-mcbopomofo/data/data.txt
# 或  MCZY_DATA=<data.txt 路徑> ./build/mczy-engine
# 選填第二參數:自訂字庫檔(框選加詞時寫入並 reload);也可用 MCZY_USER_PHRASES
./build/mczy-engine vendor/fcitx5-mcbopomofo/data/data.txt ~/.emacs.d/mczy-user-phrases.txt
```

逐行餵指令,每回合回 0..N 個狀態 sexp + 一個 `(done t|nil)` 終結:

```
(key "5") (key "j") (key "/") (key space) (key "j") (key "p") (key "6")
  -> (inputting (buffer "中文") (cursor 2))
(key left) (key space)
  -> (choosing (buffer "中文") (cursor 1) (candidates "中文" "中" "終" "鐘" ...))
(select 3)
  -> (inputting (buffer "鐘文") (cursor 1))     ; 整句重排
(key return)
  -> (commit "鐘文")
```

協定細節(指令文法、state tagged union、cursor 用 codepoint、escape 紀律)見
`main.cpp` 開頭註解與接縫筆記 §4。

## 自我驗證

```sh
./test_roundtrip.sh    # 跑上面整段,assert 選字/回改/整句重排/commit
```
