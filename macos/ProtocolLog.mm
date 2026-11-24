// SPDX-License-Identifier: GPL-3.0-only
#include "../include/veyra/ProtocolLog.h"
#import <os/log.h>

namespace veyra::log {
void info(const char *component, const std::string& message) {
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEBUG, "%{public}s %{private}s", component, message.c_str());
}
void warn(const char *component, const std::string& message) {
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "%{public}s %{private}s", component, message.c_str());
}
}
