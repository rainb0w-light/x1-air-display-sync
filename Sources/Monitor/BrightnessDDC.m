@import Foundation;
@import IOKit;

#include "BrightnessDDC.h"
#include "ioregistry.h"
#include "i2c.h"
#include <unistd.h>

uint32_t displayIDForSerial(uint32_t serial) {
    if (serial == 0) {
        return kCGNullDirectDisplay;
    }

    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess) {
        return kCGNullDirectDisplay;
    }

    CGDirectDisplayID match = kCGNullDirectDisplay;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID id = ids[i];
        if (CGDisplayVendorNumber(id) != 0x312b || CGDisplaySerialNumber(id) != serial) {
            continue;
        }
        if (match != kCGNullDirectDisplay) {
            return kCGNullDirectDisplay;
        }
        match = id;
    }
    return match;
}

uint32_t referenceDisplayID(uint32_t upper, uint32_t lower) {
    if (upper == kCGNullDirectDisplay && lower == kCGNullDirectDisplay) {
        return kCGNullDirectDisplay;
    }
    CGDirectDisplayID main = CGMainDisplayID();
    if (main != upper && main != lower) {
        return main;
    }

    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess) {
        return kCGNullDirectDisplay;
    }

    CGDirectDisplayID reference = kCGNullDirectDisplay;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID id = ids[i];
        if (id != upper && id != lower &&
            (reference == kCGNullDirectDisplay || CGDisplayBounds(id).origin.x < CGDisplayBounds(reference).origin.x)) {
            reference = id;
        }
    }
    return reference;
}

static DDCTransport brightnessTransport(CGDirectDisplayID id) {
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(id);
    if (!info) {
        return (DDCTransport){0};
    }
    CFStringRef location = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    io_service_t adapter = location
        ? IORegistryEntryCopyFromPath(kIOMainPortDefault, location)
        : MACH_PORT_NULL;
    CFRelease(info);
    if (adapter == MACH_PORT_NULL) {
        return (DDCTransport){0};
    }

    DisplayInfos display = {.id = id, .adapter = adapter};
    DDCTransport transport = getDisplayDDCTransport(&display);
    IOObjectRelease(adapter);
    return transport;
}

static bool validBrightnessReply(const UInt8 reply[11], BrightnessReading *reading) {
    if (reply[0] != 0x6e || reply[1] != 0x88 || reply[2] != 0x02 ||
        reply[3] != 0 || reply[4] != LUMINANCE) {
        return false;
    }

    UInt8 checksum = 0x50;
    for (int i = 0; i < 11; i++) {
        checksum ^= reply[i];
    }
    int maximum = (reply[6] << 8) | reply[7];
    int current = (reply[8] << 8) | reply[9];
    if (checksum != 0 || maximum <= 0 || current > maximum) {
        return false;
    }

    *reading = (BrightnessReading){.current = current, .maximum = maximum};
    return true;
}

static bool queryBrightness(DDCTransport transport, BrightnessReading *reading) {
    DDCPacket request = createDDCPacket(LUMINANCE);
    prepareDDCRead(&request);
    for (int attempt = 0; attempt < 3; attempt++) {
        UInt8 reply[11] = {0};
        IOReturn sent = IOAVServiceWriteI2C(transport.service, transport.chipAddress,
                                           request.inputAddr, request.data, 4);
        usleep(65000);
        if (sent == KERN_SUCCESS &&
            IOAVServiceReadI2C(transport.service, transport.chipAddress, 0,
                               reply, sizeof(reply)) == KERN_SUCCESS &&
            validBrightnessReply(reply, reading)) {
            return true;
        }
    }
    return false;
}

int readBrightness(uint32_t id, BrightnessReading *reading) {
    if (id == kCGNullDirectDisplay) {
        return BrightnessMissing;
    }
    DDCTransport transport = brightnessTransport(id);
    if (!transport.service) {
        return BrightnessUnreadable;
    }

    bool success = queryBrightness(transport, reading);
    CFRelease(transport.service);
    return success ? BrightnessOK : BrightnessUnreadable;
}
