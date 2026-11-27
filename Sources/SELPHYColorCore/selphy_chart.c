/* Scans of the validation chart: corner marks, homography, patch sampling.
   A step-by-step port of validation/analyze_scan.py (find_fiducials, homography, sample_rect),
   so that the app and the Python reference tools give the same numbers on the same scan. */
#include "selphy_color_core.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define DOWNSAMPLE_TARGET 1400
#define DARK_L 35.0
#define MIN_AREA 12

/* ---- Homography ------------------------------------------------------------------------ */

static int solve8(double a[8][9]) {
    /* Gaussian elimination with partial pivoting on an augmented 8x9 matrix. */
    for (int col = 0; col < 8; col++) {
        int pivot = col;
        for (int r = col + 1; r < 8; r++) {
            if (fabs(a[r][col]) > fabs(a[pivot][col])) pivot = r;
        }
        if (fabs(a[pivot][col]) < 1e-12) return 0;
        if (pivot != col) {
            for (int k = 0; k < 9; k++) {
                double t = a[col][k]; a[col][k] = a[pivot][k]; a[pivot][k] = t;
            }
        }
        for (int r = 0; r < 8; r++) {
            if (r == col) continue;
            double f = a[r][col] / a[col][col];
            if (f == 0) continue;
            for (int k = col; k < 9; k++) a[r][k] -= f * a[col][k];
        }
    }
    for (int r = 0; r < 8; r++) a[r][8] /= a[r][r];
    return 1;
}

selphy_status selphy_homography4(const selphy_point src[4], const selphy_point dst[4], double h[9]) {
    if (src == NULL || dst == NULL || h == NULL) return SELPHY_ERR_ARGUMENT;
    double a[8][9];
    for (int i = 0; i < 4; i++) {
        double x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
        double r0[9] = { x, y, 1, 0, 0, 0, -u * x, -u * y, u };
        double r1[9] = { 0, 0, 0, x, y, 1, -v * x, -v * y, v };
        memcpy(a[2 * i], r0, sizeof r0);
        memcpy(a[2 * i + 1], r1, sizeof r1);
    }
    if (!solve8(a)) return SELPHY_ERR_ARGUMENT;
    for (int i = 0; i < 8; i++) h[i] = a[i][8];
    h[8] = 1.0;
    return SELPHY_OK;
}

selphy_point selphy_homography_apply(const double h[9], selphy_point p) {
    double w = h[6] * p.x + h[7] * p.y + h[8];
    selphy_point out = { (h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w };
    return out;
}

/* ---- Corner marks ---------------------------------------------------------------------- */

typedef struct { double cx, cy; long area; long w, h; } candidate;

static double cross(selphy_point o, selphy_point a, selphy_point b) {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

static int compare_points(const void *pa, const void *pb) {
    const selphy_point *a = pa, *b = pb;
    if (a->x != b->x) return a->x < b->x ? -1 : 1;
    if (a->y != b->y) return a->y < b->y ? -1 : 1;
    return 0;
}

typedef struct { selphy_point p; int index; } indexed_point;

static int compare_indexed(const void *pa, const void *pb) {
    return compare_points(&((const indexed_point *)pa)->p, &((const indexed_point *)pb)->p);
}

/* Convex hull vertices (Andrew's monotone chain, collinear points dropped, as qhull does).
   Writes candidate indices into hull and returns their count. */
static int convex_hull(const candidate *c, int n, int *hull) {
    indexed_point *pts = malloc(sizeof *pts * (size_t)n);
    indexed_point *chain = malloc(sizeof *chain * (size_t)(2 * n + 1));
    if (pts == NULL || chain == NULL) { free(pts); free(chain); return -1; }
    for (int i = 0; i < n; i++) { pts[i].p.x = c[i].cx; pts[i].p.y = c[i].cy; pts[i].index = i; }
    qsort(pts, (size_t)n, sizeof *pts, compare_indexed);
    int k = 0;
    for (int i = 0; i < n; i++) {
        while (k >= 2 && cross(chain[k - 2].p, chain[k - 1].p, pts[i].p) <= 0) k--;
        chain[k++] = pts[i];
    }
    for (int i = n - 2, t = k + 1; i >= 0; i--) {
        while (k >= t && cross(chain[k - 2].p, chain[k - 1].p, pts[i].p) <= 0) k--;
        chain[k++] = pts[i];
    }
    int count = k > 1 ? k - 1 : k;
    for (int i = 0; i < count; i++) hull[i] = chain[i].index;
    free(pts);
    free(chain);
    return count;
}

typedef struct { double angle; int index; } angled;

static int compare_angles(const void *pa, const void *pb) {
    double a = ((const angled *)pa)->angle, b = ((const angled *)pb)->angle;
    return a < b ? -1 : (a > b ? 1 : 0);
}

/* Orders four candidates by angle around their centroid (clockwise on screen, y down) and
   returns the area of that quadrilateral. */
static double quad_area(const candidate *c, const int idx[4], int ordered[4]) {
    double mx = 0, my = 0;
    for (int i = 0; i < 4; i++) { mx += c[idx[i]].cx; my += c[idx[i]].cy; }
    mx /= 4; my /= 4;
    angled a[4];
    for (int i = 0; i < 4; i++) {
        a[i].angle = atan2(c[idx[i]].cy - my, c[idx[i]].cx - mx);
        a[i].index = idx[i];
    }
    qsort(a, 4, sizeof a[0], compare_angles);
    double area = 0;
    for (int i = 0; i < 4; i++) {
        const candidate *p = &c[a[i].index], *q = &c[a[(i + 1) % 4].index];
        area += p->cx * q->cy - q->cx * p->cy;
        ordered[i] = a[i].index;
    }
    return 0.5 * fabs(area);
}

static double distance(selphy_point a, selphy_point b) { return hypot(a.x - b.x, a.y - b.y); }

selphy_status selphy_chart_find_marks(
    const uint16_t *rgb16, size_t width, size_t height,
    const uint8_t *scanner_icc, size_t scanner_icc_size,
    double chart_aspect, selphy_point out_marks[4]) {
    if (rgb16 == NULL || out_marks == NULL || width == 0 || height == 0 || !(chart_aspect > 0)) return SELPHY_ERR_ARGUMENT;

    /* Block-mean reduction, as _downsample: factor = max(h, w) // 1400, at least 1. */
    size_t longest = width > height ? width : height;
    size_t factor = longest / DOWNSAMPLE_TARGET;
    if (factor < 1) factor = 1;
    size_t sw = width / factor, sh = height / factor, n = sw * sh;
    if (n == 0) return SELPHY_ERR_ARGUMENT;
    uint16_t *small = malloc(n * 3 * sizeof *small);
    double *lab = malloc(n * 3 * sizeof *lab);
    unsigned char *dark = malloc(n);
    int *labels = calloc(n, sizeof *labels);
    size_t *stack = malloc(n * sizeof *stack);
    candidate *cands = NULL;
    selphy_status status = SELPHY_ERR_MEMORY;
    if (small == NULL || lab == NULL || dark == NULL || labels == NULL || stack == NULL) goto done;
    for (size_t y = 0; y < sh; y++) {
        for (size_t x = 0; x < sw; x++) {
            for (int ch = 0; ch < 3; ch++) {
                unsigned long long sum = 0;
                for (size_t dy = 0; dy < factor; dy++) {
                    const uint16_t *row = rgb16 + ((y * factor + dy) * width + x * factor) * 3;
                    for (size_t dx = 0; dx < factor; dx++) sum += row[dx * 3 + ch];
                }
                small[(y * sw + x) * 3 + ch] = (uint16_t)(sum / (factor * factor));
            }
        }
    }
    status = selphy_source_to_lab(scanner_icc, scanner_icc_size, small, lab, n);
    if (status != SELPHY_OK) goto done;
    for (size_t i = 0; i < n; i++) dark[i] = lab[i * 3] < DARK_L;

    /* Connected components, 4-connectivity, labelled in raster order (as scipy.ndimage.label). */
    size_t capacity = 64, count = 0;
    cands = malloc(capacity * sizeof *cands);
    if (cands == NULL) { status = SELPHY_ERR_MEMORY; goto done; }
    int next_label = 0;
    for (size_t start = 0; start < n; start++) {
        if (!dark[start] || labels[start] != 0) continue;
        next_label++;
        size_t top = 0;
        stack[top++] = start;
        labels[start] = next_label;
        long area = 0;
        double sx = 0, sy = 0;
        size_t minx = sw, maxx = 0, miny = sh, maxy = 0;
        while (top > 0) {
            size_t p = stack[--top];
            size_t px = p % sw, py = p / sw;
            area++;
            sx += (double)px;
            sy += (double)py;
            if (px < minx) minx = px;
            if (px > maxx) maxx = px;
            if (py < miny) miny = py;
            if (py > maxy) maxy = py;
            size_t neighbours[4];
            int k = 0;
            if (px > 0) neighbours[k++] = p - 1;
            if (px + 1 < sw) neighbours[k++] = p + 1;
            if (py > 0) neighbours[k++] = p - sw;
            if (py + 1 < sh) neighbours[k++] = p + sw;
            for (int q = 0; q < k; q++) {
                size_t m = neighbours[q];
                if (dark[m] && labels[m] == 0) {
                    labels[m] = next_label;
                    stack[top++] = m;
                }
            }
        }
        long w = (long)(maxx - minx + 1), h = (long)(maxy - miny + 1);
        double ratio = (double)w / (double)h;
        if (area < MIN_AREA || !(ratio > 0.75 && ratio < 1.33) || (double)area / (double)(w * h) < 0.8) continue;
        if (count == capacity) {
            capacity *= 2;
            candidate *grown = realloc(cands, capacity * sizeof *cands);
            if (grown == NULL) { status = SELPHY_ERR_MEMORY; goto done; }
            cands = grown;
        }
        candidate c = { sx / (double)area, sy / (double)area, area, w, h };
        cands[count++] = c;
    }
    if (count < 4) { status = SELPHY_ERR_CHART_MARKS; goto done; }

    /* The four marks spanning the largest quadrilateral, among the hull vertices. */
    int *hull = malloc(sizeof *hull * (count + 1));
    if (hull == NULL) { status = SELPHY_ERR_MEMORY; goto done; }
    int hn;
    if (count > 4) {
        hn = convex_hull(cands, (int)count, hull);
    } else {
        hn = 4;
        for (int i = 0; i < 4; i++) hull[i] = i;
    }
    if (hn < 4) { free(hull); status = hn < 0 ? SELPHY_ERR_MEMORY : SELPHY_ERR_CHART_MARKS; goto done; }
    int best[4] = { 0, 0, 0, 0 };
    double best_area = -1;
    for (int a = 0; a < hn; a++)
        for (int b = a + 1; b < hn; b++)
            for (int c = b + 1; c < hn; c++)
                for (int d = c + 1; d < hn; d++) {
                    int idx[4] = { hull[a], hull[b], hull[c], hull[d] }, ordered[4];
                    double area = quad_area(cands, idx, ordered);
                    if (area > best_area) { best_area = area; memcpy(best, ordered, sizeof best); }
                }
    free(hull);

    int big = 0;
    for (int i = 1; i < 4; i++) if (cands[best[i]].area > cands[best[big]].area) big = i;
    double others = 0;
    for (int i = 0; i < 4; i++) if (i != big) others += (double)cands[best[i]].area;
    double ratio = (double)cands[best[big]].area / (others / 3.0);
    if (!(ratio > 1.5 && ratio < 3.2)) { status = SELPHY_ERR_CHART_ORIENTATION; goto done; }

    selphy_point centres[4];
    for (int k = 0; k < 4; k++) {
        const candidate *m = &cands[best[(big + k) % 4]];
        centres[k].x = m->cx * (double)factor + (double)factor / 2.0;
        centres[k].y = m->cy * (double)factor + (double)factor / 2.0;
    }
    double scan_w = (distance(centres[1], centres[0]) + distance(centres[2], centres[3])) / 2;
    double scan_h = (distance(centres[3], centres[0]) + distance(centres[2], centres[1])) / 2;
    if (fabs((scan_w / scan_h) / chart_aspect - 1) > 0.04) { status = SELPHY_ERR_CHART_SHAPE; goto done; }
    memcpy(out_marks, centres, sizeof centres);
    status = SELPHY_OK;

done:
    free(small);
    free(lab);
    free(dark);
    free(labels);
    free(stack);
    free(cands);
    return status;
}

/* ---- Patch sampling -------------------------------------------------------------------- */

static int compare_u16(const void *pa, const void *pb) {
    uint16_t a = *(const uint16_t *)pa, b = *(const uint16_t *)pb;
    return (a > b) - (a < b);
}

selphy_status selphy_chart_sample(
    const uint16_t *rgb16, size_t width, size_t height,
    const double h[9], const double *rects, size_t rect_count,
    double inner, unsigned grid, uint16_t *out_rgb16) {
    if (rgb16 == NULL || h == NULL || rects == NULL || out_rgb16 == NULL || grid == 0 || width == 0 || height == 0)
        return SELPHY_ERR_ARGUMENT;
    size_t samples = (size_t)grid * grid;
    uint16_t *values = malloc(samples * 3 * sizeof *values);
    if (values == NULL) return SELPHY_ERR_MEMORY;
    for (size_t r = 0; r < rect_count; r++) {
        double x = rects[r * 4], y = rects[r * 4 + 1], w = rects[r * 4 + 2], hh = rects[r * 4 + 3];
        size_t k = 0;
        for (unsigned j = 0; j < grid; j++) {
            double t = grid > 1 ? (double)j / (double)(grid - 1) : 0.0;
            double py = y + hh * (0.5 + (t - 0.5) * inner);
            for (unsigned i = 0; i < grid; i++) {
                double s = grid > 1 ? (double)i / (double)(grid - 1) : 0.0;
                selphy_point p = { x + w * (0.5 + (s - 0.5) * inner), py };
                selphy_point q = selphy_homography_apply(h, p);
                double qx = nearbyint(q.x), qy = nearbyint(q.y);
                if (qx < 0) qx = 0;
                if (qy < 0) qy = 0;
                if (qx > (double)(width - 1)) qx = (double)(width - 1);
                if (qy > (double)(height - 1)) qy = (double)(height - 1);
                const uint16_t *px = rgb16 + ((size_t)qy * width + (size_t)qx) * 3;
                for (int ch = 0; ch < 3; ch++) values[ch * samples + k] = px[ch];
                k++;
            }
        }
        for (int ch = 0; ch < 3; ch++) {
            uint16_t *v = values + ch * samples;
            qsort(v, samples, sizeof *v, compare_u16);
            uint32_t median = samples % 2 ? v[samples / 2] : ((uint32_t)v[samples / 2 - 1] + v[samples / 2]) / 2;
            out_rgb16[r * 3 + ch] = (uint16_t)median;
        }
    }
    free(values);
    return SELPHY_OK;
}
