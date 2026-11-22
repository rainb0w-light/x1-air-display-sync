#ifndef BRIGHTNESS_HID_H
#define BRIGHTNESS_HID_H

#include "BrightnessDDC.h"

enum {
    PanelBrightness,
    PanelContrast,
    PanelSaturation,
    PanelHue,
    PanelColorPreset,
    PanelRGB,
    PanelPicturePreset,
    PanelDynamicContrast,
    PanelEyeComfort,
    PanelSettingCount
};

enum { PanelSettingLocked = 4, PanelPairAmbiguous = 5 };

typedef struct {
    int upper;
    int lower;
} PanelValues;

typedef struct {
    uint32_t upper;
    uint32_t lower;
} PanelDisplays;

typedef struct {
    uint32_t upper;
    uint32_t lower;
} PanelSerials;

int readPanelSerials(PanelSerials *serials);
int readPanelSettings(PanelValues values[PanelSettingCount], PanelDisplays *displays);
int syncPanelSetting(int setting, int value, PanelValues values[PanelSettingCount], PanelDisplays *displays);

#endif
