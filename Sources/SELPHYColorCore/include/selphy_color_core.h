#ifndef SELPHY_COLOR_CORE_H
#define SELPHY_COLOR_CORE_H

/*
 * SELPHY colour core: portable (no macOS APIs) conversion of RGB pixel buffers
 * from a source ICC profile to the device RGB values of the Farbenwerk CP1500
 * printer profile, plus the Lab/DeltaE helpers used to evaluate the result.
 *
 * Built on the vendored LittleCMS. Image decoding/encoding is deliberately
 * outside the core: it works on pixel buffers and ICC profile bytes only, so
 * it can be developed and tested on Linux and reused unchanged by the macOS app.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SELPHY_INTENT_PERCEPTUAL = 0,
    SELPHY_INTENT_RELATIVE_COLORIMETRIC = 1,
    SELPHY_INTENT_SATURATION = 2
} selphy_intent;

typedef enum {
    SELPHY_OK = 0,
    SELPHY_ERR_ARGUMENT = 1,
    SELPHY_ERR_SOURCE_PROFILE = 2,      /* source ICC data cannot be parsed */
    SELPHY_ERR_SOURCE_UNSUPPORTED = 3,  /* source profile is not an RGB profile */
    SELPHY_ERR_PRINTER_PROFILE = 4,     /* printer ICC data cannot be parsed */
    SELPHY_ERR_PRINTER_UNSUPPORTED = 5, /* not an RGB output profile with Lab PCS, or intent tables missing */
    SELPHY_ERR_TRANSFORM = 6,           /* transform could not be built */
    SELPHY_ERR_MEMORY = 7
} selphy_status;

typedef struct {
    selphy_intent intent;
    /* Requested black point compensation. See selphy_transform_effective_bpc():
       it is forced on for perceptual/saturation with ICC v4 printer profiles. */
    int black_point_compensation;
    /* Non-zero disables LittleCMS optimisation (slow; reference quality, used by tests). */
    int exact;
} selphy_options;

typedef struct selphy_transform selphy_transform;

/* Builds source -> printer-device-RGB. A NULL source_icc with size 0 means built-in sRGB. */
selphy_status selphy_transform_create(
    const uint8_t *source_icc, size_t source_icc_size,
    const uint8_t *printer_icc, size_t printer_icc_size,
    const selphy_options *options,
    selphy_transform **out_transform);

/* Whether black point compensation is really applied (documented LittleCMS rules:
   never for absolute colorimetric; always for perceptual/saturation with a v4 printer
   profile; otherwise as requested). Lets the UI disable a toggle that has no effect. */
int selphy_transform_effective_bpc(const selphy_transform *transform);

/* Pixel buffers are packed R,G,B with no padding. In and out may not overlap. */
void selphy_transform_apply_rgb16(const selphy_transform *transform,
                                  const uint16_t *input, uint16_t *output, size_t pixel_count);

/* 8-bit convenience: expands to 16 bit, converts, rounds once at the end. */
void selphy_transform_apply_rgb8(const selphy_transform *transform,
                                 const uint8_t *input, uint8_t *output, size_t pixel_count);

void selphy_transform_free(selphy_transform *transform);

/* Predicted appearance of device RGB sent to the printer: printer A2B table -> Lab (D50).
   rgb16 is packed R,G,B; lab_out receives L,a,b per pixel. */
selphy_status selphy_printer_predict_lab(
    const uint8_t *printer_icc, size_t printer_icc_size,
    selphy_intent intent,
    const uint16_t *rgb16, double *lab_out, size_t pixel_count);

/* Intended appearance of source RGB: source profile -> Lab (D50), relative colorimetric, no BPC. */
selphy_status selphy_source_to_lab(
    const uint8_t *source_icc, size_t source_icc_size,
    const uint16_t *rgb16, double *lab_out, size_t pixel_count);

/* CIEDE2000 between two Lab triples. */
double selphy_delta_e2000(const double lab1[3], const double lab2[3]);

const char *selphy_status_message(selphy_status status);

/* Encoded version of the linked LittleCMS (e.g. 2200 for 2.20). */
int selphy_lcms_version(void);

#ifdef __cplusplus
}
#endif

#endif
