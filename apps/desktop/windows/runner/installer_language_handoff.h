#ifndef RUNNER_INSTALLER_LANGUAGE_HANDOFF_H_
#define RUNNER_INSTALLER_LANGUAGE_HANDOFF_H_

#include <string>

// Returns the language the user picked in the installer's language dialog
// (the Inno Setup language name, e.g. "english" or "chinesesimplified"), or
// an empty string when no fresh choice is waiting. The installer writes the
// value only for interactive installs; a successful read consumes it so the
// in-app language setting is never overridden again by the same install.
std::string ConsumeInstallerLanguage();

#endif  // RUNNER_INSTALLER_LANGUAGE_HANDOFF_H_
