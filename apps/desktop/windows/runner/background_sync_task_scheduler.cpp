#include "background_sync_task_scheduler.h"

#include "background_sync_handoff.h"

#include <taskschd.h>
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cwctype>
#include <iomanip>
#include <sstream>
#include <vector>

namespace {

constexpr wchar_t kTaskNamePrefix[] = L"JianHe Background Sync-";

bool g_english_description = false;

std::wstring ExecutablePath();

template <typename T>
void ReleaseIf(T*& value) {
  if (value) {
    value->Release();
    value = nullptr;
  }
}

std::wstring HResultMessage(HRESULT result) {
  wchar_t* message = nullptr;
  FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                     FORMAT_MESSAGE_IGNORE_INSERTS,
                 nullptr, result, 0, reinterpret_cast<wchar_t*>(&message), 0,
                 nullptr);
  std::wstring text = message ? message : L"Windows Task Scheduler error";
  if (message) LocalFree(message);
  return text;
}

void HashBytes(uint64_t* hash, const void* data, size_t length) {
  constexpr uint64_t kFnvPrime = 1099511628211ULL;
  const auto* bytes = static_cast<const unsigned char*>(data);
  for (size_t index = 0; index < length; ++index) {
    *hash ^= bytes[index];
    *hash *= kFnvPrime;
  }
}

bool TaskName(std::wstring* task_name, std::wstring* error_message) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    if (error_message) {
      *error_message = HResultMessage(HRESULT_FROM_WIN32(GetLastError()));
    }
    return false;
  }
  DWORD required = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &required);
  std::vector<unsigned char> token_info(required);
  if (required == 0 ||
      !GetTokenInformation(token, TokenUser, token_info.data(), required,
                           &required)) {
    const DWORD error = GetLastError();
    CloseHandle(token);
    if (error_message) {
      *error_message = HResultMessage(HRESULT_FROM_WIN32(error));
    }
    return false;
  }
  CloseHandle(token);
  const auto* token_user =
      reinterpret_cast<const TOKEN_USER*>(token_info.data());

  std::wstring executable = ExecutablePath();
  std::transform(executable.begin(), executable.end(), executable.begin(),
                 [](wchar_t value) {
                   return static_cast<wchar_t>(towlower(value));
                 });
  uint64_t hash = 14695981039346656037ULL;
  HashBytes(&hash, token_user->User.Sid, GetLengthSid(token_user->User.Sid));
  const unsigned char separator = 0xff;
  HashBytes(&hash, &separator, sizeof(separator));
  HashBytes(&hash, executable.data(), executable.size() * sizeof(wchar_t));

  std::wostringstream suffix;
  suffix << std::hex << std::setfill(L'0') << std::setw(16) << hash;
  *task_name = std::wstring(kTaskNamePrefix) + suffix.str();
  return true;
}

BSTR Bstr(const std::wstring& value) {
  return SysAllocStringLen(value.data(), static_cast<UINT>(value.size()));
}

std::wstring ExecutablePath() {
  std::wstring buffer(32768, L'\0');
  const DWORD length = GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  buffer.resize(length);
  return buffer;
}

std::wstring ParentDirectory(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? L"" : path.substr(0, separator);
}

SYSTEMTIME NextBoundary(const BackgroundSyncSchedule& schedule) {
  SYSTEMTIME now{};
  GetLocalTime(&now);
  FILETIME file_time{};
  SystemTimeToFileTime(&now, &file_time);
  ULARGE_INTEGER ticks{};
  ticks.LowPart = file_time.dwLowDateTime;
  ticks.HighPart = file_time.dwHighDateTime;
  if (schedule.daily) {
    now.wHour = static_cast<WORD>(schedule.daily_hour);
    now.wMinute = static_cast<WORD>(schedule.daily_minute);
    now.wSecond = 0;
    now.wMilliseconds = 0;
    SYSTEMTIME current{};
    GetLocalTime(&current);
    FILETIME candidate{};
    FILETIME current_file{};
    SystemTimeToFileTime(&now, &candidate);
    SystemTimeToFileTime(&current, &current_file);
    ULARGE_INTEGER candidate_ticks{};
    candidate_ticks.LowPart = candidate.dwLowDateTime;
    candidate_ticks.HighPart = candidate.dwHighDateTime;
    ULARGE_INTEGER current_ticks{};
    current_ticks.LowPart = current_file.dwLowDateTime;
    current_ticks.HighPart = current_file.dwHighDateTime;
    if (candidate_ticks.QuadPart <= current_ticks.QuadPart) {
      candidate_ticks.QuadPart += 24ULL * 60ULL * 60ULL * 10000000ULL;
      candidate.dwLowDateTime = candidate_ticks.LowPart;
      candidate.dwHighDateTime = candidate_ticks.HighPart;
      FileTimeToSystemTime(&candidate, &now);
    }
    return now;
  }
  ticks.QuadPart += static_cast<ULONGLONG>(schedule.interval_minutes) *
                    60ULL * 10000000ULL;
  file_time.dwLowDateTime = ticks.LowPart;
  file_time.dwHighDateTime = ticks.HighPart;
  FileTimeToSystemTime(&file_time, &now);
  return now;
}

std::wstring IsoLocal(const SYSTEMTIME& value) {
  std::wostringstream stream;
  stream << std::setfill(L'0') << std::setw(4) << value.wYear << L'-'
         << std::setw(2) << value.wMonth << L'-' << std::setw(2)
         << value.wDay << L'T' << std::setw(2) << value.wHour << L':'
         << std::setw(2) << value.wMinute << L':' << std::setw(2)
         << value.wSecond;
  return stream.str();
}

bool Failed(HRESULT result, std::wstring* error_message) {
  if (SUCCEEDED(result)) return false;
  if (error_message) *error_message = HResultMessage(result);
  return true;
}

}  // namespace

bool ConfigureBackgroundSyncTask(const BackgroundSyncSchedule& schedule,
                                 std::wstring* next_run,
                                 std::wstring* error_message) {
  ITaskService* service = nullptr;
  ITaskFolder* root = nullptr;
  ITaskDefinition* definition = nullptr;
  IRegistrationInfo* registration = nullptr;
  IPrincipal* principal = nullptr;
  ITaskSettings* settings = nullptr;
  ITriggerCollection* triggers = nullptr;
  ITrigger* trigger = nullptr;
  IDailyTrigger* daily_trigger = nullptr;
  IRepetitionPattern* repetition = nullptr;
  IActionCollection* actions = nullptr;
  IAction* action = nullptr;
  IExecAction* exec_action = nullptr;
  IRegisteredTask* registered = nullptr;

  auto cleanup = [&]() {
    ReleaseIf(registered);
    ReleaseIf(exec_action);
    ReleaseIf(action);
    ReleaseIf(actions);
    ReleaseIf(repetition);
    ReleaseIf(daily_trigger);
    ReleaseIf(trigger);
    ReleaseIf(triggers);
    ReleaseIf(settings);
    ReleaseIf(principal);
    ReleaseIf(registration);
    ReleaseIf(definition);
    ReleaseIf(root);
    ReleaseIf(service);
  };

  HRESULT hr = CoCreateInstance(CLSID_TaskScheduler, nullptr,
                                CLSCTX_INPROC_SERVER, IID_ITaskService,
                                reinterpret_cast<void**>(&service));
  if (Failed(hr, error_message)) {
    cleanup();
    return false;
  }
  VARIANT empty;
  VariantInit(&empty);
  hr = service->Connect(empty, empty, empty, empty);
  if (SUCCEEDED(hr)) {
    BSTR root_path = Bstr(L"\\");
    hr = service->GetFolder(root_path, &root);
    SysFreeString(root_path);
  }
  if (SUCCEEDED(hr)) hr = service->NewTask(0, &definition);
  if (SUCCEEDED(hr)) hr = definition->get_RegistrationInfo(&registration);
  if (SUCCEEDED(hr)) {
    BSTR description = Bstr(g_english_description
                                ? L"JianHe scheduled background sync"
                                : L"笺盒后台定时同步");
    hr = registration->put_Description(description);
    SysFreeString(description);
  }
  if (SUCCEEDED(hr)) hr = definition->get_Principal(&principal);
  if (SUCCEEDED(hr)) hr = principal->put_LogonType(TASK_LOGON_INTERACTIVE_TOKEN);
  if (SUCCEEDED(hr)) hr = principal->put_RunLevel(TASK_RUNLEVEL_LUA);
  if (SUCCEEDED(hr)) hr = definition->get_Settings(&settings);
  if (SUCCEEDED(hr)) hr = settings->put_StartWhenAvailable(VARIANT_TRUE);
  if (SUCCEEDED(hr)) hr = settings->put_DisallowStartIfOnBatteries(VARIANT_FALSE);
  if (SUCCEEDED(hr)) hr = settings->put_StopIfGoingOnBatteries(VARIANT_FALSE);
  if (SUCCEEDED(hr)) hr = settings->put_MultipleInstances(TASK_INSTANCES_IGNORE_NEW);
  if (SUCCEEDED(hr)) {
    BSTR limit = Bstr(L"PT10M");
    hr = settings->put_ExecutionTimeLimit(limit);
    SysFreeString(limit);
  }
  // BackgroundSyncRunner retries only transient failures. Task Scheduler's
  // RestartOnFailure cannot filter by exit code and would also repeat terminal
  // authentication/protocol failures, so retries deliberately stay in Dart.
  if (SUCCEEDED(hr)) hr = definition->get_Triggers(&triggers);
  if (SUCCEEDED(hr)) hr = triggers->Create(TASK_TRIGGER_DAILY, &trigger);
  if (SUCCEEDED(hr)) hr = trigger->QueryInterface(IID_IDailyTrigger,
                                                   reinterpret_cast<void**>(&daily_trigger));
  const SYSTEMTIME boundary = NextBoundary(schedule);
  if (SUCCEEDED(hr)) {
    BSTR start = Bstr(IsoLocal(boundary));
    hr = daily_trigger->put_StartBoundary(start);
    SysFreeString(start);
  }
  if (SUCCEEDED(hr)) hr = daily_trigger->put_DaysInterval(1);
  if (SUCCEEDED(hr) && !schedule.daily) {
    hr = daily_trigger->get_Repetition(&repetition);
    if (SUCCEEDED(hr)) {
      BSTR interval = Bstr(L"PT" + std::to_wstring(schedule.interval_minutes) + L"M");
      hr = repetition->put_Interval(interval);
      SysFreeString(interval);
    }
    if (SUCCEEDED(hr)) {
      // A repetition duration includes its end boundary. Using exactly P1D
      // would make the final repetition coincide with the next daily trigger.
      BSTR duration = Bstr(L"PT23H59M");
      hr = repetition->put_Duration(duration);
      SysFreeString(duration);
    }
    if (SUCCEEDED(hr)) hr = repetition->put_StopAtDurationEnd(VARIANT_FALSE);
  }
  if (SUCCEEDED(hr)) hr = definition->get_Actions(&actions);
  if (SUCCEEDED(hr)) hr = actions->Create(TASK_ACTION_EXEC, &action);
  if (SUCCEEDED(hr)) hr = action->QueryInterface(IID_IExecAction,
                                                  reinterpret_cast<void**>(&exec_action));
  const std::wstring executable = ExecutablePath();
  if (SUCCEEDED(hr)) {
    BSTR path = Bstr(executable);
    hr = exec_action->put_Path(path);
    SysFreeString(path);
  }
  if (SUCCEEDED(hr)) {
    BSTR arguments = Bstr(L"--sync-once --silent");
    hr = exec_action->put_Arguments(arguments);
    SysFreeString(arguments);
  }
  if (SUCCEEDED(hr)) {
    BSTR directory = Bstr(ParentDirectory(executable));
    hr = exec_action->put_WorkingDirectory(directory);
    SysFreeString(directory);
  }
  if (SUCCEEDED(hr)) {
    std::wstring resolved_task_name;
    if (!TaskName(&resolved_task_name, error_message)) {
      cleanup();
      return false;
    }
    BSTR task_name = Bstr(resolved_task_name);
    VARIANT user;
    VariantInit(&user);
    VARIANT password;
    VariantInit(&password);
    VARIANT sddl;
    VariantInit(&sddl);
    hr = root->RegisterTaskDefinition(
        task_name, definition, TASK_CREATE_OR_UPDATE, user, password,
        TASK_LOGON_INTERACTIVE_TOKEN, sddl, &registered);
    SysFreeString(task_name);
  }
  if (FAILED(hr)) {
    Failed(hr, error_message);
    cleanup();
    return false;
  }
  DATE next_date = 0;
  if (SUCCEEDED(registered->get_NextRunTime(&next_date)) && next_run) {
    SYSTEMTIME next_system{};
    if (VariantTimeToSystemTime(next_date, &next_system)) {
      *next_run = IsoLocal(next_system);
    }
  }
  cleanup();
  return true;
}

bool CancelBackgroundSyncTask(std::wstring* error_message) {
  ClearBackgroundSyncPending();
  ITaskService* service = nullptr;
  ITaskFolder* root = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_TaskScheduler, nullptr,
                                CLSCTX_INPROC_SERVER, IID_ITaskService,
                                reinterpret_cast<void**>(&service));
  VARIANT empty;
  VariantInit(&empty);
  if (SUCCEEDED(hr)) hr = service->Connect(empty, empty, empty, empty);
  if (SUCCEEDED(hr)) {
    BSTR root_path = Bstr(L"\\");
    hr = service->GetFolder(root_path, &root);
    SysFreeString(root_path);
  }
  if (SUCCEEDED(hr)) {
    std::wstring resolved_task_name;
    if (!TaskName(&resolved_task_name, error_message)) {
      ReleaseIf(root);
      ReleaseIf(service);
      return false;
    }
    BSTR task_name = Bstr(resolved_task_name);
    hr = root->DeleteTask(task_name, 0);
    SysFreeString(task_name);
    if (hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) hr = S_OK;
  }
  ReleaseIf(root);
  ReleaseIf(service);
  if (Failed(hr, error_message)) return false;
  return true;
}

void SetBackgroundSyncTaskEnglish(bool english) {
  g_english_description = english;
}
