# 安全性

麥注是輸入法,它看得到你打進 Emacs 的每一個字。這份文件說明它拿這些字做什麼、
不做什麼,以及發現問題時該找誰。

## 回報漏洞

**請不要開公開 issue。** 兩個管道:

- GitHub 的 [private vulnerability reporting](https://github.com/staryes/mczy/security/advisories/new)
- 或寄信到 `turtalk@tuta.io`

麻煩附上版本(commit sha)、作業系統、Emacs 版本,以及重現步驟。

這是個人維護的專案,不是有值班表的組織。我會盡快回覆,但無法承諾 SLA。
如果一週沒有回音,請直接再敲一次。

## 範圍

**屬於本專案:**

- `mczy.el`
- `engine/main.cpp`、`engine/DictionaryService.cpp`、`engine/fcitx-shim/`
- `engine/CMakeLists.txt` 與安裝流程

**不屬於本專案:** `engine/vendor/fcitx5-mcbopomofo/` 底下的一切,那是上游
[McBopomofo](https://github.com/openvanilla/McBopomofo) 的程式碼與詞庫,本專案未改一行。
上游程式碼的問題請報到 openvanilla;若問題是「麥注**使用**上游 API 的方式有誤」,
那屬於本專案,歡迎報過來。

## 信任模型

### 執行期

- **不連網。** `mczy.el` 沒有任何 `url-*` / network process;`engine/main.cpp` 沒有
  socket、HTTP 或 process 啟動。這兩點可以自己 grep 驗證。
- **沒有遙測。** 不蒐集、不上傳任何東西。
- 引擎是本機 subprocess,以 `make-process` 的 `:command` list 啟動(**不經 shell**),
  只透過 stdin/stdout 用 sexp 溝通。
- Emacs 端用 `read-from-string` 解析引擎輸出,**只讀不 eval**;全檔沒有 `eval`。
- 你的自訂詞寫在 `mczy-user-phrases-path`(預設 `~/.emacs.d/mczy-user-phrases.txt`),
  純文字,留在本機。

### 刻意拿掉的東西

上游的 `DictionaryService.cpp` 有「查詢選取詞」功能,會把你選的詞組成 URL 並
`xdg-open` 丟給瀏覽器。本專案**不編譯那個檔**,改以
[`engine/DictionaryService.cpp`](engine/DictionaryService.cpp) 的 no-op stub 取代——
麥注不會因為你打了什麼而開啟瀏覽器或組出 URL。

### 安裝期(唯一會執行外來程式碼的時機)

首次 `C-\` 若偵測到引擎還沒編譯,會先問一句 `y-or-n`,得到同意後才執行:

```sh
git submodule update --init      # 自 GitHub 取得上游 McBopomofo 原始碼
cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j
```

也就是說,安裝時會**從網路取得原始碼並在你的機器上編譯**。這是任何需要編譯的
Emacs 套件(如 `vterm`)共有的性質,但值得明說:

- submodule **釘在固定 commit**(`c29fd08`),不是浮動 branch。上游即使被入侵,
  也不會自動流進你的建置——版本更新一律是本 repo 的一次明確 commit。
- 不想自動編譯就別按那個 `y`,改照 [`engine/README.md`](engine/README.md) 手動建置,
  過程中可以自行檢視原始碼。
- 詞庫 `data.txt` 同樣來自那個釘住的 submodule,不由本 repo 重新散布。

## 已知的非漏洞

- **引擎會知道你在打什麼。** 這是輸入法的定義,不是缺陷。上面「不連網、無遙測」
  幾點就是為此而存在的保證。
- **`~/.emacs.d/mczy-user-phrases.txt` 沒有加密。** 它是純文字,權限由你的檔案系統
  決定。別把密碼加成自訂詞。
- **多個 Emacs buffer 同時加詞可能交錯寫入同一個詞庫檔。** 已知的資料完整性限制,
  不是安全問題;見 `engine/main.cpp` 的註解。
