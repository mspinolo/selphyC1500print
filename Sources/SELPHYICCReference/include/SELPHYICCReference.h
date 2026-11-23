#ifndef SELPHY_ICC_REFERENCE_H
#define SELPHY_ICC_REFERENCE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Independent LittleCMS reference transform: sRGB input to the supplied
/// printer profile's device RGB values. Returns 1 on success, 0 on failure.
int selphy_lcms_srgb_to_printer(
    const char *source_profile_path,
    const char *printer_profile_path,
    uint32_t rendering_intent,
    int black_point_compensation,
    const uint8_t *input_rgb,
    uint8_t *output_rgb,
    size_t pixel_count
);

/// Estimate effective source/destination black points and report mediaBlackPoint tags.
/// Output layout: source XYZ [0...2], source L* [3], destination XYZ [4...6],
/// destination L* [7], source mediaBlackPoint XYZ [8...10], destination tag [11...13].
/// Missing mediaBlackPoint tags are returned as NaN.
int selphy_lcms_inspect_black_points(
    const char *source_profile_path,
    const char *printer_profile_path,
    uint32_t rendering_intent,
    double *output_values
);

/// Diagnostic cmsCreateExtendedTransform reference with its two per-profile BPC entries controlled independently.
int selphy_lcms_srgb_to_printer_profile_bpc(
    const char *source_profile_path,
    const char *printer_profile_path,
    uint32_t rendering_intent,
    int source_bpc,
    int destination_bpc,
    const uint8_t *input_rgb,
    uint8_t *output_rgb,
    size_t pixel_count
);

#ifdef __cplusplus
}
#endif

#endif
