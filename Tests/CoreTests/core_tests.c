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


/* ---- Soft-proof preview ------------------------------------------------------------- */

static selphy_preview *make_preview(const uint8_t *prn, size_t prn_n, int paper, int bpc) {
    selphy_preview_options o = {paper, bpc};
    selphy_preview *p = NULL;
    selphy_status s = selphy_preview_create(prn, prn_n, NULL, 0, &o, &p);
    CHECK(s == SELPHY_OK && p != NULL, "preview create(paper=%d,bpc=%d): %s", paper, bpc, selphy_status_message(s));
    return p;
}

static void test_preview_error_paths(const uint8_t *prn, size_t prn_n) {
    selphy_preview_options o = {0, 0};
    selphy_preview *p = NULL;
    CHECK(selphy_preview_create(prn, prn_n, NULL, 0, NULL, &p) == SELPHY_ERR_ARGUMENT, "NULL options");
    CHECK(selphy_preview_create(prn, prn_n, NULL, 0, &o, NULL) == SELPHY_ERR_ARGUMENT, "NULL out");
    CHECK(selphy_preview_create(NULL, 0, NULL, 0, &o, &p) == SELPHY_ERR_ARGUMENT, "NULL printer");
    CHECK(selphy_preview_create(prn, prn_n / 2, NULL, 0, &o, &p) == SELPHY_ERR_PRINTER_PROFILE, "truncated printer");
    uint8_t garbage[200];
    memset(garbage, 7, sizeof garbage);
    CHECK(selphy_preview_create(prn, prn_n, garbage, sizeof garbage, &o, &p) == SELPHY_ERR_DISPLAY_PROFILE, "garbage display");
    CHECK(selphy_preview_create(prn, prn_n, prn, prn_n, &o, &p) == SELPHY_ERR_DISPLAY_PROFILE,
          "a printer profile must not be accepted as display profile");
    CHECK(p == NULL, "no preview on error");
    /* Calling apply with NULLs must not crash and must zero the counter. */
    size_t clipped = 99;
    selphy_preview_apply_rgb8(NULL, NULL, NULL, 10, &clipped);
    CHECK(clipped == 0, "counter reset on invalid call");
    selphy_preview_free(NULL);
}

/* Reference: the preview must agree with the independent A2B prediction (Lab) for colours
   inside the display gamut. Neutral steps and skin tones are inside sRGB. */
static void test_preview_matches_model(const uint8_t *prn, size_t prn_n) {
    selphy_preview *p = make_preview(prn, prn_n, 0, 0);
    if (!p) return;
    uint8_t device[CHART_COUNT * 3], shown[CHART_COUNT * 3];
    uint16_t device16[CHART_COUNT * 3], shown16[CHART_COUNT * 3];
    make_chart16(device16);
    for (int i = 0; i < CHART_COUNT * 3; i++) device[i] = (uint8_t)(device16[i] / 257);
    selphy_preview_apply_rgb8(p, device, shown, CHART_COUNT, NULL);
    for (int i = 0; i < CHART_COUNT * 3; i++) shown16[i] = (uint16_t)(shown[i] * 257);
    double predicted[CHART_COUNT * 3], displayed[CHART_COUNT * 3];
    CHECK(selphy_printer_predict_lab(prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, device16, predicted, CHART_COUNT) == SELPHY_OK, "predict");
    CHECK(selphy_source_to_lab(NULL, 0, shown16, displayed, CHART_COUNT) == SELPHY_OK, "display->lab");
    int groups[2] = {0, 0};
    const int *lists[2] = {neutral_patches, skin_patches};
    const int counts[2] = {6, 3};
    for (int g = 0; g < 2; g++)
        for (int k = 0; k < counts[g]; k++) {
            int i = lists[g][k];
            double de = selphy_delta_e2000(predicted + i * 3, displayed + i * 3);
            printf("preview model patch %d: dE00=%.3f\n", i, de);
            /* 8-bit rounding of the display value plus the 16-bit table precision. */
            CHECK(de <= 1.0, "preview vs A2B model patch %d: dE00 %.3f", i, de);
            groups[g]++;
        }
    selphy_preview_free(p);
}

/* Closed loop: preview(corrected) must look like the original; preview(uncorrected) must not. */
static void test_preview_closed_loop(const uint8_t *prn, size_t prn_n) {
    selphy_preview *p = make_preview(prn, prn_n, 0, 0);
    selphy_transform *t = make(NULL, 0, prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, 0, 0);
    if (!p || !t) { selphy_preview_free(p); selphy_transform_free(t); return; }
    uint16_t src16[CHART_COUNT * 3];
    uint8_t src8[CHART_COUNT * 3], corrected[CHART_COUNT * 3], with[CHART_COUNT * 3], without[CHART_COUNT * 3];
    make_chart16(src16);
    for (int i = 0; i < CHART_COUNT * 3; i++) src8[i] = (uint8_t)(src16[i] / 257);
    selphy_transform_apply_rgb8(t, src8, corrected, CHART_COUNT);
    selphy_preview_apply_rgb8(p, corrected, with, CHART_COUNT, NULL);
    selphy_preview_apply_rgb8(p, src8, without, CHART_COUNT, NULL);

    uint16_t with16[CHART_COUNT * 3], without16[CHART_COUNT * 3];
    for (int i = 0; i < CHART_COUNT * 3; i++) { with16[i] = (uint16_t)(with[i] * 257); without16[i] = (uint16_t)(without[i] * 257); }
    double original[CHART_COUNT * 3], labWith[CHART_COUNT * 3], labWithout[CHART_COUNT * 3];
    CHECK(selphy_source_to_lab(NULL, 0, src16, original, CHART_COUNT) == SELPHY_OK, "original lab");
    CHECK(selphy_source_to_lab(NULL, 0, with16, labWith, CHART_COUNT) == SELPHY_OK, "with lab");
    CHECK(selphy_source_to_lab(NULL, 0, without16, labWithout, CHART_COUNT) == SELPHY_OK, "without lab");
    double sumWith = 0, sumWithout = 0;
    for (int i = 0; i < CHART_COUNT; i++) {
        sumWith += selphy_delta_e2000(original + i * 3, labWith + i * 3);
        sumWithout += selphy_delta_e2000(original + i * 3, labWithout + i * 3);
    }
    printf("preview closed loop: mean dE00 with correction=%.2f, without=%.2f\n", sumWith / CHART_COUNT, sumWithout / CHART_COUNT);
    CHECK(sumWith <= 0.5 * sumWithout, "preview with correction must be at least twice as close to the original");
    const int *lists[2] = {neutral_patches, skin_patches};
    const int counts[2] = {6, 3};
    for (int g = 0; g < 2; g++)
        for (int k = 0; k < counts[g]; k++) {
            int i = lists[g][k];
            double de = selphy_delta_e2000(original + i * 3, labWith + i * 3);
            CHECK(de <= 1.0, "preview of corrected vs original, patch %d: dE00 %.3f", i, de);
        }
    selphy_preview_free(p);
    selphy_transform_free(t);
}

static void test_preview_white_and_black(const uint8_t *prn, size_t prn_n) {
    selphy_preview *rel = make_preview(prn, prn_n, 0, 0);
    selphy_preview *bpc = make_preview(prn, prn_n, 0, 1);
    selphy_preview *abs_ = make_preview(prn, prn_n, 1, 0);
    if (!rel || !bpc || !abs_) { selphy_preview_free(rel); selphy_preview_free(bpc); selphy_preview_free(abs_); return; }
    const uint8_t white[3] = {255, 255, 255}, black[3] = {0, 0, 0};
    uint8_t out[3];
    selphy_preview_apply_rgb8(rel, white, out, 1, NULL);
    printf("preview relative white = %d %d %d\n", out[0], out[1], out[2]);
    CHECK(out[0] >= 250 && out[1] >= 250 && out[2] >= 250, "relative: paper white must map to display white");
    int relWhiteMin = out[0] < out[1] ? (out[0] < out[2] ? out[0] : out[2]) : (out[1] < out[2] ? out[1] : out[2]);
    selphy_preview_apply_rgb8(abs_, white, out, 1, NULL);
    printf("preview absolute white = %d %d %d\n", out[0], out[1], out[2]);
    int absWhiteMin = out[0] < out[1] ? (out[0] < out[2] ? out[0] : out[2]) : (out[1] < out[2] ? out[1] : out[2]);
    CHECK(absWhiteMin < relWhiteMin, "paper-white simulation must show a tinted/darker paper (min %d vs %d)", absWhiteMin, relWhiteMin);
    selphy_preview_apply_rgb8(rel, black, out, 1, NULL);
    printf("preview relative black = %d %d %d\n", out[0], out[1], out[2]);
    /* The printer's own black is only L*~18 (with a bluish cast in this profile): clearly
       lifted from the display black, but still dark. */
    int relSum = out[0] + out[1] + out[2];
    CHECK(relSum >= 60 && relSum <= 240, "printer black is lifted but dark (got %d %d %d)", out[0], out[1], out[2]);
    selphy_preview_apply_rgb8(bpc, black, out, 1, NULL);
    printf("preview BPC black = %d %d %d\n", out[0], out[1], out[2]);
    int bpcSum = out[0] + out[1] + out[2];
    CHECK(bpcSum * 2 <= relSum, "BPC must clearly darken the printer black (%d vs %d)", bpcSum, relSum);
    selphy_preview_free(rel);
    selphy_preview_free(bpc);
    selphy_preview_free(abs_);
}

static void test_preview_gamut_report_and_chunking(const uint8_t *prn, size_t prn_n) {
    selphy_preview *p = make_preview(prn, prn_n, 0, 0);
    if (!p) return;
    /* Coarse sweep of the whole device cube. */
    enum { STEPS = 9, TOTAL = STEPS * STEPS * STEPS };
    static uint8_t cube[TOTAL * 3], shown[TOTAL * 3];
    int n = 0;
    for (int r = 0; r < STEPS; r++) for (int g = 0; g < STEPS; g++) for (int b = 0; b < STEPS; b++) {
        cube[n * 3] = (uint8_t)(r * 255 / (STEPS - 1));
        cube[n * 3 + 1] = (uint8_t)(g * 255 / (STEPS - 1));
        cube[n * 3 + 2] = (uint8_t)(b * 255 / (STEPS - 1));
        n++;
    }
    size_t clipped = 0;
    selphy_preview_apply_rgb8(p, cube, shown, TOTAL, &clipped);
    printf("preview gamut sweep: %zu of %d device colours fall outside sRGB\n", clipped, TOTAL);
    CHECK(clipped > 0 && clipped < TOTAL, "some, not all, device colours are outside the display gamut (%zu)", clipped);

    /* Neutral axis never clips. */
    uint8_t gray[256 * 3], grayShown[256 * 3];
    for (int i = 0; i < 256; i++) gray[i * 3] = gray[i * 3 + 1] = gray[i * 3 + 2] = (uint8_t)i;
    selphy_preview_apply_rgb8(p, gray, grayShown, 256, &clipped);
    CHECK(clipped == 0, "neutral ramp must stay inside the display gamut (%zu clipped)", clipped);

    /* Chunk boundary: one big call equals pixel-by-pixel calls. */
    enum { BIG = 10007 };
    static uint8_t in[BIG * 3], big[BIG * 3], single[3];
    uint32_t seed = 1;
    for (int i = 0; i < BIG * 3; i++) { seed = seed * 1664525u + 1013904223u; in[i] = (uint8_t)(seed >> 24); }
    selphy_preview_apply_rgb8(p, in, big, BIG, NULL);
    int mismatches = 0;
    for (int i = 0; i < BIG; i++) {
        selphy_preview_apply_rgb8(p, in + i * 3, single, 1, NULL);
        if (memcmp(single, big + i * 3, 3) != 0) mismatches++;
    }
    CHECK(mismatches == 0, "chunked and single-pixel preview differ in %d pixels", mismatches);
    selphy_preview_free(p);
}


/* ---- Per-photo checks ----------------------------------------------------------------- */

static void correct8(const uint8_t *prn, size_t prn_n, const uint8_t *src, uint8_t *dst, size_t n) {
    selphy_transform *t = make(NULL, 0, prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, 0, 0);
    if (t) { selphy_transform_apply_rgb8(t, src, dst, n); selphy_transform_free(t); }
}

static void corrected_black(const uint8_t *prn, size_t prn_n, uint8_t out[3]) {
    const uint8_t black[3] = {0, 0, 0};
    correct8(prn, prn_n, black, out, 1);
}

static void test_analysis_error_paths(const uint8_t *prn, size_t prn_n) {
    uint8_t px[3] = {10, 20, 30}, kb[3] = {30, 20, 0};
    selphy_photo_stats st;
    CHECK(selphy_analyze_photo(prn, prn_n, px, px, 1, kb, NULL, NULL) == SELPHY_ERR_ARGUMENT, "NULL stats");
    CHECK(selphy_analyze_photo(prn, prn_n, NULL, px, 1, kb, NULL, &st) == SELPHY_ERR_ARGUMENT, "NULL source");
    CHECK(selphy_analyze_photo(prn, prn_n, px, NULL, 1, kb, NULL, &st) == SELPHY_ERR_ARGUMENT, "NULL device");
    CHECK(selphy_analyze_photo(prn, prn_n, px, px, 0, kb, NULL, &st) == SELPHY_ERR_ARGUMENT, "no pixels");
    CHECK(selphy_analyze_photo(prn, prn_n, px, px, 1, NULL, NULL, &st) == SELPHY_ERR_ARGUMENT, "NULL black");
    CHECK(selphy_analyze_photo(prn, prn_n / 2, px, px, 1, kb, NULL, &st) == SELPHY_ERR_PRINTER_PROFILE, "truncated printer");
    CHECK(selphy_analyze_photo(NULL, 0, px, px, 1, kb, NULL, &st) == SELPHY_ERR_ARGUMENT, "NULL printer");
}

/* White and light neutral: nothing to report. */
static void test_analysis_white_and_midgrey(const uint8_t *prn, size_t prn_n) {
    enum { N = 64 };
    uint8_t src[N * 3], dev[N * 3];
    for (int i = 0; i < N; i++) src[i * 3] = src[i * 3 + 1] = src[i * 3 + 2] = (i % 2) ? 255 : 128;
    correct8(prn, prn_n, src, dev, N);
    selphy_photo_stats st;
    uint8_t kb[3];
    corrected_black(prn, prn_n, kb);
    CHECK(selphy_analyze_photo(prn, prn_n, src, dev, N, kb, NULL, &st) == SELPHY_OK, "analyze");
    printf("analysis white+grey: mean=%.3f p95=%.3f max=%.3f darkest L=%.2f neutral=%.2f chroma95=%.2f\n",
           st.mean_de, st.p95_de, st.max_de, st.darkest_tone_l, st.neutral_share, st.neutral_p95_chroma);
    CHECK(st.mean_de < 0.5 && st.max_de < 1.0, "white and mid grey are reproduced (mean %.3f max %.3f)", st.mean_de, st.max_de);
    CHECK(st.share_not_reproducible == 0.0, "nothing is unreproducible");
    CHECK(st.share_below_darkest_tone == 0.0, "nothing is below the darkest tone");
    CHECK(st.neutral_share == 1.0, "all pixels neutral");
    CHECK(st.neutral_p95_chroma >= 0.0 && st.neutral_p95_chroma <= 1.0, "residual chroma small (%.2f)", st.neutral_p95_chroma);
    CHECK(st.darkest_tone_l > 15.0 && st.darkest_tone_l < 20.0, "darkest reproducible tone L* about 18 (%.2f)", st.darkest_tone_l);
}

/* Full neutral ramp: shadow share checked against an independent computation. */
static void test_analysis_neutral_ramp(const uint8_t *prn, size_t prn_n) {
    uint8_t src[256 * 3], dev[256 * 3];
    for (int i = 0; i < 256; i++) src[i * 3] = src[i * 3 + 1] = src[i * 3 + 2] = (uint8_t)i;
    correct8(prn, prn_n, src, dev, 256);
    uint8_t kb[3] = {dev[0], dev[1], dev[2]};   /* the corrected source black is ramp level 0 */
    selphy_photo_stats st;
    CHECK(selphy_analyze_photo(prn, prn_n, src, dev, 256, kb, NULL, &st) == SELPHY_OK, "analyze");

    uint16_t kb16[3] = {(uint16_t)(kb[0] * 257), (uint16_t)(kb[1] * 257), (uint16_t)(kb[2] * 257)}, s16[256 * 3];
    for (int i = 0; i < 256 * 3; i++) s16[i] = (uint16_t)(src[i] * 257);
    double black[3], lab[256 * 3];
    CHECK(selphy_printer_predict_lab(prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, kb16, black, 1) == SELPHY_OK, "black");
    CHECK(selphy_source_to_lab(NULL, 0, s16, lab, 256) == SELPHY_OK, "lab");
    int below = 0;
    for (int i = 0; i < 256; i++) if (lab[i * 3] < black[0]) below++;
    printf("analysis ramp: darkest tone L*=%.2f, levels below = %d/256, stats say %.4f; not reproducible %.3f; chroma95 %.2f; mean %.2f p95 %.2f\n",
           st.darkest_tone_l, below, st.share_below_darkest_tone, st.share_not_reproducible, st.neutral_p95_chroma, st.mean_de, st.p95_de);
    CHECK(fabs(st.darkest_tone_l - black[0]) < 0.05, "darkest tone matches the A2B of the corrected black");
    CHECK(fabs(st.share_below_darkest_tone - below / 256.0) < 1e-9, "shadow share differs from the independent count");
    CHECK(below >= 30 && below <= 60, "about the darkest 40 levels are below the darkest tone (%d)", below);
    CHECK(st.neutral_share == 1.0, "ramp is neutral");
    CHECK(st.neutral_p95_chroma >= 0.0 && st.neutral_p95_chroma <= 1.2, "reproducible neutrals stay neutral (C* %.2f)", st.neutral_p95_chroma);
    CHECK(st.share_not_reproducible >= st.share_below_darkest_tone * 0.5 && st.share_not_reproducible <= 0.30,
          "unreproducible share plausible (%.3f)", st.share_not_reproducible);
    CHECK(st.p95_de >= st.mean_de && st.max_de >= st.p95_de - 0.05, "ordering mean <= p95 <= max");

    /* Chroma is measured on the predicted print, not on the original: sent uncorrected, the
       same neutral ramp must show a clearly larger residual tint. */
    selphy_photo_stats raw;
    CHECK(selphy_analyze_photo(prn, prn_n, src, src, 256, kb, NULL, &raw) == SELPHY_OK, "analyze uncorrected ramp");
    printf("analysis ramp uncorrected: chroma95 %.2f (corrected %.2f)\n", raw.neutral_p95_chroma, st.neutral_p95_chroma);
    CHECK(raw.neutral_p95_chroma > 2.0 && raw.neutral_p95_chroma > 2.0 * st.neutral_p95_chroma,
          "uncorrected neutrals show a tint (C* %.2f)", raw.neutral_p95_chroma);
}

static void test_analysis_primaries_and_map(const uint8_t *prn, size_t prn_n) {
    /* Saturated primaries are outside the printer gamut. */
    uint8_t src[3 * 3] = {255, 0, 0, 0, 255, 0, 0, 0, 255}, dev[9];
    correct8(prn, prn_n, src, dev, 3);
    selphy_photo_stats st;
    uint8_t kb[3];
    corrected_black(prn, prn_n, kb);
    CHECK(selphy_analyze_photo(prn, prn_n, src, dev, 3, kb, NULL, &st) == SELPHY_OK, "analyze");
    printf("analysis primaries: not reproducible=%.2f mean=%.2f max=%.2f\n", st.share_not_reproducible, st.mean_de, st.max_de);
    CHECK(st.share_not_reproducible == 1.0 && st.mean_de > 5.0, "pure primaries are not reproducible");
    CHECK(st.neutral_share == 0.0 && st.neutral_p95_chroma == -1.0, "no neutral pixels in primaries");

    /* Per-pixel map against the independent per-patch computation on the chart. */
    uint16_t c16[CHART_COUNT * 3];
    uint8_t c8[CHART_COUNT * 3], d8[CHART_COUNT * 3];
    float map[CHART_COUNT];
    make_chart16(c16);
    for (int i = 0; i < CHART_COUNT * 3; i++) c8[i] = (uint8_t)(c16[i] / 257);
    correct8(prn, prn_n, c8, d8, CHART_COUNT);
    CHECK(selphy_analyze_photo(prn, prn_n, c8, d8, CHART_COUNT, kb, map, &st) == SELPHY_OK, "analyze chart");
    uint16_t d16[CHART_COUNT * 3];
    for (int i = 0; i < CHART_COUNT * 3; i++) d16[i] = (uint16_t)(d8[i] * 257);
    double intended[CHART_COUNT * 3], predicted[CHART_COUNT * 3], sum = 0.0;
    CHECK(selphy_source_to_lab(NULL, 0, c16, intended, CHART_COUNT) == SELPHY_OK, "intended");
    CHECK(selphy_printer_predict_lab(prn, prn_n, SELPHY_INTENT_RELATIVE_COLORIMETRIC, d16, predicted, CHART_COUNT) == SELPHY_OK, "predicted");
    double worst = 0.0;
    for (int i = 0; i < CHART_COUNT; i++) {
        double de = selphy_delta_e2000(intended + i * 3, predicted + i * 3);
        sum += de;
        if (fabs(de - map[i]) > worst) worst = fabs(de - map[i]);
    }
    printf("analysis chart: mean=%.3f (independent %.3f), map deviation %.4f\n", st.mean_de, sum / CHART_COUNT, worst);
    CHECK(worst < 0.05, "dE map differs from the independent computation by %.4f", worst);
    CHECK(fabs(st.mean_de - sum / CHART_COUNT) < 0.05, "mean dE differs from the independent computation");

    /* The same photo sent uncorrected is clearly worse. */
    selphy_photo_stats raw;
    CHECK(selphy_analyze_photo(prn, prn_n, c8, c8, CHART_COUNT, kb, NULL, &raw) == SELPHY_OK, "analyze uncorrected");
    printf("analysis chart uncorrected: mean=%.2f vs corrected %.2f\n", raw.mean_de, st.mean_de);
    CHECK(raw.mean_de > 2.0 * st.mean_de, "uncorrected must be at least twice as far from the original");
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
    test_preview_error_paths(prn, prn_n);
    test_preview_matches_model(prn, prn_n);
    test_preview_closed_loop(prn, prn_n);
    test_preview_white_and_black(prn, prn_n);
    test_preview_gamut_report_and_chunking(prn, prn_n);
    test_analysis_error_paths(prn, prn_n);
    test_analysis_white_and_midgrey(prn, prn_n);
    test_analysis_neutral_ramp(prn, prn_n);
    test_analysis_primaries_and_map(prn, prn_n);

    free(prn);
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
