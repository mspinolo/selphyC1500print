/*
 * Tests for the portable colour core (Sources/SELPHYColorCore).
 * Run via CMake/ctest on Linux or macOS; argv[1] = path to the Farbenwerk CP1500 profile.
 *
 * Tolerances are stated in CIEDE2000 and justified where they are defined.
 */
#include "selphy_color_core.h"
#include "lcms2.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, ...)                                              \
    do {                                                              \
        checks++;                                                     \
        if (!(cond)) {                                                \
            failures++;                                               \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);               \
            printf(__VA_ARGS__);                                      \
            printf("\n");                                             \
        }                                                             \
    } while (0)

static uint8_t *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buffer = (uint8_t *)malloc((size_t)n);
    if (!buffer || fread(buffer, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(buffer); return NULL; }
    fclose(f);
    *size = (size_t)n;
    return buffer;
}

/* 32-patch sRGB chart (same colours as the macOS integration chart). */
#define CHART_COUNT 32
static const double chart[CHART_COUNT][3] = {
    {0, 0, 0}, {.1, .1, .1}, {.25, .25, .25}, {.5, .5, .5}, {.75, .75, .75}, {.9, .9, .9}, {1, 1, 1}, {.95, .95, .9},
    {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 0}, {0, 1, 1}, {1, 0, 1}, {.85, .2, .1}, {.1, .25, .85},
    {.76, .52, .38}, {.65, .4, .3}, {.9, .65, .5}, {.35, .2, .15}, {.1, .35, .15}, {.25, .55, .3}, {.45, .65, .4}, {.75, .85, .65},
    {.1, .2, .35}, {.25, .4, .6}, {.45, .6, .8}, {.7, .8, .95}, {.2, .1, .25}, {.45, .2, .5}, {.7, .4, .75}, {.9, .7, .85}};
/* Patches the printer can reproduce: neutral steps (L* >= 27) and skin tones. */
static const int neutral_patches[] = {2, 3, 4, 5, 6, 7};
static const int skin_patches[] = {16, 17, 18};

static void make_chart16(uint16_t *rgb) {
    for (int i = 0; i < CHART_COUNT; i++)
        for (int c = 0; c < 3; c++)
            rgb[i * 3 + c] = (uint16_t)((int)lround(chart[i][c] * 255.0) * 257);
}

static const char *intent_name(int intent) {
    return intent == 0 ? "perceptual" : intent == 1 ? "relative" : "saturation";
}

static selphy_transform *make(const uint8_t *src, size_t src_n, const uint8_t *prn, size_t prn_n,
                              int intent, int bpc, int exact) {
    selphy_options options = {(selphy_intent)intent, bpc, exact};
    selphy_transform *t = NULL;
    selphy_status s = selphy_transform_create(src, src_n, prn, prn_n, &options, &t);
    CHECK(s == SELPHY_OK && t != NULL, "create(%s,bpc=%d,exact=%d): %s", intent_name(intent), bpc, exact, selphy_status_message(s));
    return t;
}

static void test_error_paths(const uint8_t *prn, size_t prn_n) {
    selphy_options options = {SELPHY_INTENT_PERCEPTUAL, 0, 0};
    selphy_transform *t = NULL;

    CHECK(selphy_transform_create(NULL, 0, prn, prn_n, NULL, &t) == SELPHY_ERR_ARGUMENT, "NULL options");
    CHECK(selphy_transform_create(NULL, 0, prn, prn_n, &options, NULL) == SELPHY_ERR_ARGUMENT, "NULL out");
    CHECK(selphy_transform_create(NULL, 0, NULL, 0, &options, &t) == SELPHY_ERR_ARGUMENT, "NULL printer");
    CHECK(t == NULL, "no transform on error");

    selphy_options bad = {(selphy_intent)7, 0, 0};
    CHECK(selphy_transform_create(NULL, 0, prn, prn_n, &bad, &t) == SELPHY_ERR_ARGUMENT, "invalid intent");

    const uint8_t garbage[64] = {1, 2, 3};
    CHECK(selphy_transform_create(NULL, 0, garbage, sizeof garbage, &options, &t) == SELPHY_ERR_PRINTER_PROFILE, "garbage printer");
    CHECK(selphy_transform_create(garbage, sizeof garbage, prn, prn_n, &options, &t) == SELPHY_ERR_SOURCE_PROFILE, "garbage source");
    CHECK(selphy_transform_create(garbage, 0, prn, prn_n, &options, &t) == SELPHY_ERR_ARGUMENT, "non-NULL source with size 0");

    /* Truncated real profile must be rejected, not crash. */
    CHECK(selphy_transform_create(NULL, 0, prn, prn_n / 2, &options, &t) == SELPHY_ERR_PRINTER_PROFILE, "truncated printer (half)");
    CHECK(selphy_transform_create(NULL, 0, prn, prn_n - 1, &options, &t) == SELPHY_ERR_PRINTER_PROFILE, "truncated printer (one byte)");
    CHECK(t == NULL, "no transform for truncated profile");

    /* A display-class sRGB profile is not a printer profile. */
    cmsHPROFILE srgb = cmsCreate_sRGBProfile();
    cmsUInt32Number size = 0;
    cmsSaveProfileToMem(srgb, NULL, &size);
    uint8_t *srgb_bytes = (uint8_t *)malloc(size);
    cmsSaveProfileToMem(srgb, srgb_bytes, &size);
    cmsCloseProfile(srgb);
    CHECK(selphy_transform_create(NULL, 0, srgb_bytes, size, &options, &t) == SELPHY_ERR_PRINTER_UNSUPPORTED, "sRGB as printer");

    /* A gray profile is not a valid RGB source. */
    cmsToneCurve *gamma = cmsBuildGamma(NULL, 2.2);
    cmsHPROFILE gray = cmsCreateGrayProfile(cmsD50_xyY(), gamma);
    cmsFreeToneCurve(gamma);
    cmsUInt32Number gray_size = 0;
    cmsSaveProfileToMem(gray, NULL, &gray_size);
    uint8_t *gray_bytes = (uint8_t *)malloc(gray_size);
    cmsSaveProfileToMem(gray, gray_bytes, &gray_size);
    cmsCloseProfile(gray);
    CHECK(selphy_transform_create(gray_bytes, gray_size, prn, prn_n, &options, &t) == SELPHY_ERR_SOURCE_UNSUPPORTED, "gray source");

    /* Explicit sRGB bytes must behave exactly like the built-in default. */
    uint16_t in[CHART_COUNT * 3], a[CHART_COUNT * 3], b[CHART_COUNT * 3];
    make_chart16(in);
    selphy_transform *builtin = make(NULL, 0, prn, prn_n, 1, 0, 0);
    srgb = cmsCreate_sRGBProfile();
    size = 0;
    cmsSaveProfileToMem(srgb, NULL, &size);
    free(srgb_bytes);
    srgb_bytes = (uint8_t *)malloc(size);
    cmsSaveProfileToMem(srgb, srgb_bytes, &size);
    cmsCloseProfile(srgb);
    selphy_transform *explicit_t = make(srgb_bytes, size, prn, prn_n, 1, 0, 0);
    if (builtin && explicit_t) {
        selphy_transform_apply_rgb16(builtin, in, a, CHART_COUNT);
        selphy_transform_apply_rgb16(explicit_t, in, b, CHART_COUNT);
        /* Saving/reloading quantises the matrix and white point (s15Fixed16): measured
           worst case 10/65535 over a 28^3 colour grid; allow 16 (0.025 %). */
        int max_diff = 0;
        for (size_t i = 0; i < sizeof a / sizeof *a; i++) {
            int d = abs((int)a[i] - (int)b[i]);
            if (d > max_diff) max_diff = d;
        }
        CHECK(max_diff <= 16, "explicit sRGB bytes vs built-in sRGB differ by %d/65535", max_diff);
    }
    selphy_transform_free(builtin);
    selphy_transform_free(explicit_t);
    free(srgb_bytes);
    free(gray_bytes);
}

static void test_effective_bpc(const uint8_t *prn, size_t prn_n) {
    uint16_t in[CHART_COUNT * 3], out0[CHART_COUNT * 3], out1[CHART_COUNT * 3];
    make_chart16(in);
    for (int intent = 0; intent < 3; intent++) {
        selphy_transform *off = make(NULL, 0, prn, prn_n, intent, 0, 0);
        selphy_transform *on = make(NULL, 0, prn, prn_n, intent, 1, 0);
        if (!off || !on) { selphy_transform_free(off); selphy_transform_free(on); continue; }
        selphy_transform_apply_rgb16(off, in, out0, CHART_COUNT);
        selphy_transform_apply_rgb16(on, in, out1, CHART_COUNT);
        int same = memcmp(out0, out1, sizeof out0) == 0;
        if (intent == SELPHY_INTENT_RELATIVE_COLORIMETRIC) {
            CHECK(selphy_transform_effective_bpc(off) == 0, "relative: BPC off stays off");
            CHECK(selphy_transform_effective_bpc(on) == 1, "relative: BPC on is on");
            CHECK(!same, "relative: BPC on must change the output");
        } else {
            /* ICC v4 printer profile: BPC is mandatory for perceptual and saturation. */
            CHECK(selphy_transform_effective_bpc(off) == 1, "%s: BPC forced on for v4 profile", intent_name(intent));
            CHECK(selphy_transform_effective_bpc(on) == 1, "%s: BPC on", intent_name(intent));
            CHECK(same, "%s: requested BPC must not change output when forced", intent_name(intent));
        }
        selphy_transform_free(off);
        selphy_transform_free(on);
    }
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

/* The optimised (precalculated) transform must agree with the exact pipeline.
   1 dE00 is about the just-noticeable difference; the optimisation error must be
   well below it, so mean <= 0.1 and max <= 0.5. */
/* The three intents use different printer tables, so a chart containing saturated
   colours must not convert identically. */
static void test_intents_are_distinct(const uint8_t *prn, size_t prn_n) {
    uint16_t in[CHART_COUNT * 3], out[3][CHART_COUNT * 3];
    make_chart16(in);
    for (int intent = 0; intent < 3; intent++) {
        selphy_transform *t = make(NULL, 0, prn, prn_n, intent, 0, 0);
        if (!t) return;
        selphy_transform_apply_rgb16(t, in, out[intent], CHART_COUNT);
        selphy_transform_free(t);
    }
    CHECK(memcmp(out[0], out[1], sizeof out[0]) != 0, "perceptual and relative output identical");
    CHECK(memcmp(out[0], out[2], sizeof out[0]) != 0, "perceptual and saturation output identical");
    CHECK(memcmp(out[1], out[2], sizeof out[0]) != 0, "relative and saturation output identical");
}

static void test_optimised_matches_exact(const uint8_t *prn, size_t prn_n) {
    uint16_t in[CHART_COUNT * 3], fast[CHART_COUNT * 3], exact[CHART_COUNT * 3];
    double lab_fast[CHART_COUNT * 3], lab_exact[CHART_COUNT * 3], delta[CHART_COUNT];
    make_chart16(in);
    for (int intent = 0; intent < 3; intent++) {
        for (int bpc = 0; bpc < 2; bpc++) {
            selphy_transform *f = make(NULL, 0, prn, prn_n, intent, bpc, 0);
            selphy_transform *x = make(NULL, 0, prn, prn_n, intent, bpc, 1);
            if (!f || !x) { selphy_transform_free(f); selphy_transform_free(x); continue; }
            selphy_transform_apply_rgb16(f, in, fast, CHART_COUNT);
            selphy_transform_apply_rgb16(x, in, exact, CHART_COUNT);
            CHECK(selphy_printer_predict_lab(prn, prn_n, (selphy_intent)intent, fast, lab_fast, CHART_COUNT) == SELPHY_OK, "predict fast");
            CHECK(selphy_printer_predict_lab(prn, prn_n, (selphy_intent)intent, exact, lab_exact, CHART_COUNT) == SELPHY_OK, "predict exact");
            double sum = 0;
            for (int i = 0; i < CHART_COUNT; i++) {
                delta[i] = selphy_delta_e2000(lab_fast + i * 3, lab_exact + i * 3);
                sum += delta[i];
            }
            qsort(delta, CHART_COUNT, sizeof(double), cmp_double);
            printf("optimised-vs-exact %-10s bpc=%d: mean=%.3f max=%.3f dE00\n", intent_name(intent), bpc, sum / CHART_COUNT, delta[CHART_COUNT - 1]);
            CHECK(sum / CHART_COUNT <= 0.1, "%s bpc=%d mean dE00 %.3f", intent_name(intent), bpc, sum / CHART_COUNT);
            CHECK(delta[CHART_COUNT - 1] <= 0.5, "%s bpc=%d max dE00 %.3f", intent_name(intent), bpc, delta[CHART_COUNT - 1]);
            selphy_transform_free(f);
            selphy_transform_free(x);
        }
    }
}

/* Closed-loop check against the profile's own forward model (relative colorimetric,
   no BPC): the printer, fed the corrected values, should reproduce the intended Lab.
   - reproducible patches (neutrals with L* >= 27, skin tones): dE00 <= 0.5;
   - no patch may be worse than sending the uncorrected values (+0.05 slack);
   - overall mean must be at most half of the uncorrected mean.
   Out-of-gamut primaries and near-black patches are deliberately not asserted
   individually: the printer physically cannot reproduce them. */
static void test_closed_loop_model(const uint8_t *prn, size_t prn_n) {
    uint16_t in[CHART_COUNT * 3], out[CHART_COUNT * 3];
    double intended[CHART_COUNT * 3], corrected[CHART_COUNT * 3], baseline[CHART_COUNT * 3];
    make_chart16(in);
    selphy_transform *t = make(NULL, 0, prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, 0, 1);
    if (!t) return;
    selphy_transform_apply_rgb16(t, in, out, CHART_COUNT);
    selphy_transform_free(t);
    CHECK(selphy_source_to_lab(NULL, 0, in, intended, CHART_COUNT) == SELPHY_OK, "source lab");
    CHECK(selphy_printer_predict_lab(prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, out, corrected, CHART_COUNT) == SELPHY_OK, "corrected lab");
    CHECK(selphy_printer_predict_lab(prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, in, baseline, CHART_COUNT) == SELPHY_OK, "baseline lab");

    double sum_corrected = 0, sum_baseline = 0;
    for (int i = 0; i < CHART_COUNT; i++) {
        double dc = selphy_delta_e2000(corrected + i * 3, intended + i * 3);
        double db = selphy_delta_e2000(baseline + i * 3, intended + i * 3);
        sum_corrected += dc;
        sum_baseline += db;
        CHECK(dc <= db + 0.05, "patch %d worse than uncorrected: %.2f vs %.2f", i, dc, db);
    }
    for (size_t k = 0; k < sizeof neutral_patches / sizeof *neutral_patches; k++) {
        int i = neutral_patches[k];
        double dc = selphy_delta_e2000(corrected + i * 3, intended + i * 3);
        CHECK(dc <= 0.5, "neutral patch %d dE00 %.2f", i, dc);
    }
    for (size_t k = 0; k < sizeof skin_patches / sizeof *skin_patches; k++) {
        int i = skin_patches[k];
        double dc = selphy_delta_e2000(corrected + i * 3, intended + i * 3);
        CHECK(dc <= 0.5, "skin patch %d dE00 %.2f", i, dc);
    }
    printf("closed loop relative/BPC off: mean dE00 corrected=%.2f uncorrected=%.2f\n", sum_corrected / CHART_COUNT, sum_baseline / CHART_COUNT);
    CHECK(sum_corrected <= 0.5 * sum_baseline, "mean dE00 %.2f not at most half of uncorrected %.2f", sum_corrected / CHART_COUNT, sum_baseline / CHART_COUNT);
}

/* Neutral ramp: predicted L* must be monotonic for every intent/BPC combination
   (no tone reversals). 0.05 L* absorbs 16-bit quantisation. */
static void test_ramp_monotonic(const uint8_t *prn, size_t prn_n) {
    uint16_t ramp[256 * 3], out[256 * 3];
    double lab[256 * 3];
    for (int i = 0; i < 256; i++)
        for (int c = 0; c < 3; c++) ramp[i * 3 + c] = (uint16_t)(i * 257);
    for (int intent = 0; intent < 3; intent++) {
        for (int bpc = 0; bpc < 2; bpc++) {
            selphy_transform *t = make(NULL, 0, prn, prn_n, intent, bpc, 0);
            if (!t) continue;
            selphy_transform_apply_rgb16(t, ramp, out, 256);
            selphy_transform_free(t);
            CHECK(selphy_printer_predict_lab(prn, prn_n, (selphy_intent)intent, out, lab, 256) == SELPHY_OK, "ramp predict");
            double max_drop = 0;
            for (int i = 1; i < 256; i++) {
                double drop = lab[(i - 1) * 3] - lab[i * 3];
                if (drop > max_drop) max_drop = drop;
            }
            CHECK(max_drop <= 0.05, "%s bpc=%d ramp L* drops by %.3f", intent_name(intent), bpc, max_drop);
            CHECK(lab[255 * 3] >= 95.0, "%s bpc=%d white L* %.1f", intent_name(intent), bpc, lab[255 * 3]);
            /* Which table was used is observable at the black end of the ramp:
               ICC v4 perceptual PCS has its reference black at L* 3.14; the relative
               and saturation tables bottom out at the printer's real black, which for a
               dye-sublimation print is far lighter (measured 17.9 and 20.5). */
            if (intent == SELPHY_INTENT_PERCEPTUAL)
                CHECK(lab[0] <= 5.0, "perceptual black L* %.1f (expected near the v4 reference black 3.14)", lab[0]);
            else
                CHECK(lab[0] >= 10.0, "%s black L* %.1f (expected the printer's real black)", intent_name(intent), lab[0]);
        }
    }
}

/* 8-bit convenience path equals "expand to 16 bit, convert, round once", for any
   buffer length (exercises chunk boundaries). */
static void test_apply8_consistency(const uint8_t *prn, size_t prn_n) {
    const size_t count = 10007; /* not a multiple of the internal chunk size */
    uint8_t *in8 = (uint8_t *)malloc(count * 3), *out8 = (uint8_t *)malloc(count * 3);
    uint16_t *in16 = (uint16_t *)malloc(count * 6), *out16 = (uint16_t *)malloc(count * 6);
    unsigned seed = 12345u;
    for (size_t i = 0; i < count * 3; i++) {
        seed = seed * 1664525u + 1013904223u;
        in8[i] = (uint8_t)(seed >> 24);
        in16[i] = (uint16_t)(in8[i] * 257u);
    }
    selphy_transform *t = make(NULL, 0, prn, prn_n, 1, 1, 0);
    if (t) {
        selphy_transform_apply_rgb8(t, in8, out8, count);
        selphy_transform_apply_rgb16(t, in16, out16, count);
        size_t mismatches = 0;
        for (size_t i = 0; i < count * 3; i++) {
            uint8_t expected = (uint8_t)(((uint32_t)out16[i] * 255u + 32767u) / 65535u);
            if (out8[i] != expected) mismatches++;
        }
        CHECK(mismatches == 0, "%zu of %zu samples differ between 8-bit and 16-bit paths", mismatches, count * 3);
        selphy_transform_free(t);
    }
    free(in8); free(out8); free(in16); free(out16);
}

/* The source profile must be honoured: a wide-gamut (Adobe RGB 1998-like) source
   must give different device values than sRGB for saturated colours, but the same
   neutral axis. */
static void test_wide_gamut_source(const uint8_t *prn, size_t prn_n) {
    cmsCIExyY d65 = {0.3127, 0.3290, 1.0};
    cmsCIExyYTRIPLE primaries = {{0.6400, 0.3300, 1.0}, {0.2100, 0.7100, 1.0}, {0.1500, 0.0600, 1.0}};
    cmsToneCurve *gamma = cmsBuildGamma(NULL, 2.19921875);
    cmsToneCurve *curves[3] = {gamma, gamma, gamma};
    cmsHPROFILE adobe = cmsCreateRGBProfile(&d65, &primaries, curves);
    cmsFreeToneCurve(gamma);
    cmsUInt32Number size = 0;
    cmsSaveProfileToMem(adobe, NULL, &size);
    uint8_t *bytes = (uint8_t *)malloc(size);
    cmsSaveProfileToMem(adobe, bytes, &size);
    cmsCloseProfile(adobe);

    uint16_t in[2 * 3] = {0, (uint16_t)(200 * 257), 0, (uint16_t)(128 * 257), (uint16_t)(128 * 257), (uint16_t)(128 * 257)};
    uint16_t out_wide[6], out_srgb[6];
    selphy_transform *wide = make(bytes, size, prn, prn_n, 1, 0, 1);
    selphy_transform *srgb = make(NULL, 0, prn, prn_n, 1, 0, 1);
    if (wide && srgb) {
        selphy_transform_apply_rgb16(wide, in, out_wide, 2);
        selphy_transform_apply_rgb16(srgb, in, out_srgb, 2);
        CHECK(memcmp(out_wide, out_srgb, 3 * sizeof(uint16_t)) != 0, "saturated green must differ between wide-gamut and sRGB sources");
        double lab_wide[3], lab_srgb[3];
        selphy_printer_predict_lab(prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, out_wide + 3, lab_wide, 1);
        selphy_printer_predict_lab(prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, out_srgb + 3, lab_srgb, 1);
        double de = selphy_delta_e2000(lab_wide, lab_srgb);
        /* Gamma 2.2 vs the sRGB curve differ slightly on the neutral axis; 2 dE00 is a loose bound. */
        CHECK(de <= 2.0, "mid-gray differs by dE00 %.2f between sources", de);
    }
    selphy_transform_free(wide);
    selphy_transform_free(srgb);
    free(bytes);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <printer-profile.icc>\n", argv[0]);
        return 2;
    }
    size_t prn_n = 0;
    uint8_t *prn = read_file(argv[1], &prn_n);
    if (!prn) {
        fprintf(stderr, "cannot read %s\n", argv[1]);
        return 2;
    }
    printf("LittleCMS %d, profile %zu bytes\n", selphy_lcms_version(), prn_n);

    test_error_paths(prn, prn_n);
    test_effective_bpc(prn, prn_n);
    test_intents_are_distinct(prn, prn_n);
    test_optimised_matches_exact(prn, prn_n);
    test_closed_loop_model(prn, prn_n);
    test_ramp_monotonic(prn, prn_n);
    test_apply8_consistency(prn, prn_n);
    test_wide_gamut_source(prn, prn_n);

    free(prn);
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
