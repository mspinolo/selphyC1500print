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
    SELPHY_ERR_MEMORY = 7,
    SELPHY_ERR_DISPLAY_PROFILE = 8      /* display ICC data cannot be parsed or is not an RGB profile */
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

/*
 * Soft-proof preview: how device RGB values sent to the printer are expected to look,
 * shown on a display. The printer profile is used in its forward direction (A2B,
 * relative colorimetric tables: a physical appearance, independent of the rendering
 * intent used for the correction) and converted to the display profile.
 * This is a model-based simulation, not a print proof.
 */
typedef struct {
    /* 0: paper white is mapped to the display white (relative colorimetric).
       Non-zero: absolute colorimetric, the paper tint and brightness are simulated. */
    int simulate_paper_white;
    /* 0 shows the printer's real black level; non-zero stretches it to the display black.
       Ignored when simulate_paper_white is set. */
    int black_point_compensation;
} selphy_preview_options;

typedef struct selphy_preview selphy_preview;

/* A NULL display_icc with size 0 means built-in sRGB. */
selphy_status selphy_preview_create(
    const uint8_t *printer_icc, size_t printer_icc_size,
    const uint8_t *display_icc, size_t display_icc_size,
    const selphy_preview_options *options,
    selphy_preview **out_preview);

/* device_rgb: packed R,G,B 8-bit values as sent to the printer; display_rgb: packed R,G,B
   in the display profile. If out_of_gamut_pixels is not NULL it receives the number of pixels
   whose colour lies outside the display gamut and was therefore clipped (a float evaluation of
   the same chain; best effort for display profiles that clip in float). */
void selphy_preview_apply_rgb8(const selphy_preview *preview,
                               const uint8_t *device_rgb, uint8_t *display_rgb, size_t pixel_count,
                               size_t *out_of_gamut_pixels);

void selphy_preview_free(selphy_preview *preview);

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

/*
 * Per-photo checks. Compares, pixel by pixel, the appearance the photo should have (its sRGB
 * numbers read as sRGB, relative colorimetric, no BPC) with the appearance the printer is
 * predicted to produce for the corrected device values (printer A2B, relative colorimetric).
 * It is a model estimate, not a measurement of a print. With perceptual rendering or BPC the
 * differences include the intended tone compression.
 */
#define SELPHY_DE_NOT_REPRODUCIBLE 3.0   /* dE00 above which a pixel counts as not reproduced */
#define SELPHY_NEUTRAL_CHROMA 3.0        /* intended C* below which a pixel counts as neutral */
#define SELPHY_NEUTRAL_IMAGE_SHARE 0.9   /* neutral pixel share from which a photo counts as black and white */

typedef struct {
    double mean_de, p95_de, max_de;      /* dE00 between intended and predicted appearance */
    double share_not_reproducible;       /* share of pixels with dE00 > SELPHY_DE_NOT_REPRODUCIBLE */
    double darkest_tone_l;               /* predicted L* of the corrected source black: the darkest tone the print reproduces */
    double share_below_darkest_tone;     /* share of pixels whose intended L* is below that (merged or compressed shadows) */
    double neutral_share;                /* share of pixels with intended C* < SELPHY_NEUTRAL_CHROMA */
    double neutral_p95_chroma;           /* predicted C*, 95th percentile over neutral pixels that are
                                            at least 3 L* above the darkest tone; -1 if there are none */
} selphy_photo_stats;

/* srgb_rgb8 and device_rgb8: packed R,G,B, pixel_count pixels each, same pixel order.
   corrected_black_rgb8: the device values the same correction produces for source black (0,0,0);
   its predicted lightness is the darkest tone the print can reproduce (the device black itself is
   darker but strongly tinted, and the correction does not use it).
   de_map (optional, may be NULL) receives dE00 per pixel. */
selphy_status selphy_analyze_photo(
    const uint8_t *printer_icc, size_t printer_icc_size,
    const uint8_t *srgb_rgb8, const uint8_t *device_rgb8, size_t pixel_count,
    const uint8_t corrected_black_rgb8[3],
    float *de_map, selphy_photo_stats *out_stats);

const char *selphy_status_message(selphy_status status);

/* Encoded version of the linked LittleCMS (e.g. 2200 for 2.20). */
int selphy_lcms_version(void);

#ifdef __cplusplus
}
#endif

#endif
