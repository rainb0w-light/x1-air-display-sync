#ifndef BRIGHTNESS_DDC_H
#define BRIGHTNESS_DDC_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int current;
    int maximum;
} BrightnessReading;

enum {
    BrightnessOK = 0,
    BrightnessMissing = 1,
    BrightnessUnreadable = 2,
    BrightnessUnconfirmed = 3
};

int readBrightness(uint32_t displayID, BrightnessReading *reading);
uint32_t displayIDForSerial(uint32_t serial);
uint32_t referenceDisplayID(uint32_t upper, uint32_t lower);

#endif
