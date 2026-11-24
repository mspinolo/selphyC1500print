#include "selphy_color_core.h"
#include "lcms2.h"

#include <stdlib.h>
#include <string.h>

struct selphy_transform {
    cmsContext context;
    cmsHTRANSFORM transform;
    int effective_bpc;
};

enum { SELPHY_CHUNK_PIXELS = 4096 };

static cmsUInt32Number lcms_intent(selphy_intent intent) {
    switch (intent) {
        case SELPHY_INTENT_PERCEPTUAL: return INTENT_PERCEPTUAL;
        case SELPHY_INTENT_RELATIVE_COLORIMETRIC: return INTENT_RELATIVE_COLORIMETRIC;
        case SELPHY_INTENT_SATURATION: return INTENT_SATURATION;
    }
    return INTENT_PERCEPTUAL;
}

static int intent_is_valid(selphy_intent intent) {
    return intent == SELPHY_INTENT_PERCEPTUAL
        || intent == SELPHY_INTENT_RELATIVE_COLORIMETRIC
        || intent == SELPHY_INTENT_SATURATION;
}

const char *selphy_status_message(selphy_status status) {
    switch (status) {
        case SELPHY_OK: return "ok";
        case SELPHY_ERR_ARGUMENT: return "invalid argument";
        case SELPHY_ERR_SOURCE_PROFILE: return "source ICC profile cannot be read";
        case SELPHY_ERR_SOURCE_UNSUPPORTED: return "source profile is not an RGB profile";
        case SELPHY_ERR_PRINTER_PROFILE: return "printer ICC profile cannot be read";
        case SELPHY_ERR_PRINTER_UNSUPPORTED: return "printer profile is not an RGB output profile with Lab PCS and the requested intent tables";
        case SELPHY_ERR_TRANSFORM: return "colour transform could not be created";
        case SELPHY_ERR_MEMORY: return "out of memory";
        case SELPHY_ERR_DISPLAY_PROFILE: return "display ICC profile cannot be read or is not an RGB profile";
    }
    return "unknown status";
}

int selphy_lcms_version(void) {
    return (int)cmsGetEncodedCMMversion();
}

/* The ICC header declares the profile size in its first four bytes (big endian).
   LittleCMS reads tags lazily, so a truncated profile can still build a transform
   silently; reject it up front. Printer profiles must match exactly; source profiles
   (often extracted from image metadata) may carry trailing padding. */
static int declared_size_ok(const uint8_t *icc, size_t size, int exact_match) {
    if (size < 132) return 0;
    uint32_t declared = ((uint32_t)icc[0] << 24) | ((uint32_t)icc[1] << 16) | ((uint32_t)icc[2] << 8) | icc[3];
    return exact_match ? declared == size : declared <= size;
}

/* Opens the source profile (built-in sRGB when no data is given). */
static selphy_status open_source(cmsContext ctx, const uint8_t *icc, size_t size, cmsHPROFILE *out) {
    *out = NULL;
    if (icc == NULL) {
        if (size != 0) return SELPHY_ERR_ARGUMENT;
        *out = cmsCreate_sRGBProfileTHR(ctx);
        return *out != NULL ? SELPHY_OK : SELPHY_ERR_MEMORY;
    }
    if (size == 0 || size > 0x7fffffffu) return SELPHY_ERR_ARGUMENT;
    if (!declared_size_ok(icc, size, 0)) return SELPHY_ERR_SOURCE_PROFILE;
    cmsHPROFILE profile = cmsOpenProfileFromMemTHR(ctx, icc, (cmsUInt32Number)size);
    if (profile == NULL) return SELPHY_ERR_SOURCE_PROFILE;
    if (cmsGetColorSpace(profile) != cmsSigRgbData) {
        cmsCloseProfile(profile);
        return SELPHY_ERR_SOURCE_UNSUPPORTED;
    }
    *out = profile;
    return SELPHY_OK;
}

static selphy_status open_printer(cmsContext ctx, const uint8_t *icc, size_t size,
                                  selphy_intent intent, cmsHPROFILE *out) {
    *out = NULL;
    if (icc == NULL || size == 0 || size > 0x7fffffffu) return SELPHY_ERR_ARGUMENT;
    if (!declared_size_ok(icc, size, 1)) return SELPHY_ERR_PRINTER_PROFILE;
    cmsHPROFILE profile = cmsOpenProfileFromMemTHR(ctx, icc, (cmsUInt32Number)size);
    if (profile == NULL) return SELPHY_ERR_PRINTER_PROFILE;
    if (cmsGetDeviceClass(profile) != cmsSigOutputClass
        || cmsGetColorSpace(profile) != cmsSigRgbData
        || cmsGetPCS(profile) != cmsSigLabData
        || !cmsIsIntentSupported(profile, lcms_intent(intent), LCMS_USED_AS_OUTPUT)
        || !cmsIsIntentSupported(profile, lcms_intent(intent), LCMS_USED_AS_INPUT)) {
        cmsCloseProfile(profile);
        return SELPHY_ERR_PRINTER_UNSUPPORTED;
    }
    *out = profile;
    return SELPHY_OK;
}

selphy_status selphy_transform_create(
    const uint8_t *source_icc, size_t source_icc_size,
    const uint8_t *printer_icc, size_t printer_icc_size,
    const selphy_options *options,
    selphy_transform **out_transform) {
    if (out_transform == NULL) return SELPHY_ERR_ARGUMENT;
    *out_transform = NULL;
    if (options == NULL || !intent_is_valid(options->intent)) return SELPHY_ERR_ARGUMENT;

    cmsContext ctx = cmsCreateContext(NULL, NULL);
    if (ctx == NULL) return SELPHY_ERR_MEMORY;

    cmsHPROFILE source = NULL, printer = NULL;
    selphy_status status = open_source(ctx, source_icc, source_icc_size, &source);
    if (status == SELPHY_OK) status = open_printer(ctx, printer_icc, printer_icc_size, options->intent, &printer);
    if (status != SELPHY_OK) {
        if (source) cmsCloseProfile(source);
        cmsDeleteContext(ctx);
        return status;
    }

    /* LittleCMS rules (cmscnvrt.c, _cmsLinkProfiles): BPC never applies to absolute
       colorimetric and is forced on for perceptual/saturation with a v4 profile.
       In a two-profile chain only BPC[1] (the printer) is effective. */
    int bpc = options->black_point_compensation ? 1 : 0;
    if (options->intent != SELPHY_INTENT_RELATIVE_COLORIMETRIC
        && cmsGetEncodedICCversion(printer) >= 0x4000000) {
        bpc = 1;
    }

    cmsHPROFILE profiles[2] = { source, printer };
    cmsBool bpcs[2] = { bpc ? TRUE : FALSE, bpc ? TRUE : FALSE };
    cmsUInt32Number intents[2] = { lcms_intent(options->intent), lcms_intent(options->intent) };
    cmsFloat64Number adaptation[2] = { 1.0, 1.0 };
    cmsUInt32Number flags = cmsFLAGS_NOCACHE
        | (options->exact ? cmsFLAGS_NOOPTIMIZE : cmsFLAGS_HIGHRESPRECALC);

    cmsHTRANSFORM transform = cmsCreateExtendedTransform(
        ctx, 2, profiles, bpcs, intents, adaptation, NULL, 0,
        TYPE_RGB_16, TYPE_RGB_16, flags);
    cmsCloseProfile(source);
    cmsCloseProfile(printer);
    if (transform == NULL) {
        cmsDeleteContext(ctx);
        return SELPHY_ERR_TRANSFORM;
    }

    selphy_transform *result = (selphy_transform *)calloc(1, sizeof(*result));
    if (result == NULL) {
        cmsDeleteTransform(transform);
        cmsDeleteContext(ctx);
        return SELPHY_ERR_MEMORY;
    }
    result->context = ctx;
    result->transform = transform;
    result->effective_bpc = bpc;
    *out_transform = result;
    return SELPHY_OK;
}

int selphy_transform_effective_bpc(const selphy_transform *transform) {
    return transform != NULL ? transform->effective_bpc : 0;
}

void selphy_transform_apply_rgb16(const selphy_transform *transform,
                                  const uint16_t *input, uint16_t *output, size_t pixel_count) {
    if (transform == NULL || input == NULL || output == NULL) return;
    size_t done = 0;
    while (done < pixel_count) {
        size_t n = pixel_count - done;
        if (n > (size_t)1 << 20) n = (size_t)1 << 20;
        cmsDoTransform(transform->transform, input + done * 3, output + done * 3, (cmsUInt32Number)n);
        done += n;
    }
}

void selphy_transform_apply_rgb8(const selphy_transform *transform,
                                 const uint8_t *input, uint8_t *output, size_t pixel_count) {
    if (transform == NULL || input == NULL || output == NULL) return;
    uint16_t in16[SELPHY_CHUNK_PIXELS * 3];
    uint16_t out16[SELPHY_CHUNK_PIXELS * 3];
    size_t done = 0;
    while (done < pixel_count) {
        size_t n = pixel_count - done;
        if (n > SELPHY_CHUNK_PIXELS) n = SELPHY_CHUNK_PIXELS;
        for (size_t i = 0; i < n * 3; i++) in16[i] = (uint16_t)(input[done * 3 + i] * 257u);
        cmsDoTransform(transform->transform, in16, out16, (cmsUInt32Number)n);
        for (size_t i = 0; i < n * 3; i++) {
            output[done * 3 + i] = (uint8_t)(((uint32_t)out16[i] * 255u + 32767u) / 65535u);
        }
        done += n;
    }
}

void selphy_transform_free(selphy_transform *transform) {
    if (transform == NULL) return;
    cmsDeleteTransform(transform->transform);
    cmsDeleteContext(transform->context);
    free(transform);
}

/* Shared helper: profile -> Lab (V2 encoding profile, so no forced BPC) in double precision. */
static selphy_status run_to_lab(cmsContext ctx, cmsHPROFILE profile, cmsUInt32Number intent,
                                const uint16_t *rgb16, double *lab_out, size_t pixel_count) {
    cmsHPROFILE lab = cmsCreateLab2ProfileTHR(ctx, NULL);
    if (lab == NULL) return SELPHY_ERR_MEMORY;
    cmsHPROFILE profiles[2] = { profile, lab };
    cmsBool bpcs[2] = { FALSE, FALSE };
    cmsUInt32Number intents[2] = { intent, intent };
    cmsFloat64Number adaptation[2] = { 1.0, 1.0 };
    cmsHTRANSFORM transform = cmsCreateExtendedTransform(
        ctx, 2, profiles, bpcs, intents, adaptation, NULL, 0,
        TYPE_RGB_16, TYPE_Lab_DBL, cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE);
    cmsCloseProfile(lab);
    if (transform == NULL) return SELPHY_ERR_TRANSFORM;
    size_t done = 0;
    while (done < pixel_count) {
        size_t n = pixel_count - done;
        if (n > (size_t)1 << 20) n = (size_t)1 << 20;
        cmsDoTransform(transform, rgb16 + done * 3, lab_out + done * 3, (cmsUInt32Number)n);
        done += n;
    }
    cmsDeleteTransform(transform);
    return SELPHY_OK;
}

selphy_status selphy_printer_predict_lab(
    const uint8_t *printer_icc, size_t printer_icc_size,
    selphy_intent intent,
    const uint16_t *rgb16, double *lab_out, size_t pixel_count) {
    if (rgb16 == NULL || lab_out == NULL || !intent_is_valid(intent)) return SELPHY_ERR_ARGUMENT;
    cmsContext ctx = cmsCreateContext(NULL, NULL);
    if (ctx == NULL) return SELPHY_ERR_MEMORY;
    cmsHPROFILE printer = NULL;
    selphy_status status = open_printer(ctx, printer_icc, printer_icc_size, intent, &printer);
    if (status == SELPHY_OK) {
        status = run_to_lab(ctx, printer, lcms_intent(intent), rgb16, lab_out, pixel_count);
        cmsCloseProfile(printer);
    }
    cmsDeleteContext(ctx);
    return status;
}

selphy_status selphy_source_to_lab(
    const uint8_t *source_icc, size_t source_icc_size,
    const uint16_t *rgb16, double *lab_out, size_t pixel_count) {
    if (rgb16 == NULL || lab_out == NULL) return SELPHY_ERR_ARGUMENT;
    cmsContext ctx = cmsCreateContext(NULL, NULL);
    if (ctx == NULL) return SELPHY_ERR_MEMORY;
    cmsHPROFILE source = NULL;
    selphy_status status = open_source(ctx, source_icc, source_icc_size, &source);
    if (status == SELPHY_OK) {
        status = run_to_lab(ctx, source, INTENT_RELATIVE_COLORIMETRIC, rgb16, lab_out, pixel_count);
        cmsCloseProfile(source);
    }
    cmsDeleteContext(ctx);
    return status;
}

double selphy_delta_e2000(const double lab1[3], const double lab2[3]) {
    cmsCIELab a = { lab1[0], lab1[1], lab1[2] };
    cmsCIELab b = { lab2[0], lab2[1], lab2[2] };
    return cmsCIE2000DeltaE(&a, &b, 1.0, 1.0, 1.0);
}


/* ---- Soft-proof preview ------------------------------------------------------------ */

struct selphy_preview {
    cmsContext context;
    cmsHTRANSFORM transform16;    /* printer device RGB (16 bit) -> display RGB (16 bit) */
    cmsHTRANSFORM transform_float; /* same chain in float, unclipped where the profile allows */
};

selphy_status selphy_preview_create(
    const uint8_t *printer_icc, size_t printer_icc_size,
    const uint8_t *display_icc, size_t display_icc_size,
    const selphy_preview_options *options,
    selphy_preview **out_preview) {
    if (out_preview == NULL) return SELPHY_ERR_ARGUMENT;
    *out_preview = NULL;
    if (options == NULL) return SELPHY_ERR_ARGUMENT;

    cmsContext ctx = cmsCreateContext(NULL, NULL);
    if (ctx == NULL) return SELPHY_ERR_MEMORY;

    cmsHPROFILE printer = NULL, display = NULL;
    selphy_status status = open_printer(ctx, printer_icc, printer_icc_size, SELPHY_INTENT_RELATIVE_COLORIMETRIC, &printer);
    if (status == SELPHY_OK) {
        status = open_source(ctx, display_icc, display_icc_size, &display);
        if (status == SELPHY_ERR_SOURCE_PROFILE || status == SELPHY_ERR_SOURCE_UNSUPPORTED) status = SELPHY_ERR_DISPLAY_PROFILE;
        /* A display profile describes a monitor or a working space; printer, link and abstract
           profiles are not meaningful here. */
        if (status == SELPHY_OK) {
            cmsProfileClassSignature cls = cmsGetDeviceClass(display);
            if (cls != cmsSigDisplayClass && cls != cmsSigColorSpaceClass) status = SELPHY_ERR_DISPLAY_PROFILE;
        }
    }
    if (status != SELPHY_OK) {
        if (printer) cmsCloseProfile(printer);
        if (display) cmsCloseProfile(display);
        cmsDeleteContext(ctx);
        return status;
    }

    cmsUInt32Number intent = options->simulate_paper_white ? INTENT_ABSOLUTE_COLORIMETRIC : INTENT_RELATIVE_COLORIMETRIC;
    /* BPC[i] acts between profile i-1 and i: the display entry is the one that matters here. */
    cmsBool bpc = (!options->simulate_paper_white && options->black_point_compensation) ? TRUE : FALSE;
    cmsHPROFILE profiles[2] = { printer, display };
    cmsBool bpcs[2] = { FALSE, bpc };
    cmsUInt32Number intents[2] = { intent, intent };
    cmsFloat64Number adaptation[2] = { 1.0, 1.0 };

    cmsHTRANSFORM t16 = cmsCreateExtendedTransform(
        ctx, 2, profiles, bpcs, intents, adaptation, NULL, 0,
        TYPE_RGB_16, TYPE_RGB_16, cmsFLAGS_NOCACHE | cmsFLAGS_HIGHRESPRECALC);
    cmsHTRANSFORM tf = cmsCreateExtendedTransform(
        ctx, 2, profiles, bpcs, intents, adaptation, NULL, 0,
        TYPE_RGB_FLT, TYPE_RGB_FLT, cmsFLAGS_NOCACHE | cmsFLAGS_NOOPTIMIZE);
    cmsCloseProfile(printer);
    cmsCloseProfile(display);

    selphy_preview *result = (t16 && tf) ? (selphy_preview *)calloc(1, sizeof(*result)) : NULL;
    if (result == NULL) {
        if (t16) cmsDeleteTransform(t16);
        if (tf) cmsDeleteTransform(tf);
        cmsDeleteContext(ctx);
        return (t16 && tf) ? SELPHY_ERR_MEMORY : SELPHY_ERR_TRANSFORM;
    }
    result->context = ctx;
    result->transform16 = t16;
    result->transform_float = tf;
    *out_preview = result;
    return SELPHY_OK;
}

void selphy_preview_apply_rgb8(const selphy_preview *preview,
                               const uint8_t *device_rgb, uint8_t *display_rgb, size_t pixel_count,
                               size_t *out_of_gamut_pixels) {
    if (out_of_gamut_pixels != NULL) *out_of_gamut_pixels = 0;
    if (preview == NULL || device_rgb == NULL || display_rgb == NULL) return;
    uint16_t in16[SELPHY_CHUNK_PIXELS * 3];
    uint16_t out16[SELPHY_CHUNK_PIXELS * 3];
    float inf[SELPHY_CHUNK_PIXELS * 3];
    float outf[SELPHY_CHUNK_PIXELS * 3];
    size_t done = 0, clipped = 0;
    while (done < pixel_count) {
        size_t n = pixel_count - done;
        if (n > SELPHY_CHUNK_PIXELS) n = SELPHY_CHUNK_PIXELS;
        for (size_t i = 0; i < n * 3; i++) in16[i] = (uint16_t)(device_rgb[done * 3 + i] * 257u);
        cmsDoTransform(preview->transform16, in16, out16, (cmsUInt32Number)n);
        for (size_t i = 0; i < n * 3; i++) {
            display_rgb[done * 3 + i] = (uint8_t)(((uint32_t)out16[i] * 255u + 32767u) / 65535u);
        }
        if (out_of_gamut_pixels != NULL) {
            for (size_t i = 0; i < n * 3; i++) inf[i] = (float)device_rgb[done * 3 + i] / 255.0f;
            cmsDoTransform(preview->transform_float, inf, outf, (cmsUInt32Number)n);
            /* A pixel is clipped if any channel would round outside 0..255. */
            const float low = -0.5f / 255.0f, high = 1.0f + 0.5f / 255.0f;
            for (size_t p = 0; p < n; p++) {
                const float *c = outf + p * 3;
                if (c[0] < low || c[0] > high || c[1] < low || c[1] > high || c[2] < low || c[2] > high) clipped++;
            }
        }
        done += n;
    }
    if (out_of_gamut_pixels != NULL) *out_of_gamut_pixels = clipped;
}

void selphy_preview_free(selphy_preview *preview) {
    if (preview == NULL) return;
    cmsDeleteTransform(preview->transform16);
    cmsDeleteTransform(preview->transform_float);
    cmsDeleteContext(preview->context);
    free(preview);
}
