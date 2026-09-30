#ifndef SENSORS_H
#define SENSORS_H

/// Temperatures in °C. A value < 0 means no matching sensor was found.
typedef struct {
    double cpu;      // average of CPU die / cluster sensors
    double gpu;      // average of GPU sensors
    double hottest;  // hottest SoC sensor (excludes battery, NAND, calibration)
    int count;       // number of sensors read
} SensorsTemps;

SensorsTemps sensors_read_temperatures(void);

/// Prints every HID temperature sensor to stdout (for debugging).
void sensors_dump(void);

#endif
