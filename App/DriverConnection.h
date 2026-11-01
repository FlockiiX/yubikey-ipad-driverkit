// A thin C wrapper around the IOKit user-client calls, imported into Swift
// through the bridging header. Every function returns an IOReturn.

#ifndef YKUSB_DRIVER_CONNECTION_H
#define YKUSB_DRIVER_CONNECTION_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include "DriverAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// On failure, operation identifies the failing step (a static string; do not free).
kern_return_t YKUSBOpen(io_connect_t* connection, const char** operation);
void YKUSBClose(io_connect_t connection);
kern_return_t YKUSBGetDeviceInfo(io_connect_t connection, YKUSBDeviceInfo* info);
kern_return_t YKUSBGetFeatureReport(io_connect_t connection, uint8_t report[kYKUSBFeatureReportSize]);
kern_return_t YKUSBSetFeatureReport(io_connect_t connection, const uint8_t report[kYKUSBFeatureReportSize]);
const char* YKUSBReturnName(kern_return_t result);

#ifdef __cplusplus
}
#endif

#endif /* YKUSB_DRIVER_CONNECTION_H */
