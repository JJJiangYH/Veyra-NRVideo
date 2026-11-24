// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <string>

namespace veyra::log {
void info(const char* component, const std::string& message);
void warn(const char* component, const std::string& message);
}
