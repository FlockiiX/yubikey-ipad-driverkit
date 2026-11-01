#include "DriverStub.h"
#include <string.h>

static kern_return_t nextOpen = kIOReturnNotFound;
static kern_return_t nextInfo = kIOReturnSuccess;
static int serviceMissing = 1;

void YKTestSetResults(kern_return_t openResult, kern_return_t infoResult, int missingService)
{
    nextOpen = openResult;
    nextInfo = infoResult;
    serviceMissing = missingService;
}

kern_return_t YKUSBOpen(io_connect_t* connection, const char** operation)
{
    *connection = nextOpen == kIOReturnSuccess ? 1 : IO_OBJECT_NULL;
    *operation = serviceMissing ? "IOServiceGetMatchingService(YubiKeyUSBDriver)" : "IOServiceOpen(YubiKeyUSBDriver)";
    return nextOpen;
}

void YKUSBClose(io_connect_t connection) {}

kern_return_t YKUSBGetDeviceInfo(io_connect_t connection, YKUSBDeviceInfo* info)
{
    memset(info, 0, sizeof(*info));
    info->abiVersion = kYKUSBDriverABIVersion;
    info->vendorID = 0x1050;
    info->productID = 0x0407;
    strcpy(info->product, "Test YubiKey");
    info->otpInterfaceNumber = 0;
    info->deviceOpenResult = kIOReturnSuccess;
    return nextInfo;
}

kern_return_t YKUSBGetFeatureReport(io_connect_t connection, uint8_t* report)
{
    const uint8_t status[8] = {0, 5, 7, 1, 9, 3, 0, 0};
    memcpy(report, status, sizeof(status));
    return kIOReturnSuccess;
}

kern_return_t YKUSBSetFeatureReport(io_connect_t connection, const uint8_t* report)
{
    return kIOReturnSuccess;
}

const char* YKUSBReturnName(kern_return_t result)
{
    return result == kIOReturnNotFound ? "kIOReturnNotFound" : "TestIOReturn";
}
