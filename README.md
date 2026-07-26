# 麥注 mczy — 小麥注音(McBopomofo)的 Emacs 版

> 把[小麥注音](https://github.com/openvanilla/McBopomofo)的組句引擎與互動編輯器
> (InputController)編成一個自包的 stdio 小程式,由 Emacs 驅動。組字在 Emacs 內完成,
> commit 後的字可交給 emacs-everywhere 送往任何視窗。

核心打字手感與小麥注音同步:

- 整句智慧組字:Gramambular2 在讀音節點格子上走出機率最高的一整句
- 同音字回改:游標移回任一節點重選,整句就地重排--節點仍記著自己的注音,不必刪掉重打
- 自訂詞:組字時框選一段詞加入個人詞庫,引擎即時 reload,當下就選得到並提升排序
- 記憶最近選字、候選分頁(冷僻字也翻得到)、候選鍵可自訂

與 macOS / fcitx5 版的差別:

- 宿主是 **Emacs**,不向系統輸入法框架(IBus / IMKit / TSF)註冊、不跑常駐 daemon、不要 root、不跟桌面搶熱鍵
- 正式 Emacs 輸入法:`C-\`(`toggle-input-method`)開關,行為與內建輸入法一致
- 組字顯示為游標旁的 overlay(after-string),GUI 與 `emacs -nw` / SSH 終端都能打,不依賴 posframe / child frame
- commit 後的字靠 [emacs-everywhere](https://github.com/tecosaur/emacs-everywhere) 送出 Emacs 之外
- 空格中英快切:空組字區按一下空格離開注音,英文模式連按兩下切回(可關閉)

專案組織上:

- 重用 McBopomofo 的 controller(`KeyHandler` / `InputState`)與引擎,以 submodule vendor,**未改一行**
- 直接使用 McBopomofo macOS 版產生的詞庫 `data.txt`
- 代價是引擎的 C++ binary 要在安裝時編譯一次,如同 `vterm` 之於 `vterm-module`

## 安裝

先備好編譯工具(只在首次編引擎時用到):`git`、CMake ≥ 3.16、C++20 編譯器、**ICU**。

- macOS:`brew install cmake icu4c`
- Debian/Ubuntu:`sudo apt install build-essential cmake libicu-dev`

clone 後載入 `mczy.el`,首次按 `C-\` 會詢問並自動編譯引擎(submodule + CMake,進度顯示在
compilation buffer;等同 `M-x mczy-compile-engine`),編完再按一次就能打字。手動編譯見
[`engine/README.md`](engine/README.md)。

### 疑難排解:CMake 選到 GCC 9

引擎使用 C++20,上游原始碼的 UTF-8 識別字需要 GCC 10 以上。若自動編譯選到 GCC 9,CMake 會失敗;
即使之後裝了 GCC 11,`engine/build/` 仍快取著 GCC 9,得先刪掉再重跑。

在 repo 根目錄手動以 GCC 11 重建:

```sh
rm -rf engine/build
CC=gcc-11 CXX=g++-11 cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j
```

想保留 Emacs 的自動編譯流程,則刪掉 `engine/build/` 後在目前的 Emacs session 評估這兩行,
再執行 `M-x mczy-compile-engine`(或再按一次 `C-\`):

```elisp
(setenv "CC" "gcc-11")
(setenv "CXX" "g++-11")
```

引擎與詞庫路徑預設相對 `mczy.el`,clone 進來原地編好就免設定:

```elisp
(use-package mczy
  :load-path "~/src/mczy"            ; clone 出來的 repo 根目錄
  :config
  (setq default-input-method "chinese-mczy"))
;; 用 C-\ (toggle-input-method) 開關
```

用 `straight` 時 `mczy.el` 會被 symlink 進 `build/`、離開 `engine/`,預設引擎路徑因此失效,
需明指到 straight 的 repos clone(引擎也在那份 clone 裡編):

```elisp
(use-package mczy
  :straight (mczy :type git :host github :repo "staryes/mczy")
  :custom
  (mczy-engine-path
   "~/.emacs.d/straight/repos/mczy/engine/build/mczy-engine")
  (mczy-data-path
   "~/.emacs.d/straight/repos/mczy/engine/vendor/fcitx5-mcbopomofo/data/data.txt")
  :config
  (setq default-input-method "chinese-mczy"))
```

要把字送到 Emacs 以外的視窗,另裝 [`emacs-everywhere`](https://github.com/tecosaur/emacs-everywhere)。

## 設定

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `mczy-engine-path` | `engine/build/mczy-engine`(相對 `mczy.el`) | 引擎執行檔路徑 |
| `mczy-data-path` | `engine/vendor/.../data/data.txt`(相對 `mczy.el`) | McBopomofo 詞庫 `data.txt` 路徑 |
| `mczy-candidate-keys` | `"1234567890"` | 選字狀態下的候選鍵 |
| `mczy-user-phrases-path` | `~/.emacs.d/mczy-user-phrases.txt` | 框選加詞寫入的個人詞庫 |
| `mczy-space-toggle` | `both` | 空格觸發中英切換要開哪幾個方向,見下節 |
| `mczy-response-timeout` | `2.0` | 等待引擎完成一回合的秒數 |

常用範例:

```elisp
(setq mczy-candidate-keys "asdfghjkl"            ; 改用字母選字
      mczy-user-phrases-path
      (locate-user-emacs-file "mczy-user-phrases.txt"))
```

自建詞庫的格式(每行「詞 讀音」、`#` 註解)見
[`examples/user-phrases.txt`](examples/user-phrases.txt)。

讀音欄也可以填標點 key 來收**表情符號**:掛在 `_punctuation_^` 下的詞,按 **Shift+6**(`^`)
即列成候選,同一個 key 下多行就是多個候選。範例檔後半就是一整組顏文字。

候選鍵也可在互動中以 `M-x mczy-set-candidate-keys` 即時更換。

## 中英切換

短英文(變數名、網址、一句 `TODO`)不值得為它離開輸入法,所以空格兼任切換鍵。
兩個方向**刻意不對稱**:

| 方向 | 觸發 | 行為 |
| --- | --- | --- |
| 注音 → 英文 | **組字區為空**時按**一下**空格 | 輸出一個半形空格,切到 self-insert |
| 英文 → 注音 | 連按**兩下**空格 | 收斂成一個半形空格,切回注音 |

離開方向若也用雙空格,會跟注音的**一聲**撞車——「窩窩」這類連續一聲詞會被誤判成切換。
限定在空組字區才觸發,一聲就永遠安全:手上只要有沒送出的注音,空格照常餵給引擎
(選字狀態下則是翻頁)。

覺得太靈敏就用 `mczy-space-toggle` 關掉,可以只關單邊:

```elisp
(setq mczy-space-toggle 'to-chinese)   ; 只留「英文 → 注音」,空格不再把你踢出注音
(setq mczy-space-toggle nil)           ; 兩邊都關,只用明確指令切換
```

可選 `both`(預設)、`to-english`、`to-chinese`、`nil`。關掉的方向,空格回到本分:
注音模式餵引擎,英文模式自行插入。

下列指令不受這個設定影響,關掉自動切換時建議綁一個:

| 指令 | 作用 |
| --- | --- |
| `mczy-toggle-english` | 中英互換 |
| `mczy-set-english` | 切到英文 |
| `mczy-set-chinese` | 切到注音 |

```elisp
(global-set-key (kbd "<f9>") #'mczy-toggle-english)
```

mode line 顯示 **麥注**(注音)或 **麥Aa**(英文)。

## 與類似方案的比較

| | mczy | 系統 IME(gcin / fcitx5 / 內建) | pyim | liberime / RIME |
| --- | --- | --- | --- | --- |
| 安裝/部署 | 編譯引擎一次,載入一個 `.el` | 每平台一套框架,需註冊/daemon/權限 | 純 elisp,免編譯 | 需編譯並接 librime |
| 終端(`emacs -nw`)可用 | ✅ | 視框架而定 | ✅ | ✅ |
| 整句組字 | ✅(Gramambular2) | 視引擎 | ✅ | ✅ |
| 節點層同音字回改 | ✅ | 視引擎 | ✗(模型不同) | ✗(模型不同) |
| 不跟桌面搶熱鍵 / 免 root | ✅ | ✗ | ✅ | ✅ |
| 送字到 Emacs 以外 | ✅(emacs-everywhere) | 原生支援 | ✗ | ✗ |

選 McBopomofo 引擎的關鍵是這串手感:整句打完 → 回頭改選同音字 → 整句重排 → 再送出。
每個讀音節點都記著自己的注音,回頭重選時引擎能就地重走路徑。pyim 與 liberime/RIME 雖有整句,
模型不同,給不出節點層回改;交給 buffer 純文字編輯也補不回來--注音一旦離開引擎狀態就丟了。

相較於把同一顆引擎接在一般文字框上,`mczy` 多兩層可編輯:commit 前的 buffer 自由編輯,
以及 emacs-everywhere 送出前的整體檢查。

## 進一步閱讀

- [`docs/architecture.md`](docs/architecture.md) - 內部架構、sexp over stdio 協定與 schema、組字顯示/操作邏輯、設計取捨
- [`docs/m0-seam-notes.md`](docs/m0-seam-notes.md) - McBopomofo controller 從前端剝離的逐檔接縫考據

## 相關專案

- [McBopomofo](https://github.com/openvanilla/McBopomofo) - 引擎來源(Gramambular2 / Mandarin / McBopomofoLM)
- [fcitx5-mcbopomofo](https://github.com/openvanilla/fcitx5-mcbopomofo) - 同一顆 controller 換非-macOS 前端的範例
- [emacs-everywhere](https://github.com/tecosaur/emacs-everywhere) - 把組好的字送到 Emacs 之外
- [sis(emacs-smart-input-source)](https://github.com/laishulu/emacs-smart-input-source) - 空格觸發中英切換的手感來源

## 名稱由來

**麥注**取自「小**麥**注音」,格式沿用 Emacs 既有的注音輸入法命名慣例——內建的
`chinese-etzy` 是倚天注音、`chinese-zozy` 是零壹注音,都是「廠牌 + 注音(ZY)」。
本專案照此寫作 `mczy`,註冊為 `chinese-mczy`。

刻意不採用 McBopomofo 之名:MIT 授權涵蓋的是程式碼而非名稱,另取名可避免與上游混淆——
這個 Emacs 前端的問題該回報到本 repo,不是 openvanilla。引擎出處在本檔與
[`LICENSE`](LICENSE) 中標示。

## 授權

本專案自身的程式碼(`mczy.el`、`engine/main.cpp`、`engine/DictionaryService.cpp`、建置腳本)
以 **MIT** 釋出,見 [`LICENSE`](LICENSE)。

引擎重用的 McBopomofo 原始碼與詞庫 `data.txt` 同為 **MIT**,來自上游
[`fcitx5-mcbopomofo`](https://github.com/openvanilla/fcitx5-mcbopomofo)。這份 repo
**不重新散布**任何上游程式碼或詞庫:它們以 submodule 釘在上游 commit,由使用者 clone 時自上游取得。
