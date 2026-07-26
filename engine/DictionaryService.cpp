// No-op implementation of upstream's DictionaryService.h interface.
//
// KeyHandler's constructor builds a DictionaryServices and calls load(), so the
// symbols must link — but external dictionary lookup (open-in-browser, etc.) is
// irrelevant to the engine spike and is the only fcitx-coupled thing on this
// path. So we replace the upstream .cpp (which pulls fcitx i18n / startProcess /
// json-c) with this stub instead of compiling it.
//
// ponytail: stub, no services. Add real lookups only if mczy ever wants the
// "look up selected phrase" feature; until then this is the whole thing.
#include "DictionaryService.h"

namespace McBopomofo {

DictionaryServices::DictionaryServices() = default;
DictionaryServices::~DictionaryServices() = default;

bool DictionaryServices::hasServices() { return false; }

void DictionaryServices::load() {}

void DictionaryServices::lookup(std::string /*phrase*/, size_t /*serviceIndex*/,
                                InputState* /*state*/,
                                const StateCallback& /*stateCallback*/) {}

std::vector<std::string> DictionaryServices::menuForPhrase(
    const std::string& /*phrase*/) {
  return {};
}

}  // namespace McBopomofo
