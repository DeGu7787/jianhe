#include "background_sync_handoff.h"

#include <windows.h>

namespace {

constexpr wchar_t kJianHeRegistryKey[] = L"Software\\JianHe";
constexpr wchar_t kPendingValueName[] = L"BackgroundSyncPending";

}  // namespace

bool MarkBackgroundSyncPending() {
  HKEY key = nullptr;
  const LSTATUS opened = RegCreateKeyExW(
      HKEY_CURRENT_USER, kJianHeRegistryKey, 0, nullptr,
      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (opened != ERROR_SUCCESS) return false;
  const DWORD pending = 1;
  const LSTATUS written =
      RegSetValueExW(key, kPendingValueName, 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&pending), sizeof(pending));
  RegCloseKey(key);
  return written == ERROR_SUCCESS;
}

bool IsBackgroundSyncPending() {
  DWORD pending = 0;
  DWORD size = sizeof(pending);
  return RegGetValueW(HKEY_CURRENT_USER, kJianHeRegistryKey, kPendingValueName,
                      RRF_RT_REG_DWORD, nullptr, &pending, &size) ==
             ERROR_SUCCESS &&
         size == sizeof(pending) && pending == 1;
}

bool ConsumeBackgroundSyncPending() {
  HKEY key = nullptr;
  const LSTATUS opened = RegOpenKeyExW(
      HKEY_CURRENT_USER, kJianHeRegistryKey, 0, KEY_QUERY_VALUE | KEY_SET_VALUE,
      &key);
  if (opened != ERROR_SUCCESS) return false;

  DWORD pending = 0;
  DWORD type = 0;
  DWORD size = sizeof(pending);
  const LSTATUS read = RegQueryValueExW(
      key, kPendingValueName, nullptr, &type,
      reinterpret_cast<BYTE*>(&pending), &size);
  const bool existed = read == ERROR_SUCCESS && type == REG_DWORD &&
                       size == sizeof(pending) && pending == 1;
  if (read == ERROR_SUCCESS) RegDeleteValueW(key, kPendingValueName);
  RegCloseKey(key);
  return existed;
}

void ClearBackgroundSyncPending() {
  HKEY key = nullptr;
  const LSTATUS opened = RegOpenKeyExW(
      HKEY_CURRENT_USER, kJianHeRegistryKey, 0, KEY_SET_VALUE, &key);
  if (opened != ERROR_SUCCESS) return;
  RegDeleteValueW(key, kPendingValueName);
  RegCloseKey(key);
}
