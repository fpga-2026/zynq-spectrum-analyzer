/*
 * ad_snapshot_stage3_main.c  --  stage 3: binary streaming + two-level calibration
 *
 * Everything here is PS software: the PL (BD, FFT, DMA, mux, DDS, AD) is
 * untouched, so the already-verified DDS / FFT / DMA / MUX links cannot break.
 * The AXI DMA already delivers the complete 8192-point complex FFT frame to DDR,
 * so the PS has everything needed for display, calibration and cross-checking.
 *
 * RUN_MODE = 1 : binary stream  (for the live host viewer)
 * RUN_MODE = 0 : calibration report (two-level self-calibration + cross-check)
 *
 * Binary packet (little endian, 36 + 2*NBINS + 2 bytes):
 *   0  2  sync 0x55 0xAA
 *   2  2  seq
 *   4  2  n_bins            = NBINS
 *   6  2  flags             bit0 quality_pass, bit1 peak_valid,
 *                           bit2 xcheck_ok, bit3 channel (1 = DDS, 0 = AD)
 *   8  2  peak_idx
 *  10  2  ped_dbc   (i16)
 *  12  2  skirt_dbc (i16)
 *  14  2  far_dbc   (i16)
 *  16  4  peak_mag        (PS |X| at peak_idx)
 *  20  4  dc_mag          (PS |X[0]|)
 *  24  4  hw_peak_mag_sq  (PL peak detector)
 *  28  2  hw_peak_idx
 *  30  2  cap_us
 *  32  4  t_us
 *  36  2*N magnitudes (u16, bins 0..NBINS-1)
 *  36+2*N  2  checksum = sum of the preceding bytes, low 16 bits
 *
 * UART: 230400 baud.  The PS UART reference clock is 100 MHz (verified in the
 * BSP: XPAR_XUARTPS_0_UART_CLK_FREQ_HZ = 100000000), so 230400 divides by 27 to
 * 231481 Bd (+0.47% - safe).  460800 would divide by 14 -> 446429 Bd (-3.12%,
 * marginal), which is why 230400 was chosen.  At 230400 a 2086-byte packet
 * gives about 11 frames/s.
 *
 * Calibration (RUN_MODE = 0):
 *   L1  DDS reference  -> backend bin mapping / amplitude / leakage baseline
 *   L2  DA -> AD       -> front-end offset and amplitude in ADC LSB
 *   XCHK              -> PL peak detector vs PS peak, per frame
 *
 * Scaling note (measured on this board): with the scaled 8192-point FFT the
 * output satisfies |X[k]| = A/2 for a full-scale sine of amplitude A, and
 * |X[0]| = (DC level).  The AD path applies x512 digital gain, so
 *     ADC residual offset [LSB] = dc_mag / 512
 *     ADC tone amplitude [LSB]  = peak_mag * 2 / 512 = peak_mag / 256
 * which reproduces the analog measurements (0.45 LSB offset, 23.2 LSB tone).
 */

#include <stdio.h>
#include "xil_printf.h"
#include "xparameters.h"
#include "xil_cache.h"
#include "xil_types.h"
#include "xaxidma.h"
#include "xstatus.h"
#include "xtime_l.h"
#include "xgpio.h"
#include "xuartps.h"
#include "xuartps_hw.h"
#include "sleep.h"

/* ---------------- user switches ---------------- */
#define RUN_MODE          1        /* 1 = stream, 0 = calibration, 4 = DA sweep */
#define UART_BAUD         230400U
#define NBINS             1024U    /* bins sent to the host: 0..1023 */
#define AVE_N             1U       /* clean frames averaged per packet (1..8) */
#define STREAM_CHANNEL    0        /* 1 = stream the DDS reference path, 0 = AD path */

/* DA sweep register (axi_gpio_0, 32 bit): bit31 = sweep_en, [30:0] = pinc.
 * f_out = pinc * 32 MHz / 2^31, so pinc = f * 2^31 / 32e6 = f * 67.108864. */
#define DA_GPIO_ID        XPAR_AXI_GPIO_0_DEVICE_ID
#define DA_SWEEP_EN       0x80000000U
#define DA_PINC(hz)       ((u32)((((u64)(hz)) * 2147483648ULL + 16000000ULL) / 32000000ULL))

/* Channel dependent quality gate (evaluated at RUN time, because the mux can be
 * switched from the host with 'A'/'D').  -46 dBc is tuned for the ANALOG path,
 * where the intermittent board-level interference is what the gate must remove.
 * The DIGITAL DDS reference has no such interference, but its 10.000000 MHz tone
 * falls on bin 819.2 (0.2 bin off a bin centre), so rectangular-window leakage
 * 4..24 bins away is only about -30 dBc (theory -30, measured far band -64 dBc vs
 * theory -62 dBc).  A -46 dBc gate would reject EVERY DDS frame - that is exactly
 * why the first DDS stream run produced 0 packets.  So the DDS channel is not
 * gated at all (threshold -100 dBc never triggers). */

#define QUALITY_GATE      1
#define QUALITY_MIN_DBC   (-46)    /* keep only frames with pedestal <= this */
#define SKIP_FRAMES       3U
#define WAIT_TIMEOUT_MS   50U
#define K_CAL             16U      /* frames averaged per calibration step */

/* ---------------- fixed configuration ---------------- */
#define DMA_DEV_ID        XPAR_AXIDMA_0_DEVICE_ID
#define GPIO_CAP_ID       XPAR_AXI_GPIO_4_DEVICE_ID   /* Ch1 = mux sel, Ch2 = cap_start */
#define GPIO_PEAK_ID      XPAR_AXI_GPIO_2_DEVICE_ID   /* Ch1 = peak_mag_sq, Ch2 = peak_idx */

#define FFT_POINTS        8192
#define BYTES_PER_SAMP    4
#define BUF_SIZE          (FFT_POINTS * BYTES_PER_SAMP)
#define DDR_RX_BASE       0x11000000U

#define FS_AD             32000000U   /* AD path sample rate */
#define FS_DDS            100000000U  /* DDS path sample rate */
#define BIN_AD            (FS_AD / FFT_POINTS)      /* 3906.25 Hz */
#define TONE_BIN_AD       32          /* 125 kHz */

XAxiDma AxiDma;
XGpio   GpioCap;
XGpio   GpioPeak;
XGpio   GpioDa;      /* axi_gpio_0: DA sweep control */
XUartPs Uart;

static u64 timeout_ticks;
static u32 g_cap_us, g_loop_us, g_t_us;
static u32 g_sel;                     /* current mux channel */
/* 1 = force the DA path onto the 125 kHz calibrator before every capture.
 * ctrl crosses 100 MHz -> 32 MHz with no CDC, so a single write can be sampled
 * incoherently (a mix of old and new bits) and that wrong value then sticks.
 * Re-writing 0 before each capture is safe: 0 -> 0 has no bit transitions. */
static u32 g_park_da = 1;
#define HALF_BINS (FFT_POINTS / 2)      /* bins 0..4095 of the 8192-point FFT */
static u32 mag_acc[NBINS];
static u16 mag_out[NBINS];
static u16 mags_all[HALF_BINS];         /* per-frame |X| scratch (one isqrt/bin) */
static u8  txbuf[96 + NBINS * 2 + 8];

/* coarse signal classes (relative to the peak level, so rectangular-window
 * leakage can never be mistaken for extra tones) */
#define CLS_NONE       0
#define CLS_CW         1
#define CLS_MULTITONE  2
#define CLS_WIDEBAND   3
#define CLS_CW_NOISE   4

typedef struct {
    u32 peak_idx, peak_mag, peak_mag_sq, dc_mag, nz;
    int ped, skirt, far;
    /* instrument metrics */
    u32 floor_mag;                 /* mean |X| outside the peak main lobe      */
    u16 n_peaks;                   /* significant components (>= -20 dBc)      */
    u16 occ_x10;                   /* occupancy above -20 dBc, in 0.1 %        */
    int snr_db;                    /* 20log10(peak / floor)                    */
    int sfdr_dbc;                  /* 20log10(peak / largest spur)             */
    int thd_dbc;                   /* harmonics 2..5                           */
    int sinad_db;                  /* signal / (everything else)               */
    int enob_x10;                  /* (SINAD - 1.76) / 6.02, x10               */
    u16 cls;                       /* CLS_*                                    */
} fmet_t;

/* ------------------------------------------------------------------ helpers */
static u32 isqrt32(u32 x)
{
    u32 lo = 0, hi = 46341U;
    while (lo < hi) {
        u32 mid = (lo + hi + 1U) >> 1;
        if (mid * mid <= x) lo = mid;
        else                hi = mid - 1U;
    }
    return lo;
}

/* integer 20*log10(num/den), 1 dB resolution, 0..-100 dB */
static int dbc1(u32 num, u32 den)
{
    u64 r;
    int d = 0;
    if (den == 0) den = 1;
    if (num == 0) return -100;
    r = ((u64)num * 1000000ULL) / (u64)den;
    while (r < 1000000ULL && d < 100)  { r = (r * 1122018ULL) / 1000000ULL; d++; }
    while (r > 1000000ULL && d > -100) { r = (r * 891251ULL) / 1000000ULL;  d--; }
    return -d;
}

/* integer 10*log10(num/den) - power ratio, 1 dB resolution */
static int dbp10(u64 num, u64 den)
{
    u64 r;
    int d = 0;
    if (den == 0ULL) den = 1ULL;
    if (num == 0ULL) return -100;
    r = (num * 1000000ULL) / den;
    while (r < 1000000ULL && d < 100)  { r = (r * 1122018ULL) / 1000000ULL; d++; }
    while (r > 1000000ULL && d > -100) { r = (r * 891251ULL) / 1000000ULL;  d--; }
    return -d;
}

static inline u32 bin_mag(u32 raw)
{
    s16 re = (s16)(raw & 0xFFFF);
    s16 im = (s16)((raw >> 16) & 0xFFFF);
    return isqrt32((u32)((s32)re * (s32)re + (s32)im * (s32)im));
}

static inline u32 bin_mag_sq(u32 raw)
{
    s16 re = (s16)(raw & 0xFFFF);
    s16 im = (s16)((raw >> 16) & 0xFFFF);
    return (u32)((s32)re * (s32)re + (s32)im * (s32)im);
}

/* ------------------------------------------------------------- peripheral IO */
static int dma_hard_reset(void)
{
    u32 guard = 0;
    XAxiDma_Reset(&AxiDma);
    while (!XAxiDma_ResetIsDone(&AxiDma)) {
        if (++guard > 10000000U) return XST_FAILURE;
    }
    return XST_SUCCESS;
}

static int init_periph(void)
{
    XUartPs_Config *ucfg;
    int st;

    st = XGpio_Initialize(&GpioCap, GPIO_CAP_ID);
    if (st != XST_SUCCESS) return XST_FAILURE;
    XGpio_SetDataDirection(&GpioCap, 1, 0x00000000);
    XGpio_SetDataDirection(&GpioCap, 2, 0x00000000);
    XGpio_DiscreteWrite(&GpioCap, 1, 0U);
    XGpio_DiscreteWrite(&GpioCap, 2, 0U);

    st = XGpio_Initialize(&GpioPeak, GPIO_PEAK_ID);
    if (st != XST_SUCCESS) return XST_FAILURE;
    XGpio_SetDataDirection(&GpioPeak, 1, 0xFFFFFFFF);
    XGpio_SetDataDirection(&GpioPeak, 2, 0xFFFFFFFF);

    /* Park the DA path on the stock 125 kHz calibrator (sweep_en = 0).
     * IMPORTANT: downloading a new application does not reset the PL, so an
     * earlier sweep run can leave axi_gpio_0 holding a pinc value - with
     * sweep_en still set the DA would keep playing a programmable tone. */
    st = XGpio_Initialize(&GpioDa, DA_GPIO_ID);
    if (st == XST_SUCCESS) {
        XGpio_SetDataDirection(&GpioDa, 1, 0x00000000);
        XGpio_DiscreteWrite(&GpioDa, 1, 0x00000000U);
    }

    /* raise the console baud rate before printing anything */
    ucfg = XUartPs_LookupConfig(XPAR_XUARTPS_0_DEVICE_ID);
    if (!ucfg) return XST_FAILURE;
    st = XUartPs_CfgInitialize(&Uart, ucfg, ucfg->BaseAddress);
    if (st != XST_SUCCESS) return XST_FAILURE;
    XUartPs_SetBaudRate(&Uart, UART_BAUD);

    return XST_SUCCESS;
}

static void set_channel(u32 sel)
{
    g_sel = sel;
    XGpio_DiscreteWrite(&GpioCap, 1, sel);
}

/* Gate threshold per channel, evaluated at run time.
 *
 * ped is a dBc value and is ALWAYS <= 0, and the test is "ped > threshold means
 * dirty".  So a threshold must be moved UP (towards 0) to be more permissive:
 * using -100 for "never gate" is exactly backwards - it is the strictest
 * possible gate and silently rejects every DDS frame (that bug kept the DDS
 * channel completely silent: no packets at all, USB LED never blinked).
 * 0 dBc is the correct "never gate" value because ped > 0 is never true. */
#define GATE_DDS_DBC   0        /* ped <= 0 always -> this never gates */

static int gate_min_dbc(void)
{
    return g_sel ? (GATE_DDS_DBC) : (QUALITY_MIN_DBC);   /* DDS: no gate, AD: -46 */
}

/* Runtime channel switch from the host: send 'D' for the DDS reference path or
 * 'A' for the analog path.  The mux select is just an AXI GPIO, so switching is
 * one register write - no rebuild needed.  RX is polled here for the same reason
 * TX is (see uart_send_raw below): the interrupt driven API never gets serviced. */
static void poll_channel_cmd(void)
{
    u32 sr = XUartPs_ReadReg(Uart.Config.BaseAddress, XUARTPS_SR_OFFSET);
    u8  c;

    if (sr & XUARTPS_SR_RXEMPTY) return;

    c = (u8)(XUartPs_ReadReg(Uart.Config.BaseAddress, XUARTPS_FIFO_OFFSET) & 0xFF);
    if ((c == 'D') || (c == 'd')) {
        if (g_sel != 1U) {
            set_channel(1U);
            xil_printf("\r\n[ch] DDS reference path (Fs=100MHz, 12.207kHz/bin)\r\n");
        }
    }
    else if ((c == 'A') || (c == 'a')) {
        if (g_sel != 0U) {
            set_channel(0U);
            xil_printf("\r\n[ch] AD analog path (Fs=32MHz, 3.906kHz/bin)\r\n");
        }
    }
}

/* Blocking, fully polled UART send.
 *
 * Do NOT use XUartPs_Send() here: in this BSP (uartps_v3_7) it is the
 * *interrupt driven* entry point - it just fills the 64-byte TX FIFO and relies
 * on transmit interrupts/callbacks to push the rest.  With no interrupt setup
 * only the first ~64 bytes of each 2086-byte packet reached the wire, which
 * looked like "9 checksum errors, 0 good packets" on the host.
 * Writing the FIFO directly is polled, blocking and needs no interrupts. */
static void uart_send_raw(const u8 *p, u32 n)
{
    while (n--) {
        while (XUartPs_IsTransmitFull(Uart.Config.BaseAddress)) {
            /* wait for room in the 64-byte TX FIFO */
        }
        XUartPs_WriteReg(Uart.Config.BaseAddress, XUARTPS_FIFO_OFFSET, (u32)*p++);
    }
}

/* --------------------------------------------------------------- acquisition */
static int capture_one_frame(void)
{
    /* keep the DA on the stock calibrator unless a sweep is running */
    if (g_park_da) XGpio_DiscreteWrite(&GpioDa, 1, 0x00000000U);

    XTime t0, t1;
    int st;

    XGpio_DiscreteWrite(&GpioCap, 2, 0U);
    Xil_DCacheInvalidateRange((UINTPTR)DDR_RX_BASE, BUF_SIZE);

    st = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)DDR_RX_BASE,
                                BUF_SIZE, XAXIDMA_DEVICE_TO_DMA);
    if (st != XST_SUCCESS) {
        xil_printf("DMA arm failed %d\r\n", st);
        dma_hard_reset();
        return -1;
    }

    XGpio_DiscreteWrite(&GpioCap, 2, 1U);
    usleep(10);
    XGpio_DiscreteWrite(&GpioCap, 2, 0U);

    XTime_GetTime(&t0);
    while (XAxiDma_Busy(&AxiDma, XAXIDMA_DEVICE_TO_DMA)) {
        XTime_GetTime(&t1);
        if ((u64)(t1 - t0) > timeout_ticks) {
            xil_printf("DMA TIMEOUT\r\n");
            dma_hard_reset();
            return -2;
        }
    }

    Xil_DCacheInvalidateRange((UINTPTR)DDR_RX_BASE, BUF_SIZE);
    XTime_GetTime(&t1);
    g_cap_us  = (u32)(((u64)(t1 - t0) * 1000000ULL) / (u64)COUNTS_PER_SECOND);
    g_t_us    = (u32)((u64)t1 / (u64)(COUNTS_PER_SECOND / 1000000U));
    return 0;
}

/* --------------------------------------------------------------- frame maths */
/* One isqrt per bin: |X| is cached in mags_all[] and every metric below is then a
 * cheap scan of that array.  Produces the peak, DC, the three dBc bands and the
 * instrument metrics (floor, SNR, SFDR, THD, SINAD, ENOB) plus a coarse class. */
static void analyze_frame(volatile u32 *buf, fmet_t *m, int accumulate)
{
    u32 i, mag, d, s1 = 0, n1 = 0, s2 = 0, n2 = 0, s3 = 0, n3 = 0, msq;
    u32 f0, best = 0, n_pk = 0, n_occ = 0, s_floor = 0, c_floor = 0;
    u64 p_sig = 0, p_rest = 0, p_h = 0;

    /* ---- pass 1: cache |X|, find the peak of the lower half (skip DC area) --- */
    m->peak_idx = 0; m->peak_mag = 0; m->peak_mag_sq = 0; m->nz = 0;
    for (i = 0; i < HALF_BINS; i++) {
        u32 raw = buf[i];
        mag = bin_mag(raw);
        mags_all[i] = (mag > 0xFFFFU) ? 0xFFFFU : (u16)mag;
        if (i >= 5U && mag > m->peak_mag) {
            m->peak_mag    = mag;
            m->peak_idx    = i;
            m->peak_mag_sq = bin_mag_sq(raw);
        }
    }
    f0  = m->peak_idx;
    msq = m->peak_mag ? m->peak_mag : 1U;
    m->dc_mag = mags_all[0];

    /* ---- bands / nonzero count / averaging accumulator ---- */
    for (i = 1; i < HALF_BINS; i++) {
        mag = mags_all[i];
        if (mag) m->nz++;
        if (accumulate && i < NBINS) mag_acc[i] += mag;
        if (i == f0) continue;
        d = (i > f0) ? (i - f0) : (f0 - i);
        if      (d >= 4   && d <= 24)  { s1 += mag; n1++; }
        else if (d >= 40  && d <= 120) { s2 += mag; n2++; }
        else if (d >= 150 && d <= 600) { s3 += mag; n3++; }
    }
    m->ped   = dbc1(n1 ? s1 / n1 : 1, msq);
    m->skirt = dbc1(n2 ? s2 / n2 : 1, msq);
    m->far   = dbc1(n3 ? s3 / n3 : 1, msq);

    /* ---- noise floor: mean |X| of the bins outside the peak +-64 ---- */
    for (i = 1; i < HALF_BINS; i++) {
        if (i + 64U > f0 && i < f0 + 64U) continue;
        s_floor += mags_all[i]; c_floor++;
    }
    m->floor_mag = c_floor ? (s_floor / c_floor) : 1U;

    /* ---- signal / spurious power, occupancy, significant peaks ---- */
    {
        u32 thr_sig = msq / 10U;                      /* -20 dBc of the peak */
        for (i = 1; i < HALF_BINS; i++) {
            u64 p = (u64)mags_all[i] * (u64)mags_all[i];
            if (i + 8U >= f0 && i <= f0 + 8U) { p_sig += p; continue; }
            p_rest += p;
            if (mags_all[i] > thr_sig) n_occ++;
            if (i >= 2U && (i + 2U) < HALF_BINS &&
                mags_all[i] > mags_all[i - 1U] && mags_all[i] > mags_all[i + 1U] &&
                mags_all[i] > thr_sig &&
                (i + 16U < f0 || i > f0 + 16U)) {     /* ignore the main-lobe skirt */
                n_pk++;
                if (mags_all[i] > best) best = mags_all[i];
            }
        }
    }
    m->n_peaks  = (u16)(n_pk + 1U);                   /* the main peak itself */
    m->occ_x10  = (u16)((n_occ * 1000U) / (HALF_BINS - 1U));
    m->snr_db   = (int)(-dbc1(m->floor_mag, msq));
    /* SFDR: largest spurious line OUTSIDE the carrier's +/-8 bins (the old
     * version compared the peak with itself, so it always read 0 dBc). */
    {
        u32 spur = 1U;
        for (i = 1; i < HALF_BINS; i++) {
            if (i + 8U >= f0 && i <= f0 + 8U) continue;
            if (mags_all[i] > spur) spur = mags_all[i];
        }
        m->sfdr_dbc = (int)(-dbc1(spur, msq));
        if (m->sfdr_dbc < 0) m->sfdr_dbc = 0;
    }
    /* SINAD = carrier power / (everything else in the band).
     * NOTE: p_rest is built from bin_mag() = integer sqrt of |X|^2, so bins whose
     * |X| rounds to 0/1 are under-weighted.  The number is therefore optimistic
     * at high SNR: treat it as "signal to spurs", not as the converter's SINAD.
     * The honest instrument figure is P/F; see the design document, section 4.3. */
    m->sinad_db = (int)dbp10(p_sig, p_rest);
    m->enob_x10 = (m->sinad_db > 2) ? (((m->sinad_db - 2) * 10) / 6) : 0;

    /* ---- THD: harmonics 2..5, when they fit in the lower half ---- */
    if (f0 >= 8U && (5U * f0) < HALF_BINS) {
        u32 h;
        for (h = 2U; h <= 5U; h++) {
            u32 hb = h * f0;
            p_h += (u64)mags_all[hb] * (u64)mags_all[hb];
        }
        m->thd_dbc = (int)dbp10(p_h, (u64)msq * (u64)msq);
    }
    else {
        m->thd_dbc = -100;
    }

    /* ---- coarse class ---- */
    if (m->peak_mag == 0U)        m->cls = CLS_NONE;
    else if (m->occ_x10 > 300U)   m->cls = CLS_WIDEBAND;
    else if (n_pk >= 2U)          m->cls = CLS_MULTITONE;
    else if (m->snr_db < 55)      m->cls = CLS_CW_NOISE;
    else                          m->cls = CLS_CW;
}

static void clear_acc(void)
{
    u32 i;
    for (i = 0; i < NBINS; i++) mag_acc[i] = 0;
}

static void average_acc(u32 n)
{
    u32 i;
    if (n == 0) n = 1;
    for (i = 0; i < NBINS; i++) {
        u32 v = mag_acc[i] / n;
        mag_out[i] = (v > 0xFFFFU) ? 0xFFFFU : (u16)v;
    }
}

/* ------------------------------------------------------------ binary packet */
static void put16(u32 *o, u32 v)
{
    txbuf[(*o)++] = (u8)(v & 0xFF);
    txbuf[(*o)++] = (u8)((v >> 8) & 0xFF);
}

static void put32(u32 *o, u32 v)
{
    put16(o, v & 0xFFFF);
    put16(o, (v >> 16) & 0xFFFF);
}

static void send_packet(u32 seq, u16 flags, fmet_t *m, u32 hw_mag_sq, u32 hw_idx)
{
    u32 i, o = 0, sum = 0;

    txbuf[o++] = 0x55;
    txbuf[o++] = 0xAA;
    put16(&o, seq);
    put16(&o, NBINS);
    put16(&o, flags);
    put16(&o, m->peak_idx & 0xFFFF);
    put16(&o, (u16)(s16)m->ped);
    put16(&o, (u16)(s16)m->skirt);
    put16(&o, (u16)(s16)m->far);
    put32(&o, m->peak_mag);
    put32(&o, m->dc_mag);
    put32(&o, hw_mag_sq);
    put16(&o, hw_idx & 0xFFFF);
    put16(&o, g_cap_us & 0xFFFF);
    put32(&o, g_t_us);
    /* ---- stage-3 instrument metrics (header is now 52 bytes) ---- */
    put16(&o, (u16)(s16)m->snr_db);
    put16(&o, (u16)(s16)m->sfdr_dbc);
    put16(&o, (u16)(s16)m->thd_dbc);
    put16(&o, (u16)(s16)m->sinad_db);
    put16(&o, (u16)(s16)m->enob_x10);
    put16(&o, (u16)(m->floor_mag & 0xFFFF));
    put16(&o, m->n_peaks);
    put16(&o, m->cls);

    for (i = 0; i < NBINS; i++) put16(&o, mag_out[i]);

    for (i = 0; i < o; i++) sum += txbuf[i];
    put16(&o, sum & 0xFFFF);

    uart_send_raw(txbuf, o);          /* polled - see uart_send_raw() */
}

/* -------------------------------------------------------------- calibration */
static void run_calibration(void)
{
    fmet_t m;
    volatile u32 *buf = (volatile u32 *)DDR_RX_BASE;
    u32 k, tries, acc_bad = 0, xchk_bad = 0, xchk_max = 0, xchk_n = 0;
    u32 xchk_mirror = 0, xchk_hw_idx = 0;
    u32 l1_peak_bin = 0, l1_peak_mag = 0, l1_dc = 0, l1_far = 0;
    u32 l2_peak_bin = 0, l2_peak_mag = 0, l2_dc = 0;

    xil_printf("\r\n=== CALIBRATION (RUN_MODE 0) ===\r\n");
    xil_printf("FFT %d pts, bin_ad=%d Hz, bin_dds=%d Hz, gain=512\r\n",
               FFT_POINTS, BIN_AD, FS_DDS / FFT_POINTS);

    /* ---------------- L1: DDS reference channel -> backend ---------------- */
    set_channel(1);
    usleep(2000);
    for (k = 0; k < SKIP_FRAMES; k++) {
        if (capture_one_frame() != 0) { xil_printf("CAL_L1 FAIL capture\r\n"); return; }
    }
    clear_acc();
    for (k = 0; k < K_CAL; k++) {
        if (capture_one_frame() != 0) { xil_printf("CAL_L1 FAIL capture\r\n"); return; }
        analyze_frame(buf, &m, 1);
        l1_peak_bin = m.peak_idx;
        l1_peak_mag = m.peak_mag;
        l1_dc       = m.dc_mag;
        l1_far      = m.far;
    }
    xil_printf("CAL_L1 peak_bin=%d (expect 819 = 10MHz/%dHz) peak_mag=%d dc=%d far=%ddBc\r\n",
               l1_peak_bin, FS_DDS / FFT_POINTS, l1_peak_mag, l1_dc, l1_far);
    xil_printf("CAL_L1 bin_err=%d bin_hz=%d\r\n",
               (int)l1_peak_bin - 819, BIN_AD);

    /* ---------------- L2: DA -> AD front-end ----------------------------- */
    set_channel(0);
    usleep(2000);
    for (k = 0; k < SKIP_FRAMES; k++) {
        if (capture_one_frame() != 0) { xil_printf("CAL_L2 FAIL capture\r\n"); return; }
    }
    clear_acc();
    tries = 0;
    k = 0;
    while (k < K_CAL && tries < 400U) {
        tries++;
        if (capture_one_frame() != 0) { xil_printf("CAL_L2 FAIL capture\r\n"); return; }
        analyze_frame(buf, &m, 1);
#if (QUALITY_GATE == 1)
        if (m.ped > QUALITY_MIN_DBC) { acc_bad++; continue; }
#endif
        k++;
        l2_peak_bin = m.peak_idx;
        l2_peak_mag = m.peak_mag;
        l2_dc       = m.dc_mag;

        /* Cross-check.  The PL detector scans the full 0..8191 spectrum while
         * the PS metrics only look at the lower half, so the PL may legitimately
         * latch the mirror bin (8192 - peak): a real FFT's two halves are exact
         * conjugates in theory but differ by a fraction of a count in fixed
         * point.  The meaningful test is therefore: does the PS reproduce the
         * PL's magnitude squared from the same DMA frame AT THE SAME BIN?
         * (Comparing indices instead flags every frame where the mirror wins by
         * one count - that was the bad=7 max_err=5717 seen on the first run.) */
        {
            u32 hw_mag = XGpio_DiscreteRead(&GpioPeak, 1);
            u32 hw_idx = XGpio_DiscreteRead(&GpioPeak, 2) & (FFT_POINTS - 1);
            u32 ps_sq  = bin_mag_sq(buf[hw_idx]);
            u32 err    = (hw_mag > ps_sq) ? (hw_mag - ps_sq) : (ps_sq - hw_mag);

            xchk_n++;
            if (err > 1U) {
                xchk_bad++;
                if (err > xchk_max) xchk_max = err;
            }
            else if (hw_idx != m.peak_idx) {
                xchk_mirror++;          /* PL reported the mirror image bin */
            }
            xchk_hw_idx = hw_idx;
        }
    }
    if (k == 0) { xil_printf("CAL_L2 FAIL no clean frame\r\n"); return; }
    average_acc(k);

    xil_printf("CAL_L2 frames=%d dropped=%d tone_bin=%d (expect %d) tone_mag=%d dc=%d\r\n",
               k, acc_bad, l2_peak_bin, TONE_BIN_AD, l2_peak_mag, l2_dc);
    xil_printf("CAL_L2 off_lsb=%d.%02d amp_lsb=%d.%02d (dc/512, mag/256)\r\n",
               (int)(l2_dc / 512), (int)(((l2_dc % 512) * 100) / 512),
               (int)(l2_peak_mag / 256), (int)(((l2_peak_mag % 256) * 100) / 256));
    xil_printf("CAL_L2 ped=%ddBc skirt=%ddBc far=%ddBc\r\n", m.ped, m.skirt, m.far);
    xil_printf("CAL_XCHK frames=%d bad=%d mirror=%d max_err=%d (last hw_idx=%d)\r\n",
               xchk_n, xchk_bad, xchk_mirror, xchk_max, xchk_hw_idx);
    xil_printf("CAL_DONE ok=%d\r\n",
               (xchk_bad == 0 && l2_peak_bin == TONE_BIN_AD &&
                (u32)((int)l1_peak_bin - 819) < 2) ? 1 : 0);
}

/* largest |X| within +-win bins of `centre`; returns the local peak bin.
 * Used by the DA sweep: the peak is searched around the expected bin instead of
 * over the whole spectrum, so an interference spur elsewhere cannot be picked. */
static u32 local_peak(volatile u32 *buf, u32 centre, u32 win, u32 *amp)
{
    u32 k, best_bin = centre, best = 0;
    u32 lo = (centre > win) ? (centre - win) : 1U;
    u32 hi = centre + win;
    if (hi >= HALF_BINS) hi = HALF_BINS - 1U;

    for (k = lo; k <= hi; k++) {
        u32 mag = bin_mag(buf[k]);
        if (mag > best) { best = mag; best_bin = k; }
    }
    *amp = best;
    return best_bin;
}

/* ---------------------------------------------- DA sweep (RUN_MODE 4) ------ */
/* Drives the DA through da_path_mux with a programmable tone, loops it back into
 * the AD path (blue SMA cable connected!), and measures the amplitude response
 * of the whole analog path.  Everything happens inside the PL/PS - no external
 * source, no extra pin.  At the end the DA is returned to the stock 125 kHz
 * calibrator so a later stream run sees the familiar spectrum. */
/* 20*log10(num/den) in 0.1 dB steps (attenuation is negative).
 * Same successive-multiply trick as dbc1(), but the step is 10^(1/200)=1.011579,
 * so one multiply equals 0.1 dB. Ten times finer than dbc1(), for the sweep curve. */
static int db_x10(u32 num, u32 den)
{
    u64 v;
    int n = 0;

    if (!num || !den) return 0;

    v = ((u64)num << 30) / (u64)den;            /* normalise to Q30 */
    while (v < (1ULL << 30) && n < 8000) {      /* num < den: multiply up */
        v = (v * 1060719ULL) >> 20;             /* x 1.011579 */
        n++;
    }
    while (v > (1ULL << 30) && n > -8000) {     /* num > den: divide down */
        v = (v << 20) / 1060719ULL;
        n--;
    }
    return -n;
}

static void run_sweep(void)
{
    volatile u32 *buf = (volatile u32 *)DDR_RX_BASE;
    fmet_t m;
    u32 i, k, f, exp_bin, bin, amp, amp_ref = 0;
    u32 amp_lo, amp_hi;
    int rel_db, rel_x10, rel_min = 9990, rel_max = -9990;
    int st;
    const u32 NAVG = 5;                /* frames averaged per frequency point */

    g_park_da = 0;                     /* this function owns the DA ctrl word */
    xil_printf("\r\n=== DA SWEEP (RUN_MODE 4) ===\r\n");
    xil_printf("blue SMA loopback DA->AD must be connected\r\n");

    st = XGpio_Initialize(&GpioDa, DA_GPIO_ID);
    if (st != XST_SUCCESS) { xil_printf("SWEEP FAIL gpio %d\r\n", st); return; }
    XGpio_SetDataDirection(&GpioDa, 1, 0x00000000);
    XGpio_DiscreteWrite(&GpioDa, 1, 0x00000000U);      /* back to the calibrator */

    /* check the loopback with the known 125 kHz tone before sweeping */
    for (k = 0; k < SKIP_FRAMES + 2U; k++) (void)capture_one_frame();
    analyze_frame(buf, &m, 0);
    xil_printf("SWEEP_REF125K bin=%d amp=%d dc=%d (expect bin 32, amp ~6000)\r\n",
               (int)m.peak_idx, (int)m.peak_mag, (int)m.dc_mag);

    xil_printf("SWEEP_BEGIN f_start=500000 f_step=500000 n=24 navg=%d\r\n", (int)NAVG);

    for (i = 0; i < 24U; i++) {
        u32 amp_sum = 0, n = 0;
        int comp_q8;

        f = 500000U + i * 500000U;
        XGpio_DiscreteWrite(&GpioDa, 1, DA_SWEEP_EN | DA_PINC(f));
        usleep(3000);

        /* drop two frames: the FIFO may still hold data from the old tone */
        for (k = 0; k < 2U; k++) (void)capture_one_frame();

        exp_bin = (u32)(((u64)f * (u64)FFT_POINTS) / (u64)FS_AD);
        bin     = exp_bin;
        amp_lo  = 0xFFFFFFFFU;
        amp_hi  = 0U;

        /* take NAVG frames, find the local peak in each, average */
        for (k = 0; k < NAVG; k++) {
            if (capture_one_frame() != 0) continue;
            analyze_frame(buf, &m, 0);
            bin = local_peak(buf, exp_bin, 32U, &amp);
            amp_sum += amp;
            n++;
            if (amp < amp_lo) amp_lo = amp;
            if (amp > amp_hi) amp_hi = amp;
        }
        if (n == 0U) { xil_printf("SWEEP FAIL capture f=%d\r\n", (int)f); continue; }
        amp = amp_sum / n;

        if (i == 0U) amp_ref = amp ? amp : 1U;

        /* rel_db: integer dB (kept for old logs); rel_x10: 0.1 dB, loss positive */
        rel_db  = (int)(-dbc1 (amp ? amp : 1U, amp_ref ? amp_ref : 1U));
        rel_x10 = (int)(-db_x10(amp ? amp : 1U, amp_ref ? amp_ref : 1U));
        if (rel_x10 < rel_min) rel_min = rel_x10;
        if (rel_x10 > rel_max) rel_max = rel_x10;

        /* display gain: multiply the shown magnitude by comp_q8/256 */
        comp_q8 = (int)((amp > 0U) ? ((u64)amp_ref * 256ULL / (u64)amp) : 256);
        if (comp_q8 > 4096) comp_q8 = 4096;

        xil_printf("SWEEP f_hz=%d exp_bin=%d bin=%d amp=%d amp_lo=%d amp_hi=%d "
                   "rel_db=%d rel_x10=%d comp_q8=%d dc=%d\r\n",
                   (int)f, (int)exp_bin, (int)bin, (int)amp, (int)amp_lo, (int)amp_hi,
                   rel_db, rel_x10, comp_q8, (int)m.dc_mag);
    }

    xil_printf("SWEEP_DONE n=24 navg=%d ampref=%d rel_min_x10=%d rel_max_x10=%d flat_x10=%d\r\n",
               (int)NAVG, (int)amp_ref, rel_min, rel_max, rel_max - rel_min);
    xil_printf("SWEEP note: rel_x10 is 0.1 dB units (loss positive), "
               "comp_q8/256 is the display gain\r\n");

    /* restore the calibrator */
    XGpio_DiscreteWrite(&GpioDa, 1, 0x00000000U);
    g_park_da = 1;
    usleep(2000);
    xil_printf("SWEEP restores the 125 kHz calibrator path\r\n");
}

/* ------------------------------------------------------------ binary stream */
static void run_stream(void)
{
    fmet_t m;
    u32 seq = 0, ave = 0, dropped = 0, xchk_bad = 0;
    volatile u32 *buf = (volatile u32 *)DDR_RX_BASE;

    xil_printf("\r\n=== BINARY STREAM (RUN_MODE 1) ===\r\n");
    xil_printf("baud=%d n_bins=%d packet=%d bytes ave=%d gate: AD %ddBc, DDS off\r\n",
               UART_BAUD, NBINS, (int)(52 + NBINS * 2 + 2), AVE_N, (int)QUALITY_MIN_DBC);
    xil_printf("initial channel=%s\r\n", STREAM_CHANNEL ? "DDS" : "AD");
    /* ---- axi_gpio_0 liveness probe -------------------------------------
     * XGpio_Initialize only reads xparameters.h, so it succeeds even when the
     * GPIO is not reachable in the running bitstream.  Write a pattern and read
     * it back: if it does not come back, every write to the DA sweep register
     * (and to the AD9833 SPI before it) silently went nowhere. */
    {
        u32 rb;
        XGpio_DiscreteWrite(&GpioDa, 1, 0x000000A5U);
        rb = XGpio_DiscreteRead(&GpioDa, 1);
        XGpio_DiscreteWrite(&GpioDa, 1, 0x00000000U);   /* back to calibrator */
        xil_printf("DA gpio: base=0x%08x wrote=0x000000a5 read=0x%08x -> %s\r\n",
                   (unsigned)GpioDa.BaseAddress, (unsigned)rb,
                   (rb == 0x000000A5U) ? "ALIVE" : "DEAD (bitstream/BD mismatch)");
    }
    xil_printf("DA ctrl parked=%d readback=0x%08x (expect 0x00000000)\r\n",
               (int)g_park_da, (unsigned)XGpio_DiscreteRead(&GpioDa, 1));
    xil_printf("send D or A to switch channel at run time\r\n");

    set_channel(STREAM_CHANNEL);
    usleep(2000);
    {
        u32 k;
        for (k = 0; k < SKIP_FRAMES; k++) (void)capture_one_frame();
    }
    clear_acc();

    while (1) {
        u32 hw_mag, hw_idx, err;
        u16 flags;

        poll_channel_cmd();                /* 'A' / 'D' from the host, live */

        if (capture_one_frame() != 0) continue;

        analyze_frame(buf, &m, 1);

#if (QUALITY_GATE == 1)
        if (m.ped > gate_min_dbc()) {
            dropped++;
            clear_acc();                       /* restart the averaging window */
            ave = 0;
            continue;
        }
#endif
        ave++;

        hw_mag = XGpio_DiscreteRead(&GpioPeak, 1);
        hw_idx = XGpio_DiscreteRead(&GpioPeak, 2) & (FFT_POINTS - 1);
        /* same rule as the calibration: compare at the bin the PL reported
         * (it may be the mirror bin, which is legitimate for a real FFT) */
        err    = (hw_mag > bin_mag_sq(buf[hw_idx]))
                 ? (hw_mag - bin_mag_sq(buf[hw_idx]))
                 : (bin_mag_sq(buf[hw_idx]) - hw_mag);

        if (ave < AVE_N) continue;

        average_acc(ave);
        clear_acc();
        ave = 0;

        flags = 0x0001;                                   /* quality pass */
        if (m.peak_mag) flags |= 0x0002;                  /* peak valid */
        if (err <= 1U)  flags |= 0x0004;                  /* xcheck ok */
        else            xchk_bad++;
        if (g_sel) flags |= 0x0008;

        send_packet(seq++, flags, &m, hw_mag, hw_idx);
        (void)xchk_bad;
    }
}

/* --------------------------------------------------------------------- main */
int main(void)
{
    XAxiDma_Config *Cfg;
    int st;

    if (init_periph() != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Cfg = XAxiDma_LookupConfig(DMA_DEV_ID);
    if (!Cfg) { xil_printf("DMA lookup failed\r\n"); return XST_FAILURE; }
    st = XAxiDma_CfgInitialize(&AxiDma, Cfg);
    if (st != XST_SUCCESS) { xil_printf("DMA init failed %d\r\n", st); return XST_FAILURE; }
    if (dma_hard_reset() != XST_SUCCESS) { xil_printf("DMA reset timeout\r\n"); return XST_FAILURE; }

    timeout_ticks = ((u64)COUNTS_PER_SECOND * (u64)WAIT_TIMEOUT_MS) / 1000U;

#if (RUN_MODE == 0)
    run_calibration();
    while (1) { sleep(1); }
#elif (RUN_MODE == 4)
    run_sweep();
    while (1) { sleep(1); }
#else
    run_stream();
    return XST_SUCCESS;
#endif
}






