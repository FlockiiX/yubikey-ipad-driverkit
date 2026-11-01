// The user-client ABI shared by the driver extension and the app.
//
// Both sides compile this header. Bump kYKUSBDriverABIVersion whenever the
// layout of YKUSBDeviceInfo or the meaning of a selector changes.

#ifndef YKUSB_DRIVER_API_H
#define YKUSB_DRIVER_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    kYKUSBDriverABIVersion = 2,
    kYKUSBFeatureReportSize = 8,
    kYKUSBDriverLogSize = 2048,
    kYKUSBNoInterface = 0xff,
};

// External method selectors. Every method has a fixed structure size.
enum {
    kYKUSBMethodGetDeviceInfo = 0,    // output: YKUSBDeviceInfo
    kYKUSBMethodGetFeatureReport = 1, // output: one eight-byte Feature report
    kYKUSBMethodSetFeatureReport = 2, // input:  one eight-byte Feature report
    kYKUSBMethodCount = 3,
};

typedef struct {
    uint32_t abiVersion;
    int32_t deviceOpenResult;     // IOReturn of IOUSBHostDevice::Open
    uint16_t vendorID;
    uint16_t productID;
    uint8_t configurationValue;
    uint8_t otpInterfaceNumber;   // kYKUSBNoInterface if no OTP interface was found
    uint8_t reserved[2];
    char product[128];            // NUL-terminated ASCII
    char driverLog[kYKUSBDriverLogSize]; // NUL-terminated, newline-separated
} YKUSBDeviceInfo;

#ifdef __cplusplus
}
#endif

#endif /* YKUSB_DRIVER_API_H */
