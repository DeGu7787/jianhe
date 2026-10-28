#include "installer_language_handoff.h"

#include <windows.h>

#include "utils.h"

namespace {

// Written by installer/jianhe_installer.iss in ssPostInstall.
constexpr wchar_t kJianHeRegistryKey[] = L"Software\\JianHe";
constexpr wchar_t kInstallerLanguageValueName[] = L"InstallerLanguage";
// Inno Setup language names are short ASCII identifiers.
constexpr DWORD kMaxLanguageChars = 64;

}  // namespace

std::string ConsumeInstallerLanguage() {
  HKEY key = nullptr;
  const LSTATUS opened = RegOpenKeyExW(
      HKEY_CURRENT_USER, kJianHeRegistryKey, 0, KEY_QUERY_VALUE | KEY_SET_VALUE,
      &key);
  if (opened != ERROR_SUCCESS) return std::string();

  wchar_t buffer[kMaxLanguageChars + 1] = {};
  DWORD type = 0;
  DWORD size = sizeof(buffer) - sizeof(wchar_t);
  const LSTATUS read = RegQueryValueExW(
      key, kInstallerLanguageValueName, nullptr, &type,
      reinterpret_cast<BYTE*>(buffer), &size);
  std::string language;
  if (read == ERROR_SUCCESS && type == REG_SZ) {
    buffer[size / sizeof(wchar_t)] = L'\0';
    language = Utf8FromUtf16(buffer);
  }
  // Consume any value, even a malformed or oversized one, so it cannot be
  // re-applied on every start.
  if (read == ERROR_SUCCESS || read == ERROR_MORE_DATA) {
    RegDeleteValueW(key, kInstallerLanguageValueName);
  }
  RegCloseKey(key);
  return language;
}
