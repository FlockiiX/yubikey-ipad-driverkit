#include "DriverConnection.h"

#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

static const char* kDriverServiceName = "YubiKeyUSBDriver";

kern_return_t YKUSBOpen(io_connect_t* connection, const char** operation)
{
    if (operation != NULL) *operation = "YKUSBOpen";
    if (connection == NULL) return kIOReturnBadArgument;
    *connection = IO_OBJECT_NULL;
    if (operation != NULL) *operation = "IOServiceNameMatching(YubiKeyUSBDriver)";
    CFMutableDictionaryRef matching = IOServiceNameMatching(kDriverServiceName);
    if (matching == NULL) return kIOReturnNoMemory;
    if (operation != NULL) *operation = "IOServiceGetMatchingService(YubiKeyUSBDriver)";
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (service == IO_OBJECT_NULL) return kIOReturnNotFound;
    if (operation != NULL) *operation = "IOServiceOpen(YubiKeyUSBDriver)";
    kern_return_t result = IOServiceOpen(service, mach_task_self_, 0, connection);
    IOObjectRelease(service);
    if (result == kIOReturnSuccess && operation != NULL) *operation = NULL;
    return result;
}

void YKUSBClose(io_connect_t connection)
{
    if (connection != IO_OBJECT_NULL) IOServiceClose(connection);
}

kern_return_t YKUSBGetDeviceInfo(io_connect_t connection, YKUSBDeviceInfo* info)
{
    if (connection == IO_OBJECT_NULL || info == NULL) return kIOReturnBadArgument;
    memset(info, 0, sizeof(*info));
    size_t outputSize = sizeof(*info);
    kern_return_t result = IOConnectCallStructMethod(
        connection,
        kYKUSBMethodGetDeviceInfo,
        NULL,
        0,
        info,
        &outputSize
    );
    if (result == kIOReturnSuccess && outputSize != sizeof(*info)) return kIOReturnUnderrun;
    return result;
}

kern_return_t YKUSBGetFeatureReport(
    io_connect_t connection,
    uint8_t report[kYKUSBFeatureReportSize])
{
    if (connection == IO_OBJECT_NULL || report == NULL) return kIOReturnBadArgument;
    memset(report, 0, kYKUSBFeatureReportSize);
    size_t outputSize = kYKUSBFeatureReportSize;
    kern_return_t result = IOConnectCallStructMethod(
        connection,
        kYKUSBMethodGetFeatureReport,
        NULL,
        0,
        report,
        &outputSize
    );
    if (result == kIOReturnSuccess && outputSize != kYKUSBFeatureReportSize) return kIOReturnUnderrun;
    return result;
}

kern_return_t YKUSBSetFeatureReport(
    io_connect_t connection,
    const uint8_t report[kYKUSBFeatureReportSize])
{
    if (connection == IO_OBJECT_NULL || report == NULL) return kIOReturnBadArgument;
    return IOConnectCallStructMethod(
        connection,
        kYKUSBMethodSetFeatureReport,
        report,
        kYKUSBFeatureReportSize,
        NULL,
        NULL
    );
}

const char* YKUSBReturnName(kern_return_t result)
{
    switch (result) {
        case kIOReturnSuccess: return "kIOReturnSuccess";
        case kIOReturnNotOpen: return "kIOReturnNotOpen";
        case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess";
        case kIOReturnNotPrivileged: return "kIOReturnNotPrivileged";
        case kIOReturnNotPermitted: return "kIOReturnNotPermitted";
        case kIOReturnBadArgument: return "kIOReturnBadArgument";
        case kIOReturnNotFound: return "kIOReturnNotFound";
        case kIOReturnTimeout: return "kIOReturnTimeout";
        case kIOReturnNoDevice: return "kIOReturnNoDevice";
        case kIOReturnNotAttached: return "kIOReturnNotAttached";
        case kIOReturnOffline: return "kIOReturnOffline";
        case kIOReturnNotReady: return "kIOReturnNotReady";
        case kIOReturnUnsupported: return "kIOReturnUnsupported";
        default: return "IOReturn";
    }
}
