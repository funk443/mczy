#!/usr/bin/env bash
# M1 acceptance self-check: 餵 key → read state → 選字 / 回改 / 整句重排 / commit.
# Drives the built mczy-engine through the same sequence upstream's KeyHandler
# test uses, plus a homophone re-selection, and asserts on the emitted sexp.
# Grep assertions, no test framework — the engine is the thing under test.
set -euo pipefail
cd "$(dirname "$0")"

BIN=build/mczy-engine
DATA=vendor/fcitx5-mcbopomofo/data/data.txt
[ -x "$BIN" ] || { echo "FAIL: build first (cmake --build build)"; exit 1; }
[ -f "$DATA" ] || { echo "FAIL: missing data — git submodule update --init"; exit 1; }

# 5j/=ㄓㄨㄥ space j p6=ㄨㄣˊ -> 中文 ; left ; space opens candidates ; select 鐘 ; commit
out=$(printf '%s\n' \
  '(key "5")' '(key "j")' '(key "/")' '(key space)' \
  '(key "j")' '(key "p")' '(key "6")' \
  '(key left)' '(key space)' '(select 3)' '(key return)' \
  | "$BIN" "$DATA")

fail=0
check() { if grep -qF "$1" <<<"$out"; then echo "ok: $2"; else echo "FAIL: $2"; fail=1; fi; }

check '(inputting (buffer "中文") (cursor 2))'  "compose whole sentence 中文"
check '(inputting (buffer "中文") (cursor 1))'  "回改: cursor moves back into the sentence"
check '(choosing (buffer "中文") (cursor 1) (candidates "中文" "中" "終" "鐘"' \
                                               "選字: homophones of ㄓㄨㄥ offered"
check '(inputting (buffer "鐘文") (cursor 1))'  "整句重排: sentence re-walks to 鐘文"
check '(commit "鐘文")'                          "commit emits the re-walked text"

# 自訂字庫: mark a non-dictionary 2-syllable phrase (鐘文) and add it; the
# reload must make it selectable, and the engine must NOT crash on add
# (onAddNewPhrase_ callback set).  Uses a throwaway user-phrase file.
UP=$(mktemp)
set +e
out2=$(printf '%s\n' \
  '(key "5")' '(key "j")' '(key "/")' '(key space)' \
  '(key "j")' '(key "p")' '(key "6")' \
  '(key left)' '(key space)' '(select 3)' '(key end)' \
  '(key left shift)' '(key left shift)' '(key return)' \
  '(reset)' \
  '(key "5")' '(key "j")' '(key "/")' '(key space)' \
  '(key "j")' '(key "p")' '(key "6")' '(key space)' \
  | "$BIN" "$DATA" "$UP")
rc=$?
set -e
rm -f "$UP"
if [ "$rc" -ne 0 ]; then echo "FAIL: engine crashed on user-phrase add (rc=$rc)"; fail=1
else echo "ok: 自訂字庫 add did not crash"; fi
check2() { if grep -qF "$1" <<<"$out2"; then echo "ok: $2"; else echo "FAIL: $2"; fail=1; fi; }
check2 '(marking (head "") (marked "鐘文") (tail "") (acceptable t))' \
                                               "框選: 鐘文 markable as a new phrase"
check2 '(candidates "鐘文"'                     "reload: 鐘文 selectable after add"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
