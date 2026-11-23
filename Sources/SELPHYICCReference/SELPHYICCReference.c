#include "SELPHYICCReference.h"
#include <lcms2.h>

int selphy_lcms_srgb_to_printer(
    const char *printer_profile_path,
    uint32_t rendering_intent,
    int black_point_compensation,
    const uint8_t *input_rgb,
    uint8_t *output_rgb,
    size_t pixel_count
) {
    if (printer_profile_path == NULL || input_rgb == NULL || output_rgb == NULL) {
        return 0;
    }
    if (rendering_intent > INTENT_ABSOLUTE_COLORIMETRIC) {
        return 0;
    }

    cmsHPROFILE source_profile = cmsCreate_sRGBProfile();
    if (source_profile == NULL) {
        return 0;
    }

    cmsHPROFILE printer_profile = cmsOpenProfileFromFile(printer_profile_path, "r");
    if (printer_profile == NULL) {
        cmsCloseProfile(source_profile);
        return 0;
    }

    cmsUInt32Number flags = black_point_compensation
        ? cmsFLAGS_BLACKPOINTCOMPENSATION
        : 0;

    cmsHTRANSFORM transform = cmsCreateTransform(
        source_profile,
        TYPE_RGB_8,
        printer_profile,
        TYPE_RGB_8,
        rendering_intent,
        flags
    );

    if (transform == NULL) {
        cmsCloseProfile(printer_profile);
        cmsCloseProfile(source_profile);
        return 0;
    }

    cmsDoTransform(transform, input_rgb, output_rgb, (cmsUInt32Number)pixel_count);

    cmsDeleteTransform(transform);
    cmsCloseProfile(printer_profile);
    cmsCloseProfile(source_profile);
    return 1;
}
