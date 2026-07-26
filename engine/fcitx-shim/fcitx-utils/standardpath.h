// ponytail: no-op shim for fcitx's legacy StandardPath API. Only reached if
// USE_LEGACY_FCITX5_API_STANDARDPATH is defined (it isn't, in our build) — kept
// so PathCompat.h compiles regardless of which branch its #if picks.
#ifndef MCZY_SHIM_FCITX_UTILS_STANDARDPATH_H_
#define MCZY_SHIM_FCITX_UTILS_STANDARDPATH_H_

#include <string>

namespace fcitx {

class StandardPath {
 public:
  enum class Type { Config, PkgConfig, Data, PkgData, Cache, Runtime, Addon };
  static StandardPath& global() {
    static StandardPath instance;
    return instance;
  }
  std::string locate(Type, const std::string&) const { return {}; }
  std::string userDirectory(Type) const { return {}; }
};

}  // namespace fcitx

#endif  // MCZY_SHIM_FCITX_UTILS_STANDARDPATH_H_
