// A device-level USBDriverKit driver for the OTP HID interface of a YubiKey.
//
// Start() opens the USB device, activates its configuration, finds the OTP
// interface by its HID report descriptor, and registers the service so the
// app can open a user client. After that the driver performs only two
// operations, on request: GET_REPORT and SET_REPORT of an eight-byte HID
// Feature report on that interface. The OTP protocol runs in the app.

#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOLib.h>
#include <USBDriverKit/AppleUSBDefinitions.h>
#include <USBDriverKit/IOUSBHostDevice.h>
#include <USBDriverKit/USBDriverKit.h>
#include <os/log.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "YubiKeyUSBDriver.h"
#include "YubiKeyUSBDriverUserClient.h"

struct YubiKeyUSBDriver_IVars {
    IOUSBHostDevice* device = nullptr;
    bool deviceIsOpen = false;
    kern_return_t configurationResult = kIOReturnNotReady;
    YKUSBDeviceInfo info = {};
};

namespace {

constexpr uint16_t kYubicoVendorID = 0x1050;
constexpr uint32_t kControlTimeoutMS = 2000;
constexpr uint16_t kEnglishLanguageID = 0x0409;

// HID class definitions (Device Class Definition for HID 1.11).
constexpr uint8_t kUSBInterfaceClassHID = 0x03;
constexpr uint8_t kHIDDescriptorType = 0x21;
constexpr uint8_t kHIDDescriptorMinimumLength = 9;
constexpr uint8_t kHIDReportDescriptorType = 0x22;
constexpr uint8_t kHIDRequestGetReport = 0x01;
constexpr uint8_t kHIDRequestSetReport = 0x09;
constexpr uint16_t kHIDFeatureReportID0 = 0x0300; // wValue: report type Feature (3), report ID 0

// The OTP interface's top-level collection is Generic Desktop / Keyboard.
// The FIDO interface (usage page 0xF1D0) is deliberately not selected.
constexpr uint32_t kHIDUsagePageGenericDesktop = 0x01;
constexpr uint32_t kHIDUsageKeyboard = 0x06;

constexpr size_t kMaximumHIDInterfaces = 16;
constexpr uint16_t kMaximumReportDescriptorLength = 4096;
constexpr size_t kLoggedReportDescriptorBytes = 64;

constexpr uint8_t RequestType(uint8_t direction, uint8_t type, uint8_t recipient)
{
    return static_cast<uint8_t>(direction | type | recipient);
}

constexpr uint8_t kStandardDeviceIn = RequestType(
    kIOUSBDeviceRequestDirectionIn, kIOUSBDeviceRequestTypeStandard, kIOUSBDeviceRequestRecipientDevice);
constexpr uint8_t kStandardInterfaceIn = RequestType(
    kIOUSBDeviceRequestDirectionIn, kIOUSBDeviceRequestTypeStandard, kIOUSBDeviceRequestRecipientInterface);
constexpr uint8_t kClassInterfaceIn = RequestType(
    kIOUSBDeviceRequestDirectionIn, kIOUSBDeviceRequestTypeClass, kIOUSBDeviceRequestRecipientInterface);
constexpr uint8_t kClassInterfaceOut = RequestType(
    kIOUSBDeviceRequestDirectionOut, kIOUSBDeviceRequestTypeClass, kIOUSBDeviceRequestRecipientInterface);

struct HIDInterface {
    uint8_t number;
    uint16_t reportDescriptorLength;
};

// MARK: - Helpers

// Writes a line to the system log and appends it to the bounded log that the
// app reads through the user client. Lines that no longer fit are dropped.
__attribute__((format(printf, 2, 3)))
void Log(YubiKeyUSBDriver_IVars* ivars, const char* format, ...)
{
    char line[512] = {};
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(line, sizeof(line), format, arguments);
    va_end(arguments);
    os_log(OS_LOG_DEFAULT, "YubiKeyUSBPoC - %{public}s", line);

    char* log = ivars->info.driverLog;
    const size_t capacity = sizeof(ivars->info.driverLog);
    const size_t used = strnlen(log, capacity);
    if (used >= capacity - 2) return;
    snprintf(log + used, capacity - used, "%s%s", used == 0 ? "" : "\n", line);
}

void FormatHex(const uint8_t* bytes, size_t count, char* output, size_t capacity)
{
    output[0] = '\0';
    for (size_t index = 0; index < count && (index + 1) * 2 < capacity; ++index) {
        snprintf(output + index * 2, 3, "%02x", bytes[index]);
    }
}

uint16_t ReadLE16(const uint8_t* bytes)
{
    return static_cast<uint16_t>(bytes[0] | (static_cast<uint16_t>(bytes[1]) << 8));
}

// Returns the usage page and usage in effect at the first Collection item of
// a HID report descriptor. They identify the interface's top-level collection.
void FindTopLevelUsage(const uint8_t* bytes, size_t length, uint32_t* usagePage, uint32_t* usage)
{
    constexpr uint8_t kLongItemPrefix = 0xfe;
    constexpr uint8_t kItemTypeMain = 0;
    constexpr uint8_t kItemTypeGlobal = 1;
    constexpr uint8_t kItemTypeLocal = 2;
    constexpr uint8_t kMainTagCollection = 0x0a;
    constexpr uint8_t kGlobalTagUsagePage = 0x00;
    constexpr uint8_t kLocalTagUsage = 0x00;

    *usagePage = 0;
    *usage = 0;
    uint32_t currentPage = 0;
    uint32_t currentUsage = 0;

    for (size_t offset = 0; offset < length;) {
        const uint8_t prefix = bytes[offset++];
        if (prefix == kLongItemPrefix) {
            // bDataSize and bLongItemTag follow, then the data.
            if (offset + 2 > length) return;
            offset += 2 + bytes[offset];
            continue;
        }

        const uint8_t sizeCode = prefix & 0x03;
        const size_t dataSize = sizeCode == 3 ? 4 : sizeCode;
        const uint8_t type = (prefix >> 2) & 0x03;
        const uint8_t tag = prefix >> 4;
        if (offset + dataSize > length) return;

        uint32_t value = 0;
        for (size_t index = 0; index < dataSize; ++index) {
            value |= static_cast<uint32_t>(bytes[offset + index]) << (8 * index);
        }
        offset += dataSize;

        if (type == kItemTypeGlobal && tag == kGlobalTagUsagePage) currentPage = value;
        if (type == kItemTypeLocal && tag == kLocalTagUsage) currentUsage = value;
        if (type == kItemTypeMain && tag == kMainTagCollection) {
            *usagePage = currentPage;
            *usage = currentUsage;
            return;
        }
    }
}

// Copies a USB string descriptor as printable ASCII; other characters become '?'.
void CopyUSBString(IOUSBHostDevice* device, uint8_t index, char* output, size_t capacity)
{
    if (index == 0 || capacity == 0) return;

    uint16_t languageID = kEnglishLanguageID;
    if (const IOUSBStringDescriptor* languages = device->CopyStringDescriptor(0, 0)) {
        if (languages->bLength >= 4) languageID = ReadLE16(reinterpret_cast<const uint8_t*>(languages) + 2);
        IOUSBHostFreeDescriptor(languages);
    }

    const IOUSBStringDescriptor* descriptor = device->CopyStringDescriptor(index, languageID);
    if (descriptor == nullptr) return;
    const uint8_t* raw = reinterpret_cast<const uint8_t*>(descriptor);
    const size_t characters = descriptor->bLength >= 2 ? (descriptor->bLength - 2) / 2 : 0;
    const size_t count = characters < capacity - 1 ? characters : capacity - 1;
    for (size_t character = 0; character < count; ++character) {
        const uint8_t low = raw[2 + character * 2];
        const uint8_t high = raw[3 + character * 2];
        output[character] = high == 0 && low >= 0x20 && low < 0x7f ? static_cast<char>(low) : '?';
    }
    output[count] = '\0';
    IOUSBHostFreeDescriptor(descriptor);
}

// Performs a control request on endpoint zero. Device-to-host requests copy
// the received bytes into data; host-to-device requests send data.
kern_return_t ControlRequest(
    IOUSBHostDevice* device,
    IOService* owner,
    uint8_t requestType,
    uint8_t request,
    uint16_t value,
    uint16_t index,
    uint8_t* data,
    uint16_t length,
    uint16_t* transferred)
{
    *transferred = 0;
    IOBufferMemoryDescriptor* buffer = nullptr;
    kern_return_t result = device->CreateIOBuffer(kIOMemoryDirectionInOut, length, &buffer);
    if (result != kIOReturnSuccess) return result;
    if (buffer == nullptr) return kIOReturnNoMemory;

    IOAddressSegment range = {};
    result = buffer->SetLength(length);
    if (result == kIOReturnSuccess) result = buffer->GetAddressRange(&range);
    if (result == kIOReturnSuccess && (range.address == 0 || range.length < length)) result = kIOReturnNoMemory;

    const bool isDeviceToHost =
        (requestType & kIOUSBDeviceRequestDirectionMask) == kIOUSBDeviceRequestDirectionIn;
    void* bufferBytes = reinterpret_cast<void*>(range.address);
    if (result == kIOReturnSuccess) {
        if (isDeviceToHost) memset(bufferBytes, 0, length);
        else memcpy(bufferBytes, data, length);
        result = device->DeviceRequest(
            owner, requestType, request, value, index, length, buffer, transferred, kControlTimeoutMS);
    }
    if (result == kIOReturnSuccess && isDeviceToHost) {
        memcpy(data, bufferBytes, *transferred < length ? *transferred : length);
    }
    OSSafeReleaseNULL(buffer);
    return result;
}

// MARK: - Startup steps

void OpenDevice(IOService* owner, YubiKeyUSBDriver_IVars* ivars)
{
    const kern_return_t result = ivars->device->Open(owner, 0, 0);
    ivars->info.deviceOpenResult = result;
    ivars->deviceIsOpen = result == kIOReturnSuccess;
    if (ivars->deviceIsOpen) {
        Log(ivars, "USB device opened");
    } else {
        Log(ivars, "USB open failure: IOReturn=0x%08x", result);
    }
}

void CloseDevice(IOService* owner, YubiKeyUSBDriver_IVars* ivars)
{
    if (!ivars->deviceIsOpen) return;
    ivars->device->Close(owner, 0);
    ivars->deviceIsOpen = false;
}

void ReadDeviceDescriptor(YubiKeyUSBDriver_IVars* ivars)
{
    const IOUSBDeviceDescriptor* descriptor = ivars->device->CopyDeviceDescriptor();
    if (descriptor == nullptr) {
        Log(ivars, "CopyDeviceDescriptor returned null");
        return;
    }
    YKUSBDeviceInfo& info = ivars->info;
    info.vendorID = USBToHost16(descriptor->idVendor);
    info.productID = USBToHost16(descriptor->idProduct);
    CopyUSBString(ivars->device, descriptor->iProduct, info.product, sizeof(info.product));
    Log(ivars,
        "device descriptor: VID=0x%04x PID=0x%04x bcdDevice=0x%04x class=%u/%u/%u configurations=%u product=%s",
        info.vendorID,
        info.productID,
        USBToHost16(descriptor->bcdDevice),
        descriptor->bDeviceClass,
        descriptor->bDeviceSubClass,
        descriptor->bDeviceProtocol,
        descriptor->bNumConfigurations,
        info.product[0] != '\0' ? info.product : "unavailable");
    IOUSBHostFreeDescriptor(descriptor);
}

// Records the value of configuration 0 and each of its HID interfaces
// (alternate setting 0) with the length of the interface's report descriptor.
size_t ReadConfigurationDescriptor(YubiKeyUSBDriver_IVars* ivars, HIDInterface* interfaces, size_t capacity)
{
    const IOUSBConfigurationDescriptor* configuration =
        ivars->device->CopyConfigurationDescriptor(static_cast<uint8_t>(0));
    if (configuration == nullptr) {
        Log(ivars, "CopyConfigurationDescriptor(0) returned null");
        return 0;
    }
    const uint16_t totalLength = USBToHost16(configuration->wTotalLength);
    ivars->info.configurationValue = configuration->bConfigurationValue;
    Log(ivars, "configuration: value=%u interfaces=%u totalLength=%u",
        configuration->bConfigurationValue, configuration->bNumInterfaces, totalLength);

    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(configuration);
    size_t count = 0;
    HIDInterface* current = nullptr;
    for (size_t offset = 0; offset + 2 <= totalLength;) {
        const uint8_t length = bytes[offset];
        const uint8_t type = bytes[offset + 1];
        if (length < 2 || offset + length > totalLength) {
            Log(ivars, "malformed descriptor at offset=%zu length=%u", offset, length);
            break;
        }
        os_log(OS_LOG_DEFAULT, "YubiKeyUSBPoC - descriptor offset=%zu type=0x%02x length=%u", offset, type, length);

        if (type == kIOUSBDescriptorTypeInterface && length >= sizeof(IOUSBInterfaceDescriptor)) {
            const auto* interface = reinterpret_cast<const IOUSBInterfaceDescriptor*>(bytes + offset);
            Log(ivars, "interface %u alt=%u class=0x%02x subclass=0x%02x protocol=0x%02x endpoints=%u",
                interface->bInterfaceNumber,
                interface->bAlternateSetting,
                interface->bInterfaceClass,
                interface->bInterfaceSubClass,
                interface->bInterfaceProtocol,
                interface->bNumEndpoints);
            current = nullptr;
            if (interface->bInterfaceClass == kUSBInterfaceClassHID &&
                interface->bAlternateSetting == 0 && count < capacity) {
                current = &interfaces[count++];
                *current = { interface->bInterfaceNumber, 0 };
            }
        } else if (type == kHIDDescriptorType && length >= kHIDDescriptorMinimumLength && current != nullptr) {
            // bDescriptorType and wDescriptorLength of the first class descriptor.
            if (bytes[offset + 6] == kHIDReportDescriptorType) {
                current->reportDescriptorLength = ReadLE16(bytes + offset + 7);
                Log(ivars, "HID interface %u report descriptor length=%u",
                    current->number, current->reportDescriptorLength);
            }
        } else if (type == kIOUSBDescriptorTypeEndpoint && length >= sizeof(IOUSBEndpointDescriptor)) {
            const auto* endpoint = reinterpret_cast<const IOUSBEndpointDescriptor*>(bytes + offset);
            Log(ivars, "endpoint address=0x%02x attributes=0x%02x maxPacket=%u interval=%u",
                endpoint->bEndpointAddress,
                endpoint->bmAttributes,
                USBToHost16(endpoint->wMaxPacketSize),
                endpoint->bInterval);
        }
        offset += length;
    }
    IOUSBHostFreeDescriptor(configuration);
    return count;
}

kern_return_t ReadActiveConfiguration(IOService* owner, YubiKeyUSBDriver_IVars* ivars, uint8_t* configurationValue)
{
    uint16_t transferred = 0;
    const kern_return_t result = ControlRequest(
        ivars->device, owner, kStandardDeviceIn, kIOUSBDeviceRequestGetConfiguration,
        0, 0, configurationValue, 1, &transferred);
    if (result == kIOReturnSuccess && transferred != 1) return kIOReturnUnderrun;
    return result;
}

// Selects the device's configuration unless it is already active. A matched
// device can still be unconfigured (configuration 0), and Feature reports then
// fail. Child interfaces are not matched, so the system's HID, FIDO, and CCID
// drivers stay detached while this driver owns the device.
kern_return_t ActivateConfiguration(IOService* owner, YubiKeyUSBDriver_IVars* ivars)
{
    const uint8_t expected = ivars->info.configurationValue;
    uint8_t active = 0;
    kern_return_t result = ReadActiveConfiguration(owner, ivars, &active);
    Log(ivars, "GET_CONFIGURATION result=0x%08x active=%u expected=%u", result, active, expected);
    if (result != kIOReturnSuccess || active == expected) return result;

    // Select the configuration for this USB session.
    result = ivars->device->SetConfiguration(expected, false);
    Log(ivars, "SET_CONFIGURATION value=%u matchInterfaces=false result=0x%08x", expected, result);
    if (result != kIOReturnSuccess) return result;

    result = ReadActiveConfiguration(owner, ivars, &active);
    Log(ivars, "GET_CONFIGURATION after selection result=0x%08x active=%u", result, active);
    if (result == kIOReturnSuccess && active != expected) result = kIOReturnNotReady;
    return result;
}

// Reads each HID interface's report descriptor and selects the first whose
// top-level collection is Generic Desktop / Keyboard: the OTP interface.
void SelectOTPInterface(IOService* owner, YubiKeyUSBDriver_IVars* ivars, const HIDInterface* interfaces, size_t count)
{
    for (size_t index = 0; index < count; ++index) {
        const HIDInterface& interface = interfaces[index];
        if (interface.reportDescriptorLength == 0 || interface.reportDescriptorLength > kMaximumReportDescriptorLength) {
            Log(ivars, "HID interface %u has unusable report descriptor length %u",
                interface.number, interface.reportDescriptorLength);
            continue;
        }

        uint8_t descriptor[kMaximumReportDescriptorLength] = {};
        const uint16_t wValue = static_cast<uint16_t>(kHIDReportDescriptorType << 8);
        uint16_t transferred = 0;
        const kern_return_t result = ControlRequest(
            ivars->device, owner, kStandardInterfaceIn, kIOUSBDeviceRequestGetDescriptor,
            wValue, interface.number, descriptor, interface.reportDescriptorLength, &transferred);
        Log(ivars,
            "GET_DESCRIPTOR(report) bmRequestType=0x%02x bRequest=0x%02x wValue=0x%04x wIndex=%u wLength=%u IOReturn=0x%08x bytes=%u",
            kStandardInterfaceIn, kIOUSBDeviceRequestGetDescriptor, wValue,
            interface.number, interface.reportDescriptorLength, result, transferred);
        if (result != kIOReturnSuccess || transferred == 0) continue;

        char hex[2 * kLoggedReportDescriptorBytes + 1];
        FormatHex(descriptor, transferred, hex, sizeof(hex));
        Log(ivars, "HID report descriptor interface %u bytes=%s%s",
            interface.number, hex, transferred > kLoggedReportDescriptorBytes ? "..." : "");

        uint32_t usagePage = 0;
        uint32_t usage = 0;
        FindTopLevelUsage(descriptor, transferred, &usagePage, &usage);
        Log(ivars, "HID interface %u top-level usage page=0x%x usage=0x%x", interface.number, usagePage, usage);
        if (usagePage == kHIDUsagePageGenericDesktop && usage == kHIDUsageKeyboard &&
            ivars->info.otpInterfaceNumber == kYKUSBNoInterface) {
            ivars->info.otpInterfaceNumber = interface.number;
            Log(ivars, "OTP interface selected: %u (Generic Desktop / Keyboard usage)", interface.number);
        }
    }
}

// MARK: - Feature reports

kern_return_t TransferFeatureReport(
    IOService* owner,
    YubiKeyUSBDriver_IVars* ivars,
    bool isRead,
    uint8_t report[kYKUSBFeatureReportSize])
{
    if (!ivars->deviceIsOpen) return kIOReturnNotOpen;
    if (ivars->configurationResult != kIOReturnSuccess) return ivars->configurationResult;
    if (ivars->info.otpInterfaceNumber == kYKUSBNoInterface) return kIOReturnNotFound;

    const char* name = isRead ? "GET" : "SET";
    const uint8_t requestType = isRead ? kClassInterfaceIn : kClassInterfaceOut;
    const uint8_t request = isRead ? kHIDRequestGetReport : kHIDRequestSetReport;
    uint16_t transferred = 0;
    kern_return_t result = ControlRequest(
        ivars->device, owner, requestType, request, kHIDFeatureReportID0,
        ivars->info.otpInterfaceNumber, report, kYKUSBFeatureReportSize, &transferred);
    Log(ivars,
        "%s_REPORT bmRequestType=0x%02x bRequest=0x%02x wValue=0x%04x wIndex=%u wLength=%u IOReturn=0x%08x bytes=%u",
        name, requestType, request, kHIDFeatureReportID0, ivars->info.otpInterfaceNumber,
        kYKUSBFeatureReportSize, result, transferred);
    if (result == kIOReturnSuccess && transferred != kYKUSBFeatureReportSize) result = kIOReturnUnderrun;
    return result;
}

} // namespace

// MARK: - YubiKeyUSBDriver

bool YubiKeyUSBDriver::init(void)
{
    if (!super::init()) return false;
    ivars = IONewZero(YubiKeyUSBDriver_IVars, 1);
    if (ivars == nullptr) return false;
    ivars->configurationResult = kIOReturnNotReady;
    ivars->info.abiVersion = kYKUSBDriverABIVersion;
    ivars->info.deviceOpenResult = kIOReturnNotOpen;
    ivars->info.otpInterfaceNumber = kYKUSBNoInterface;
    return true;
}

void YubiKeyUSBDriver::free(void)
{
    if (ivars != nullptr) {
        OSSafeReleaseNULL(ivars->device);
        IOSafeDeleteNULL(ivars, YubiKeyUSBDriver_IVars, 1);
    }
    super::free();
}

kern_return_t YubiKeyUSBDriver::Start_Impl(IOService* provider)
{
    kern_return_t result = Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;

    // The build time shows which DEXT build is running: iPadOS keeps a loaded
    // driver until the YubiKey is reconnected.
    Log(ivars, "driver starting; build " __DATE__ " " __TIME__);

    ivars->device = OSDynamicCast(IOUSBHostDevice, provider);
    if (ivars->device == nullptr) {
        Log(ivars, "provider is not an IOUSBHostDevice");
        return kIOReturnBadArgument;
    }
    ivars->device->retain();

    // Failures below are logged rather than fatal: the service still registers
    // so that the app can read the log and show what went wrong.
    OpenDevice(this, ivars);
    ReadDeviceDescriptor(ivars);
    if (ivars->info.vendorID != kYubicoVendorID) {
        Log(ivars, "refusing non-Yubico VID 0x%04x", ivars->info.vendorID);
        CloseDevice(this, ivars);
        return kIOReturnUnsupported;
    }

    HIDInterface hidInterfaces[kMaximumHIDInterfaces] = {};
    const size_t hidInterfaceCount = ReadConfigurationDescriptor(ivars, hidInterfaces, kMaximumHIDInterfaces);
    if (ivars->deviceIsOpen && ivars->info.configurationValue != 0) {
        ivars->configurationResult = ActivateConfiguration(this, ivars);
    }
    // Descriptors can be read without an active configuration; Feature reports cannot.
    if (ivars->deviceIsOpen && ivars->configurationResult == kIOReturnSuccess) {
        SelectOTPInterface(this, ivars, hidInterfaces, hidInterfaceCount);
    }
    if (ivars->info.otpInterfaceNumber == kYKUSBNoInterface) {
        Log(ivars, "OTP interface not found; FIDO usage 0xf1d0/1 is intentionally rejected");
    }

    Log(ivars, "registering service");
    result = RegisterService();
    Log(ivars, "RegisterService result=0x%08x", result);
    return result;
}

kern_return_t YubiKeyUSBDriver::Stop_Impl(IOService* provider)
{
    Log(ivars, "driver stopping");
    CloseDevice(this, ivars);
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t YubiKeyUSBDriver::NewUserClient_Impl(uint32_t type, IOUserClient** userClient)
{
    IOService* client = nullptr;
    kern_return_t result = Create(this, "UserClientProperties", &client);
    if (result != kIOReturnSuccess) return result;
    *userClient = OSDynamicCast(YubiKeyUSBDriverUserClient, client);
    if (*userClient == nullptr) {
        client->release();
        return kIOReturnError;
    }
    Log(ivars, "user client opened (type=%u)", type);
    return kIOReturnSuccess;
}

kern_return_t YubiKeyUSBDriver::CopyDeviceInfo(YKUSBDeviceInfo* output)
{
    if (output == nullptr) return kIOReturnBadArgument;
    memcpy(output, &ivars->info, sizeof(*output));
    return kIOReturnSuccess;
}

kern_return_t YubiKeyUSBDriver::GetFeatureReport(uint8_t output[kYKUSBFeatureReportSize])
{
    return TransferFeatureReport(this, ivars, true, output);
}

kern_return_t YubiKeyUSBDriver::SetFeatureReport(const uint8_t input[kYKUSBFeatureReportSize])
{
    // Raw OTP Feature report transport; command policy belongs to the client.
    uint8_t report[kYKUSBFeatureReportSize] = {};
    memcpy(report, input, sizeof(report));
    return TransferFeatureReport(this, ivars, false, report);
}
