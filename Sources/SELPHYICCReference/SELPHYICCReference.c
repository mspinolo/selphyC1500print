#include "SELPHYICCReference.h"
#include <lcms2.h>

int selphy_lcms_srgb_to_printer(
    const char *source_profile_path,
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

    cmsHPROFILE source_profile = source_profile_path != NULL
        ? cmsOpenProfileFromFile(source_profile_path, "r")
        : cmsCreate_sRGBProfile();
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


int selphy_lcms_srgb_to_printer_profile_bpc(
    const char *source_profile_path,
    const char *printer_profile_path,
    uint32_t rendering_intent,
    int source_bpc,
    int destination_bpc,
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

    cmsHPROFILE source_profile = source_profile_path != NULL
        ? cmsOpenProfileFromFile(source_profile_path, "r")
        : cmsCreate_sRGBProfile();
    if (source_profile == NULL) {
        return 0;
    }

    cmsHPROFILE printer_profile = cmsOpenProfileFromFile(printer_profile_path, "r");
    if (printer_profile == NULL) {
        cmsCloseProfile(source_profile);
        return 0;
    }

    cmsHPROFILE profiles[2] = { source_profile, printer_profile };
    // LittleCMS applies BPC at the PCS connection while processing the
    // output profile (profile index 1 in a two-profile transform). In the
    // current implementation this is BPC[1], not BPC[0]. Map the source
    // profile's ColorSync sequence option to that connection. The final
    // profile has no subsequent PCS connection, so destination_bpc cannot
    // represent a second independent BPC operation in this two-profile chain.
    cmsBool bpc[2] = {
        destination_bpc ? TRUE : FALSE,
        source_bpc ? TRUE : FALSE
    };
    cmsUInt32Number intents[2] = { rendering_intent, rendering_intent };
    cmsFloat64Number adaptation_states[2] = { 1.0, 1.0 };

    cmsHTRANSFORM transform = cmsCreateExtendedTransform(
        NULL,
        2,
        profiles,
        bpc,
        intents,
        adaptation_states,
        NULL,
        0,
        TYPE_RGB_8,
        TYPE_RGB_8,
        0
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
