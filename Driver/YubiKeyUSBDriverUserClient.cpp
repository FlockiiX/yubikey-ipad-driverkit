// The app's only entry point into the driver.
//
// It exposes exactly the three selectors in DriverAPI.h, each with a fixed
// structure size that IOUserClientMethodDispatch checks before the call. The
// app cannot send arbitrary USB requests; the driver builds them itself.

#include <DriverKit/IOLib.h>
#include <DriverKit/OSData.h>

#include "DriverAPI.h"
#include "YubiKeyUSBDriver.h"
#include "YubiKeyUSBDriverUserClient.h"

struct YubiKeyUSBDriverUserClient_IVars {
    YubiKeyUSBDriver* driver = nullptr;
};

static const IOUserClientMethodDispatch kMethodDispatch[kYKUSBMethodCount] = {
    {
        .function = (IOUserClientMethodFunction)&YubiKeyUSBDriverUserClient::StaticGetDeviceInfo,
        .checkCompletionExists = false,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = sizeof(YKUSBDeviceInfo),
    },
    {
        .function = (IOUserClientMethodFunction)&YubiKeyUSBDriverUserClient::StaticGetFeatureReport,
        .checkCompletionExists = false,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = kYKUSBFeatureReportSize,
    },
    {
        .function = (IOUserClientMethodFunction)&YubiKeyUSBDriverUserClient::StaticSetFeatureReport,
        .checkCompletionExists = false,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = kYKUSBFeatureReportSize,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
};

bool YubiKeyUSBDriverUserClient::init(void)
{
    if (!super::init()) return false;
    ivars = IONewZero(YubiKeyUSBDriverUserClient_IVars, 1);
    return ivars != nullptr;
}

void YubiKeyUSBDriverUserClient::free(void)
{
    if (ivars != nullptr) {
        OSSafeReleaseNULL(ivars->driver);
        IOSafeDeleteNULL(ivars, YubiKeyUSBDriverUserClient_IVars, 1);
    }
    super::free();
}

kern_return_t YubiKeyUSBDriverUserClient::Start_Impl(IOService* provider)
{
    kern_return_t result = Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;
    ivars->driver = OSDynamicCast(YubiKeyUSBDriver, provider);
    if (ivars->driver == nullptr) return kIOReturnBadArgument;
    ivars->driver->retain();
    return kIOReturnSuccess;
}

kern_return_t YubiKeyUSBDriverUserClient::Stop_Impl(IOService* provider)
{
    OSSafeReleaseNULL(ivars->driver);
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t YubiKeyUSBDriverUserClient::ExternalMethod(
    uint64_t selector,
    IOUserClientMethodArguments* arguments,
    const IOUserClientMethodDispatch*, // replaced by this class's own dispatch table
    OSObject* target,
    void* reference)
{
    if (selector >= kYKUSBMethodCount) return kIOReturnUnsupported;
    return super::ExternalMethod(
        selector,
        arguments,
        &kMethodDispatch[selector],
        target != nullptr ? target : this,
        reference
    );
}

kern_return_t YubiKeyUSBDriverUserClient::StaticGetDeviceInfo(
    OSObject* target, void*, IOUserClientMethodArguments* arguments)
{
    if (target == nullptr) return kIOReturnBadArgument;
    return static_cast<YubiKeyUSBDriverUserClient*>(target)->GetDeviceInfo(arguments);
}

kern_return_t YubiKeyUSBDriverUserClient::StaticGetFeatureReport(
    OSObject* target, void*, IOUserClientMethodArguments* arguments)
{
    if (target == nullptr) return kIOReturnBadArgument;
    return static_cast<YubiKeyUSBDriverUserClient*>(target)->GetFeatureReport(arguments);
}

kern_return_t YubiKeyUSBDriverUserClient::StaticSetFeatureReport(
    OSObject* target, void*, IOUserClientMethodArguments* arguments)
{
    if (target == nullptr) return kIOReturnBadArgument;
    return static_cast<YubiKeyUSBDriverUserClient*>(target)->SetFeatureReport(arguments);
}

kern_return_t YubiKeyUSBDriverUserClient::GetDeviceInfo(IOUserClientMethodArguments* arguments)
{
    if (ivars->driver == nullptr) return kIOReturnNotAttached;
    YKUSBDeviceInfo info = {};
    kern_return_t result = ivars->driver->CopyDeviceInfo(&info);
    if (result == kIOReturnSuccess) {
        arguments->structureOutput = OSData::withBytes(&info, sizeof(info));
        if (arguments->structureOutput == nullptr) result = kIOReturnNoMemory;
    }
    return result;
}

kern_return_t YubiKeyUSBDriverUserClient::GetFeatureReport(IOUserClientMethodArguments* arguments)
{
    if (ivars->driver == nullptr) return kIOReturnNotAttached;
    uint8_t report[kYKUSBFeatureReportSize] = {};
    kern_return_t result = ivars->driver->GetFeatureReport(report);
    if (result == kIOReturnSuccess) {
        arguments->structureOutput = OSData::withBytes(report, sizeof(report));
        if (arguments->structureOutput == nullptr) result = kIOReturnNoMemory;
    }
    return result;
}

kern_return_t YubiKeyUSBDriverUserClient::SetFeatureReport(IOUserClientMethodArguments* arguments)
{
    if (ivars->driver == nullptr) return kIOReturnNotAttached;
    if (arguments->structureInput == nullptr ||
        arguments->structureInput->getLength() != kYKUSBFeatureReportSize) {
        return kIOReturnBadArgument;
    }
    const uint8_t* report = static_cast<const uint8_t*>(
        arguments->structureInput->getBytesNoCopy()
    );
    return ivars->driver->SetFeatureReport(report);
}
