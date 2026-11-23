#include "SELPHYICCReference.h"
#include <lcms2.h>
#include <math.h>

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



int selphy_lcms_inspect_black_points(
    const char *source_profile_path,
    const char *printer_profile_path,
    uint32_t rendering_intent,
    double *output_values
) {
    if (source_profile_path == NULL || printer_profile_path == NULL || output_values == NULL ||
        rendering_intent > INTENT_ABSOLUTE_COLORIMETRIC) {
        return 0;
    }
    cmsHPROFILE source_profile = cmsOpenProfileFromFile(source_profile_path, "r");
    if (source_profile == NULL) return 0;
    cmsHPROFILE printer_profile = cmsOpenProfileFromFile(printer_profile_path, "r");
    if (printer_profile == NULL) {
        cmsCloseProfile(source_profile);
        return 0;
    }

    cmsCIEXYZ source_black, destination_black;
    cmsBool source_ok = cmsDetectBlackPoint(&source_black, source_profile, rendering_intent, 0);
    cmsBool destination_ok = cmsDetectDestinationBlackPoint(&destination_black, printer_profile, rendering_intent, 0);
    if (!source_ok || !destination_ok) {
        cmsCloseProfile(printer_profile);
        cmsCloseProfile(source_profile);
        return 0;
    }

    cmsCIELab source_lab, destination_lab;
    cmsXYZ2Lab(cmsD50_XYZ(), &source_lab, &source_black);
    cmsXYZ2Lab(cmsD50_XYZ(), &destination_lab, &destination_black);
    output_values[0] = source_black.X;
    output_values[1] = source_black.Y;
    output_values[2] = source_black.Z;
    output_values[3] = source_lab.L;
    output_values[4] = destination_black.X;
    output_values[5] = destination_black.Y;
    output_values[6] = destination_black.Z;
    output_values[7] = destination_lab.L;

    const cmsCIEXYZ *source_tag = (const cmsCIEXYZ *) cmsReadTag(source_profile, cmsSigMediaBlackPointTag);
    const cmsCIEXYZ *destination_tag = (const cmsCIEXYZ *) cmsReadTag(printer_profile, cmsSigMediaBlackPointTag);
    for (int channel = 0; channel < 3; channel++) {
        output_values[8 + channel] = source_tag == NULL ? NAN :
            (channel == 0 ? source_tag->X : channel == 1 ? source_tag->Y : source_tag->Z);
        output_values[11 + channel] = destination_tag == NULL ? NAN :
            (channel == 0 ? destination_tag->X : channel == 1 ? destination_tag->Y : destination_tag->Z);
    }
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
    // cmsCreateExtendedTransform accepts one BPC state per profile.
    // Keep both entries independently controllable for the diagnostic matrix;
    // their actual effect is verified against cmsCreateTransform in tests.
    cmsBool bpc[2] = {
        source_bpc ? TRUE : FALSE,
        destination_bpc ? TRUE : FALSE
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
