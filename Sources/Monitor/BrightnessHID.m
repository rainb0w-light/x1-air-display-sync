@import Foundation;
#include <IOKit/hid/IOHIDLib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "BrightnessHID.h"

enum {
    OutputReport = 2,
    InputReport = 1,
    DeviceInfo = 0x04,
    PanelRole = 0x09,
    LowerPanel = 1,
    UpperPanel = 2,
    MenuRead = 0xee,
    MenuWrite = 0xef
};

typedef struct {
    IOHIDDeviceRef device;
    uint8_t buffer[64];
    uint8_t expected[4];
    size_t expectedLength;
    size_t expectedReplyLength;
    uint8_t response[22];
    size_t responseLength;
} PanelConnection;

typedef struct {
    PanelConnection upper;
    PanelConnection lower;
} PanelPair;

// The monitor encodes the reply length and each payload byte with a fixed XOR mask.
static const uint8_t replyMask[] = {
    0x57, 0x54, 0x80, 0x19, 0x19, 0xb6, 0x8d, 0x82, 0xe4, 0xc7, 0x57,
    0x35, 0x9c, 0x4d, 0x84, 0x10, 0xfc, 0x91, 0x75, 0x31, 0xee, 0x62
};

static void receivePanelReply(void *context, IOReturn status, void *sender, IOHIDReportType type,
                              uint32_t reportID, uint8_t *report, CFIndex length) {
    (void)sender;
    PanelConnection *connection = context;
    if (status != kIOReturnSuccess || type != kIOHIDReportTypeInput ||
        reportID != InputReport || length < 3 || report[0] != InputReport ||
        !report[1] || connection->responseLength) {
        return;
    }

    size_t decodedLength = report[1] ^ replyMask[0];
    if (decodedLength != connection->expectedReplyLength || decodedLength > sizeof(replyMask) ||
        decodedLength >= (size_t)length) {
        return;
    }
    uint8_t decoded[sizeof(replyMask)] = {InputReport};
    for (size_t i = 1; i < decodedLength; i++) {
        decoded[i] = report[i + 1] ^ replyMask[i];
    }
    if (memcmp(decoded, connection->expected, connection->expectedLength) == 0) {
        memcpy(connection->response, decoded, decodedLength);
        connection->responseLength = decodedLength;
    }
}

static IOReturn sendPanelCommand(PanelConnection *connection, const uint8_t *command, size_t length) {
    return IOHIDDeviceSetReport(connection->device, kIOHIDReportTypeOutput, OutputReport, command, length);
}

static bool queryPanel(PanelConnection *connection, const uint8_t *command, size_t commandLength,
                       const uint8_t *expected, size_t expectedLength, size_t replyLength) {
    connection->expectedLength = expectedLength;
    connection->expectedReplyLength = replyLength;
    memcpy(connection->expected, expected, expectedLength);

    for (int attempt = 0; attempt < 2; attempt++) {
        connection->responseLength = 0;
        if (sendPanelCommand(connection, command, commandLength) != kIOReturnSuccess) {
            continue;
        }
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 0.35;
        while (connection->responseLength == 0) {
            NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
            if (remaining <= 0) {
                break;
            }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining, true);
        }
        if (connection->responseLength == replyLength) {
            return true;
        }
    }
    return false;
}

static void openPanel(PanelConnection *connection, IOHIDDeviceRef device) {
    if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        return;
    }
    connection->device = device;
    IOHIDDeviceRegisterInputReportCallback(device, connection->buffer, sizeof(connection->buffer),
                                           receivePanelReply, connection);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
}

static void closePanel(PanelConnection *connection) {
    if (connection->device) {
        IOHIDDeviceUnscheduleFromRunLoop(connection->device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDDeviceRegisterInputReportCallback(connection->device, connection->buffer, sizeof(connection->buffer),
                                               NULL, NULL);
        IOHIDDeviceClose(connection->device, kIOHIDOptionsTypeNone);
        connection->device = NULL;
    }
}

static uint32_t readPanelSerial(PanelConnection *connection) {
    const uint8_t command[] = {OutputReport, DeviceInfo};
    const uint8_t expected[] = {InputReport, DeviceInfo, 'E', 'H'};
    if (!queryPanel(connection, command, sizeof(command), expected, sizeof(expected), 22)) {
        return 0;
    }
    const uint8_t *reply = connection->response;
    if (memcmp(reply + 2, "EHOMEWEI", 8) != 0 || strncasecmp((const char *)reply + 16, "X1 Air", 6) != 0) {
        return 0;
    }
    return (uint32_t)reply[10] | ((uint32_t)reply[11] << 8) |
        ((uint32_t)reply[12] << 16) | ((uint32_t)reply[13] << 24);
}

static uint8_t readPanelRole(PanelConnection *connection) {
    const uint8_t command[] = {OutputReport, PanelRole};
    const uint8_t expected[] = {InputReport, PanelRole};
    if (!queryPanel(connection, command, sizeof(command), expected, sizeof(expected), 4)) {
        return 0;
    }
    return connection->response[2];
}

static bool panelSupportsMenu(PanelConnection *connection) {
    const uint8_t command[] = {OutputReport, MenuRead};
    const uint8_t expected[] = {InputReport, MenuRead};
    return connection->device &&
        queryPanel(connection, command, sizeof(command), expected, sizeof(expected), 3) &&
        connection->response[2] == 1;
}

static int withPanelDevices(int (^operation)(IOHIDDeviceRef upper, IOHIDDeviceRef lower, PanelSerials serials)) {
    @autoreleasepool {
        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        if (!manager) {
            return BrightnessMissing;
        }
        NSDictionary *matching = @{ @kIOHIDVendorIDKey: @0x056a, @kIOHIDProductIDKey: @0x8191,
                                    @kIOHIDPrimaryUsagePageKey: @0xff00, @kIOHIDPrimaryUsageKey: @1 };
        IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)matching);
        CFSetRef devices = IOHIDManagerCopyDevices(manager);
        NSSet *candidates = (__bridge NSSet *)devices;

        IOHIDDeviceRef upper = NULL;
        IOHIDDeviceRef lower = NULL;
        uint32_t upperSerial = 0;
        uint32_t lowerSerial = 0;
        bool ambiguous = false;
        for (id device in candidates) {
            PanelConnection candidate = {0};
            openPanel(&candidate, (__bridge IOHIDDeviceRef)device);
            if (!candidate.device) {
                continue;
            }
            uint32_t serial = readPanelSerial(&candidate);
            uint8_t role = serial ? readPanelRole(&candidate) : 0;
            closePanel(&candidate);
            if (role == UpperPanel) {
                ambiguous |= upper != NULL;
                upper = (__bridge IOHIDDeviceRef)device;
                upperSerial = serial;
            } else if (role == LowerPanel) {
                ambiguous |= lower != NULL;
                lower = (__bridge IOHIDDeviceRef)device;
                lowerSerial = serial;
            }
        }

        ambiguous |= upperSerial != 0 && upperSerial == lowerSerial;
        int result = ambiguous ? PanelPairAmbiguous : operation(upper, lower, (PanelSerials){upperSerial, lowerSerial});
        if (devices) CFRelease(devices);
        CFRelease(manager);
        return result;
    }
}

int readPanelSerials(PanelSerials *serials) {
    *serials = (PanelSerials){0};
    return withPanelDevices(^int(IOHIDDeviceRef upper, IOHIDDeviceRef lower, PanelSerials found) {
        if (!upper || !lower) return BrightnessMissing;
        *serials = found;
        return BrightnessOK;
    });
}

static int withPanels(PanelDisplays *displays, int (^operation)(PanelPair *panels)) {
    *displays = (PanelDisplays){0};
    return withPanelDevices(^int(IOHIDDeviceRef upper, IOHIDDeviceRef lower, PanelSerials serials) {
        *displays = (PanelDisplays){displayIDForSerial(serials.upper), displayIDForSerial(serials.lower)};
        if (!displays->upper && !displays->lower) return BrightnessMissing;

        PanelPair panels = {0};
        if (upper) openPanel(&panels.upper, upper);
        if (lower) openPanel(&panels.lower, lower);
        if (!panelSupportsMenu(&panels.upper)) closePanel(&panels.upper);
        if (!panelSupportsMenu(&panels.lower)) closePanel(&panels.lower);
        int result = operation(&panels);
        closePanel(&panels.upper);
        closePanel(&panels.lower);
        return result;
    });
}

typedef struct {
    uint8_t page;
    uint8_t item;
    uint8_t replyLength;
    uint8_t valueOffset;
    uint8_t pageOffset;
    int maximum;
} MenuSetting;

static const MenuSetting settings[PanelSettingCount] = {
    [PanelBrightness]      = {1, 10, 5, 4, 13, 100},
    [PanelContrast]        = {1, 11, 5, 4, 14, 100},
    [PanelSaturation]      = {2,  3, 5, 4,  9, 100},
    [PanelHue]             = {2,  2, 5, 4,  8, 100},
    [PanelColorPreset]     = {2,  1, 8, 7,  7, 3},
    [PanelRGB]             = {2,  1, 8, 4,  4, 0x646464},
    [PanelPicturePreset]   = {1,  8, 5, 4, 11, 3},
    [PanelDynamicContrast] = {1,  3, 5, 4,  6, 1},
    [PanelEyeComfort]      = {3,  4, 5, 4,  8, 1},
};

static bool validValue(int setting, int value) {
    if (value < 0 || value > settings[setting].maximum) {
        return false;
    }
    return setting != PanelRGB || (((value >> 8) & 0xff) <= 100 && (value & 0xff) <= 100);
}

static int readValue(const uint8_t *valueBytes, int setting) {
    int value = setting == PanelRGB ? (valueBytes[0] << 16) | (valueBytes[1] << 8) | valueBytes[2] : valueBytes[0];
    return validValue(setting, value) ? value : -1;
}

static int readSetting(PanelConnection *connection, int setting) {
    if (!connection->device) {
        return -1;
    }
    MenuSetting address = settings[setting];
    const uint8_t command[] = {OutputReport, MenuRead, address.page, address.item};
    const uint8_t expected[] = {InputReport, MenuRead, address.page, address.item};
    if (!queryPanel(connection, command, sizeof(command), expected, sizeof(expected), address.replyLength)) {
        return -1;
    }

    return readValue(connection->response + address.valueOffset, setting);
}

static int writeSetting(PanelConnection *connection, int setting, int value) {
    MenuSetting address = settings[setting];
    uint8_t command[8] = {OutputReport, MenuWrite, address.page, address.item, (uint8_t)value};
    size_t length = 5;
    if (setting == PanelRGB) {
        command[4] = 4;
        command[5] = (uint8_t)(value >> 16);
        command[6] = (uint8_t)(value >> 8);
        command[7] = (uint8_t)value;
        length = 8;
    }

    int readback = -1;
    for (int attempt = 0; attempt < 2; attempt++) {
        if (sendPanelCommand(connection, command, length) == kIOReturnSuccess) {
            usleep(180000);
            readback = readSetting(connection, setting);
            if (readback == value) {
                break;
            }
        }
    }
    return readback;
}

static void clearSettings(PanelValues *values) {
    for (int i = 0; i < PanelSettingCount; i++) {
        values[i] = (PanelValues){-1, -1};
    }
}

static void readMenuPages(PanelConnection *connection, int *values) {
    for (int i = 0; i < PanelSettingCount; i++) {
        values[i] = -1;
    }
    if (!connection->device) {
        return;
    }

    const uint8_t pageLengths[] = {15, 10, 10};
    for (uint8_t page = 1; page <= sizeof(pageLengths); page++) {
        const uint8_t command[] = {OutputReport, MenuRead, page, 0xff};
        const uint8_t expected[] = {InputReport, MenuRead, page, 0xff};
        if (!queryPanel(connection, command, sizeof(command), expected, sizeof(expected), pageLengths[page - 1])) {
            continue;
        }
        for (int i = 0; i < PanelSettingCount; i++) {
            if (settings[i].page == page) {
                values[i] = readValue(connection->response + settings[i].pageOffset, i);
            }
        }
    }
}

static int readSettings(PanelPair *panels, PanelValues *values) {
    if (!panels->upper.device && !panels->lower.device) {
        return BrightnessMissing;
    }
    int upper[PanelSettingCount];
    int lower[PanelSettingCount];
    readMenuPages(&panels->upper, upper);
    readMenuPages(&panels->lower, lower);
    for (int i = 0; i < PanelSettingCount; i++) {
        values[i] = (PanelValues){upper[i], lower[i]};
    }
    return panels->upper.device && panels->lower.device ? BrightnessOK : BrightnessUnreadable;
}

static int syncSetting(PanelPair *panels, int setting, int target) {
    PanelValues previous = {readSetting(&panels->upper, setting), readSetting(&panels->lower, setting)};
    if (previous.upper < 0 || previous.lower < 0) {
        return BrightnessUnreadable;
    }
    if (setting == PanelRGB &&
        (readSetting(&panels->upper, PanelColorPreset) != 3 || readSetting(&panels->lower, PanelColorPreset) != 3)) {
        return PanelSettingLocked;
    }

    int upper = previous.upper;
    int lower = previous.lower;
    if (upper != target) {
        upper = writeSetting(&panels->upper, setting, target);
    }
    if (upper == target && lower != target) {
        lower = writeSetting(&panels->lower, setting, target);
    }
    if (upper == target && lower == target) {
        return BrightnessOK;
    }

    if (upper != previous.upper) {
        writeSetting(&panels->upper, setting, previous.upper);
    }
    if (lower != previous.lower) {
        writeSetting(&panels->lower, setting, previous.lower);
    }
    return BrightnessUnconfirmed;
}

int readPanelSettings(PanelValues values[PanelSettingCount], PanelDisplays *displays) {
    clearSettings(values);
    return withPanels(displays, ^int(PanelPair *panels) {
        return readSettings(panels, values);
    });
}

int syncPanelSetting(int setting, int value, PanelValues values[PanelSettingCount], PanelDisplays *displays) {
    clearSettings(values);
    *displays = (PanelDisplays){0};
    if (setting < 0 || setting >= PanelSettingCount || !validValue(setting, value)) {
        return BrightnessUnconfirmed;
    }
    return withPanels(displays, ^int(PanelPair *panels) {
        int status = syncSetting(panels, setting, value);
        readSettings(panels, values);
        if (status == BrightnessOK && (values[setting].upper != value || values[setting].lower != value)) {
            return BrightnessUnconfirmed;
        }
        return status;
    });
}
