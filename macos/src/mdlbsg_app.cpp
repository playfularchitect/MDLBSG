// v221: BITWISE CONTEXT MIXING. The candidate-funnel architecture (4 guesses, hit/miss split,
// literal path) is gone. Every byte is decomposed into 8 binary distinctions, coded MSB-first.
// For each bit:
//   - 8 context families (order-0 direct, order-1..6 hashed byte context, word-shape hash)
//     each hold an adaptive 12-bit probability for THIS bit in THIS context (same shift-EMA
//     rule as everywhere else in MDLBSG).
//   - The 8 votes are mixed in the stretch (log-odds) domain with integer weights that update
//     in proportion to each family's contribution to the prediction error: track record IS
//     influence, applied at the level where bits are actually paid.
//   - The mixed probability goes straight to the range coder. No hit/miss. No literal path.
//     Every bit pays exactly its measured surprise.
// pattern = boundary + rule + residue, taken to the bit level:
//   boundary = the binary distinction itself
//   rule     = the mixed expectation from shared body state
//   residue  = the arithmetic-coded gap between expectation and reality
// Laws kept: integer-only, deterministic, causal (decoder replays identical state), exact
// replay verified in-process, no zlib, no external compressor, no preminer, no phrase bank.
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <future>
#include <iomanip>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using s16 = int16_t;
using s32 = int32_t;
using s64 = int64_t;

static void die(const std::string& s) { std::cerr << "[v234] ERROR: " << s << "\n"; std::exit(1); }

static std::vector<u8> read_all(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) die("cannot open input: " + path);
    f.seekg(0, std::ios::end);
    std::streamoff n = f.tellg();
    if (n < 0) die("cannot size input: " + path);
    f.seekg(0, std::ios::beg);
    std::vector<u8> data(static_cast<size_t>(n));
    if (!data.empty()) f.read(reinterpret_cast<char*>(data.data()), n);
    return data;
}
static void write_all(const std::string& path, const std::vector<u8>& data) {
    std::ofstream f(path, std::ios::binary);
    if (!f) die("cannot open output: " + path);
    if (!data.empty()) f.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
}

static inline u32 mix32(u32 x) { x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16; return x; }

// ---------------- stretch/squash: integer-only logistic transforms (paq lineage) ----------------
// squash: stretch-domain (-2047..2047) -> probability (0..4095). Pure integer interpolation.
static inline int squash(int d) {
    static const int t[33] = {1,2,3,6,10,16,27,45,73,120,194,310,488,747,1101,1546,2047,
                              2549,2994,3348,3607,3785,3901,3975,4024,4050,4068,4079,4085,4089,4092,4093,4094};
    if (d >  2047) return 4095;
    if (d < -2047) return 0;
    int w = d & 127;
    d = (d >> 7) + 16;
    return (t[d]*(128-w) + t[d+1]*w + 64) >> 7;
}

struct StretchTable {
    std::array<s16,4096> t{};
    StretchTable() {
        int pi = 0;
        for (int x = -2047; x <= 2047; ++x) {
            int v = squash(x);
            for (int j = pi; j <= v; ++j) t[static_cast<size_t>(j)] = static_cast<s16>(x);
            pi = v + 1;
        }
        t[4095] = 2047;
    }
};
static const StretchTable g_stretch;
static inline int stretch(int p) { return g_stretch.t[static_cast<size_t>(p & 4095)]; }

// ---------------- Deterministic carryless range coder (probability given per bit) ----------------
static const u32 kTopValue = 1u << 24;

struct RangeEncoder {
    std::vector<u8> out;
    u64 low = 0;
    u32 range = 0xFFFFFFFFu;
    u8 cache = 0;
    u64 cache_size = 1;

    void shift_low() {
        if (static_cast<u32>(low >> 32) != 0 || low < 0xFF000000ULL) {
            u8 carry = static_cast<u8>(low >> 32);
            u8 temp = cache;
            do {
                out.push_back(static_cast<u8>(temp + carry));
                temp = 0xFF;
            } while (--cache_size != 0);
            cache = static_cast<u8>(low >> 24);
        }
        ++cache_size;
        low = (low << 8) & 0xFFFFFFFFULL;
    }
    // p1 = probability that bit == 1, 12-bit scale, clamped to [1,4095] by caller
    void encode_bit_p(u32 p1, int bit) {
        u32 bound = (range >> 12) * p1;
        if (bit) {
            range = bound;
        } else {
            low += bound;
            range -= bound;
        }
        while (range < kTopValue) { range <<= 8; shift_low(); }
    }
    void flush() { for (int i = 0; i < 5; ++i) shift_low(); }
};

struct RangeDecoder {
    const std::vector<u8>& in;
    size_t pos = 0;
    u32 range = 0xFFFFFFFFu;
    u32 code = 0;

    explicit RangeDecoder(const std::vector<u8>& data) : in(data) {
        pos = 1;
        for (int i = 0; i < 4; ++i) code = (code << 8) | next_byte();
    }
    u8 next_byte() { return pos < in.size() ? in[pos++] : 0; }

    int decode_bit_p(u32 p1) {
        u32 bound = (range >> 12) * p1;
        int bit;
        if (code < bound) {
            range = bound;
            bit = 1;
        } else {
            code -= bound;
            range -= bound;
            bit = 0;
        }
        while (range < kTopValue) { range <<= 8; code = (code << 8) | next_byte(); }
        return bit;
    }
};

// ---------------- Bitwise context-mixing body ----------------

// ---------------- exact integer SIMD mixer, 12-wide fused (neon / avx2) ----------------
// The max core mixes 12 models through THREE weight rows sharing one st[] vector, and
// counts committee votes (st > 400 / st < -400) in the same walk. The SIMD version is
// the same fused shape: one set of st loads feeds three widening dot products plus the
// two vote counts. s64 accumulation of s32*s32 products is order-independent (no
// saturation, fits s64) and the weight update is element-wise -- both exactly
// reproducible in SIMD. The binary PROVES it at startup: 4096 randomized trials of the
// full fused contract (3 dots + 2 vote counts + 3 updated rows) against scalar; any
// mismatch aborts the run.
static bool g_simd = true;
#if defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
static inline void dot12_simd(const s32* wa, const s32* wb, const s32* wc, const int* st,
                              s64& dA, s64& dB, s64& dC, u32& vpos, u32& vneg) {
    const int32x4_t s0 = vld1q_s32(st), s1 = vld1q_s32(st + 4), s2 = vld1q_s32(st + 8);
    const int32x4_t thp = vdupq_n_s32(400), thn = vdupq_n_s32(-400);
    // vote masks are 0xFFFFFFFF per true lane; the lanewise sum is (u32)(-count)
    uint32x4_t gp = vaddq_u32(vaddq_u32(vcgtq_s32(s0, thp), vcgtq_s32(s1, thp)), vcgtq_s32(s2, thp));
    uint32x4_t gn = vaddq_u32(vaddq_u32(vcltq_s32(s0, thn), vcltq_s32(s1, thn)), vcltq_s32(s2, thn));
    vpos = static_cast<u32>(0u - vaddvq_u32(gp));
    vneg = static_cast<u32>(0u - vaddvq_u32(gn));
    auto row = [&](const s32* w) -> s64 {
        int32x4_t w0 = vld1q_s32(w), w1 = vld1q_s32(w + 4), w2 = vld1q_s32(w + 8);
        int64x2_t acc = vmull_s32(vget_low_s32(w0), vget_low_s32(s0));
        acc = vmlal_s32(acc, vget_high_s32(w0), vget_high_s32(s0));
        acc = vmlal_s32(acc, vget_low_s32(w1),  vget_low_s32(s1));
        acc = vmlal_s32(acc, vget_high_s32(w1), vget_high_s32(s1));
        acc = vmlal_s32(acc, vget_low_s32(w2),  vget_low_s32(s2));
        acc = vmlal_s32(acc, vget_high_s32(w2), vget_high_s32(s2));
        return vaddvq_s64(acc);
    };
    dA = row(wa); dB = row(wb); dC = row(wc);
}
static inline void upd12_simd(s32* w, const int* st, int err) {
    const int32x4_t verr = vdupq_n_s32(err);
    const int32x4_t vmaxv = vdupq_n_s32(1 << 20), vminv = vdupq_n_s32(-(1 << 20));
    for (int k = 0; k < 12; k += 4) {
        int32x4_t sv = vld1q_s32(st + k);
        int32x4_t wv = vld1q_s32(w + k);
        int32x4_t d  = vshrq_n_s32(vmulq_s32(sv, verr), 10);
        int32x4_t nv = vminq_s32(vmaxq_s32(vaddq_s32(wv, d), vminv), vmaxv);
        vst1q_s32(w + k, nv);
    }
}
#define HAVE_NEON_MIX 1
#elif defined(__AVX2__)
#include <immintrin.h>
static inline s64 hsum4_s64(__m256i v) {
    __m128i s2 = _mm_add_epi64(_mm256_castsi256_si128(v), _mm256_extracti128_si256(v, 1));
    return static_cast<s64>(_mm_extract_epi64(s2, 0)) + static_cast<s64>(_mm_extract_epi64(s2, 1));
}
static inline void dot12_simd(const s32* wa, const s32* wb, const s32* wc, const int* st,
                              s64& dA, s64& dB, s64& dC, u32& vpos, u32& vneg) {
    const __m256i s8 = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(st));
    const __m128i s4 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(st + 8));
    const __m256i thp8 = _mm256_set1_epi32(400),  thn8 = _mm256_set1_epi32(-400);
    const __m128i thp4 = _mm_set1_epi32(400),     thn4 = _mm_set1_epi32(-400);
    vpos = static_cast<u32>(
        __builtin_popcount(static_cast<unsigned>(_mm256_movemask_ps(_mm256_castsi256_ps(_mm256_cmpgt_epi32(s8, thp8))))) +
        __builtin_popcount(static_cast<unsigned>(_mm_movemask_ps(_mm_castsi128_ps(_mm_cmpgt_epi32(s4, thp4))))));
    vneg = static_cast<u32>(
        __builtin_popcount(static_cast<unsigned>(_mm256_movemask_ps(_mm256_castsi256_ps(_mm256_cmpgt_epi32(thn8, s8))))) +
        __builtin_popcount(static_cast<unsigned>(_mm_movemask_ps(_mm_castsi128_ps(_mm_cmpgt_epi32(thn4, s4))))));
    // widening 32x32->64: even lanes directly; odd lanes shifted into the low halves.
    const __m256i s8o = _mm256_srli_epi64(s8, 32);
    const __m128i s4o = _mm_srli_epi64(s4, 32);
    auto row = [&](const s32* w) -> s64 {
        __m256i w8 = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(w));
        __m128i w4 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(w + 8));
        __m256i acc8 = _mm256_add_epi64(_mm256_mul_epi32(w8, s8),
                                        _mm256_mul_epi32(_mm256_srli_epi64(w8, 32), s8o));
        __m128i acc4 = _mm_add_epi64(_mm_mul_epi32(w4, s4),
                                     _mm_mul_epi32(_mm_srli_epi64(w4, 32), s4o));
        return hsum4_s64(acc8)
             + static_cast<s64>(_mm_extract_epi64(acc4, 0))
             + static_cast<s64>(_mm_extract_epi64(acc4, 1));
    };
    dA = row(wa); dB = row(wb); dC = row(wc);
}
static inline void upd12_simd(s32* w, const int* st, int err) {
    const __m256i verr8 = _mm256_set1_epi32(err);
    const __m256i vmax8 = _mm256_set1_epi32(1 << 20), vmin8 = _mm256_set1_epi32(-(1 << 20));
    __m256i sv = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(st));
    __m256i wv = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(w));
    __m256i d  = _mm256_srai_epi32(_mm256_mullo_epi32(sv, verr8), 10);
    _mm256_storeu_si256(reinterpret_cast<__m256i*>(w),
        _mm256_min_epi32(_mm256_max_epi32(_mm256_add_epi32(wv, d), vmin8), vmax8));
    const __m128i verr4 = _mm_set1_epi32(err);
    const __m128i vmax4 = _mm_set1_epi32(1 << 20), vmin4 = _mm_set1_epi32(-(1 << 20));
    __m128i sv4 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(st + 8));
    __m128i wv4 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(w + 8));
    __m128i d4  = _mm_srai_epi32(_mm_mullo_epi32(sv4, verr4), 10);
    _mm_storeu_si128(reinterpret_cast<__m128i*>(w + 8),
        _mm_min_epi32(_mm_max_epi32(_mm_add_epi32(wv4, d4), vmin4), vmax4));
}
#define HAVE_NEON_MIX 1
#else
#define HAVE_NEON_MIX 0
#endif
#if HAVE_NEON_MIX
static void simd_self_proof() {
    if (!g_simd) return;
    u64 x = 0x9E3779B97F4A7C15ULL;
    auto rnd = [&]() { x ^= x<<13; x ^= x>>7; x ^= x<<17; return x; };
    for (int trial = 0; trial < 4096; ++trial) {
        s32 wa[12], wb[12], wc[12], wa2[12], wb2[12], wc2[12]; int st[12];
        for (int k = 0; k < 12; ++k) {
            wa[k] = static_cast<s32>(rnd() % (1u<<21)) - (1<<20); wa2[k] = wa[k];
            wb[k] = static_cast<s32>(rnd() % (1u<<21)) - (1<<20); wb2[k] = wb[k];
            wc[k] = static_cast<s32>(rnd() % (1u<<21)) - (1<<20); wc2[k] = wc[k];
            st[k] = static_cast<int>(rnd() % 4096) - 2048;
        }
        int err = static_cast<int>(rnd() % 8192) - 4096;
        s64 rA = 0, rB = 0, rC = 0; u32 rp = 0, rn = 0;
        for (int k = 0; k < 12; ++k) {
            rp += static_cast<u32>(st[k] > 400);
            rn += static_cast<u32>(st[k] < -400);
            rA += static_cast<s64>(wa[k]) * st[k];
            rB += static_cast<s64>(wb[k]) * st[k];
            rC += static_cast<s64>(wc[k]) * st[k];
        }
        s64 sA, sB, sC; u32 sp, sn;
        dot12_simd(wa, wb, wc, st, sA, sB, sC, sp, sn);
        if (rA != sA || rB != sB || rC != sC || rp != sp || rn != sn)
            die("SIMD SELF-PROOF FAILED (dot12) -- refusing to run");
        for (int k = 0; k < 12; ++k) {
            s32 n = wa[k] + ((st[k] * err) >> 10);
            if (n >  (1<<20)) n =  (1<<20); if (n < -(1<<20)) n = -(1<<20);
            wa[k] = n;
        }
        upd12_simd(wa2, st, err);
        for (int k = 0; k < 12; ++k) if (wa[k] != wa2[k])
            die("SIMD SELF-PROOF FAILED (upd12) -- refusing to run");
    }
    std::cout << "[v234] simd self-proof: 4096 randomized trials, 12-wide fused simd == scalar exactly\n";
}
#else
static void simd_self_proof() {}
#endif

struct WarmSnapshotPos {
    std::vector<u8> hist0;
    std::vector<u32> mtab0;
    u64 last8_0 = 0;
};
static WarmSnapshotPos g_warm_pos;   // chunk-0 positional prefix, shared read-only by lineages
static u32 g_warm_clamp = 15;
static bool g_unit_alpha = false; // organs treat 0x80..0xFB unit codes as letter-like symbols
static bool g_rightsize = false;
// residual map: -log2(p) accounting per coded byte, bucketed by (byte class x match state).
// Pure instrumentation: archive bytes untouched. Atomic adds so braid lineages merge exactly.
#include <atomic>
#include <cmath>
static bool g_resmap = false;
// Progress reporting. The compressor is the only thing that knows how far along it is,
// so it writes "<chunks done> <chunks total>" to a file after each chunk completes.
// Anything watching that file can draw a progress bar. Flag-gated: zero cost when off.
static bool g_content_folder = false;   // true when the input is a bundled folder tree
static std::string g_progress_path;
static std::atomic<unsigned long long> g_progress_bytes{0};
static std::atomic<int> g_progress_pct{-1};
static unsigned long long g_progress_total = 0;   // total BYTES of input
// Called as bytes are encoded. Writes the file only when the whole percent changes,
// so a 1GB run does ~100 tiny writes, not millions -- and lanes racing each other
// can't thrash it.
static void progress_add(unsigned long long n) {
    if (g_progress_path.empty() || g_progress_total == 0) return;
    const unsigned long long b = g_progress_bytes.fetch_add(n) + n;
    int pct = static_cast<int>((b * 100ull) / g_progress_total);
    if (pct > 100) pct = 100;
    int last = g_progress_pct.load();
    while (pct > last) {
        if (g_progress_pct.compare_exchange_weak(last, pct)) {
            FILE* f = std::fopen(g_progress_path.c_str(), "w");
            if (f) { std::fprintf(f, "%llu %llu\n", b, g_progress_total); std::fclose(f); }
            return;
        }
    }
}
static bool g_errledger = false;
static std::atomic<unsigned long long> g_err_pat_mb[256], g_err_pat_n[256];
static std::atomic<unsigned long long> g_err_run[17];
static bool g_timeledger = false;
static u32 g_w2_bits = 22;
static u32 g_w3_bits = 23;
static std::atomic<unsigned long long> g_res_mbits[44];   // 11 classes x 4 match buckets
static std::atomic<unsigned long long> g_res_bytes[44];
static int g_logmb[4096];                                  // -log2(p/4096) in millibits
static void resmap_init(){
    for(int p2=1;p2<4096;++p2) g_logmb[p2]=(int)std::lround(-std::log2(p2/4096.0)*1000.0);
    g_logmb[0]=g_logmb[1];
}
static const char* kClsName[11]={"other","lower","UPPER","digit","space","newline","period",
                                 "comma","quote","bracket","wiki[]{}|="};
static u32 res_cls(u8 b){
    if (b>='a'&&b<='z') return 1; if (b>='A'&&b<='Z') return 2;
    if (b>='0'&&b<='9') return 3; if (b==' ') return 4;
    if (b=='\n'||b=='\r') return 5; if (b=='.') return 6; if (b==',') return 7;
    if (b=='\''||b=='"') return 8; if (b=='('||b==')'||b=='<'||b=='>') return 9;
    if (b=='['||b==']'||b=='{'||b=='}'||b=='|'||b=='=') return 10;
    return 0;
}
static void errledger_print() {
    if(!g_errledger) return;
    printf("\n[error ledger] cost per last-8-byte expense rhythm (1 = >4 bits), top patterns:\n");
    struct R{u32 pat; unsigned long long mb,n;};
    std::vector<R> rs;
    unsigned long long tot=0;
    for(u32 k=0;k<256;++k){ auto mb=g_err_pat_mb[k].load(), n=g_err_pat_n[k].load(); if(n) rs.push_back({k,mb,n}); tot+=mb; }
    std::sort(rs.begin(),rs.end(),[](auto&a,auto&b){return a.mb>b.mb;});
    printf("%-10s %14s %10s %8s\n","rhythm","bytes","bits/byte","share");
    for(size_t k=0;k<rs.size() && k<14;++k){
        char pat[9]; for(int j=7;j>=0;--j) pat[7-j]=((rs[k].pat>>j)&1)?'1':'0'; pat[8]=0;
        printf("%-10s %14llu %10.3f %7.2f%%\n",pat,(unsigned long long)rs[k].n,rs[k].mb/1000.0/rs[k].n,100.0*rs[k].mb/tot);
    }
    printf("[error ledger] expensive-run lengths: ");
    for(u32 k=1;k<=16;++k){ auto v=g_err_run[k].load(); if(v) printf("%u:%llu ",k,(unsigned long long)v); }
    printf("\n");
}
static void resmap_print(u64 archive_bytes){
    if(!g_resmap) return;
    printf("\n[residual map] where the unexplained reality lives (sorted by total bits):\n");
    printf("%-14s %-9s %12s %14s %9s %7s\n","class","match","bytes","kilobits","bits/byte","share");
    static const char* mb[4]={"none","1-7","8-31","32+"};
    struct Row{int k; unsigned long long mbits, cnt;};
    std::vector<Row> rows;
    unsigned long long tot=0;
    for(int k=0;k<44;++k){ auto m=g_res_mbits[k].load(), c=g_res_bytes[k].load();
        if(c) rows.push_back({k,m,c}); tot+=m; }
    std::sort(rows.begin(),rows.end(),[](auto&a,auto&b){return a.mbits>b.mbits;});
    for(auto&r:rows){
        printf("%-14s %-9s %12llu %14.0f %9.3f %6.2f%%\n",
            kClsName[r.k/4], mb[r.k%4], r.cnt, r.mbits/1000.0/1000.0*1000.0/1000.0*1000.0,
            r.mbits/1000.0/r.cnt, 100.0*r.mbits/tot);
    }
    printf("[residual map] instrument check: sum=%.0f bytes vs archive=%llu bytes\n",
           tot/1000.0/8.0,(unsigned long long)archive_bytes);
}  // o1 direct @2^16 (collision-free, 1/256 memory), o2 direct @2^24 (collision-free)
static inline u16 clamp_cnt(u16 v, u32 cl) {
    u32 c = v >> 12; if (c > cl) c = cl;
    return static_cast<u16>((c << 12) | (v & 4095u));
}
struct BitCMBody {
    static constexpr u32 kNumModels = 12;     // order0, word2, o2..6, word, case, o8, word3, match
    static constexpr u32 kMixCtx = 4096;      // (quiet bucket 0..3) x (match bucket) x (node)
    u32 cm_bits;                              // log2 size of each hashed model table
    u32 cm_mask;
    u32 fam_mask[10];                          // per-family index mask (rightsize: o1/o2 direct)
    u32 mm_bits;                              // log2 size of match-position table
    u32 mm_mask;

    // Per-model adaptive bit probabilities (12-bit, init 2048 = "no opinion").
    std::array<u16,256> t_order0;             // direct partial-byte table
    std::vector<u16> t_hash[10];              // word2, o2..6, word, case, o8, word3

    // Mixer committee: three specialists, each viewing the same ten family votes through a
    // different context lens, each trained on its OWN error (so each becomes a genuine
    // specialist), plus an adaptive layer-2 combiner that learns whose judgment to trust
    // in which regime. The combiner's rule is the specialists' track records.
    std::vector<s32> w;                       // A: (quiet x match x node) rows
    std::vector<s32> wB;                      // B: previous-byte identity rows (256)
    std::vector<s32> wC;                      // C: character-class texture rows (100)
    std::vector<s32> w2;                      // layer 2: 256 rows x 3 specialist weights

    // Match model: the exact-repeat relation family. hist = every byte this body has absorbed
    // (identical on decoder, which absorbs its own decoded output). mtab maps a hash of the
    // last 8 bytes to the position that followed that context last time. When the current
    // context has been seen before, the byte that followed it is a strong vote; confidence
    // scales with how long the current match run has been extending.
    std::vector<u8> hist;
    std::vector<u32> mtab;
    u64 last8 = 0;
    bool cache_local = false;
    u32 match_ptr = 0;
    u32 match_len = 0;
    u8  match_byte = 0;
    bool match_valid_byte = false;
    int cur_bit = 7;

    // causal byte history + word-shape hash
    u8 b1=0,b2=0,b3=0,b4=0,b5=0,b6=0,b7=0,b8=0;
    u32 word_hash = 0;
    u8 caps_run = 0;      // consecutive capitals just seen
    u8 sent_end = 0;      // last non-space byte was . ! ?
    u8 cur_word_caps = 0; // current word began with a capital
    u8 prev_word_caps = 0;// previous word began with a capital (proper nouns travel in packs)

    // per-byte cached model base indices (recomputed once per byte)
    std::array<u32,10> hbase{};
    // TWIST layout: store cell idx at physical slot (idx * KINV) & mask, where KINV is the
    // modular inverse of the ctx stride 0x57F4A9 mod 2^32. Then slot(hbase + ctx*K) =
    // hbase*KINV + ctx: one byte-context's 255 bit-tree nodes become PHYSICALLY CONTIGUOUS.
    // A bijective relabeling preserves every collision and every cell value -> the archive is
    // bit-identical to scatter. Only the memory geometry changes: ~4 lines per family per byte
    // instead of ~8 scattered lines, all prefetchable at byte start.
    static constexpr u32 kCtxStrideInv = 0xABFDEF99u; // (0x57F4A9)^-1 mod 2^32
    bool twist = false;
    std::array<u32,10> hb2{};

    explicit BitCMBody(u32 bits, u32 mmbits, u64 reserve_hint)
        : cm_bits(bits), cm_mask((1u<<bits)-1u), mm_bits(mmbits), mm_mask((1u<<mmbits)-1u) {
        t_order0.fill(2048);
        for (int m = 0; m < 10; ++m) {
            u32 fb = cm_bits;
            if (g_rightsize) { if (m == 0) fb = g_w2_bits; else if (m == 1) fb = 24; else if (m == 9) fb = g_w3_bits; }
            fam_mask[m] = (1u << fb) - 1u;
            t_hash[m].assign(static_cast<size_t>(1u) << fb, 2048);
        }
        w.assign(static_cast<size_t>(kMixCtx) * kNumModels, 1 << 13); // ~equal initial trust
        wB.assign(256u * kNumModels, 1 << 13);
        wC.assign(100u * kNumModels, 1 << 13);
        w2.assign(256u * 3u, (1 << 16) / 3);   // combiner starts as an equal-thirds average
        mtab.assign(static_cast<size_t>(1u) << mm_bits, 0xFFFFFFFFu);
        apm_init();
        hist.reserve(static_cast<size_t>(reserve_hint));
    }

    // APM/SSE: calibration of the mixer's own output. Indexed by (order-1 byte, quantized
    // stretch of p_mix), interpolated between neighboring buckets, updated toward the actual
    // bit. This is the track-record rule applied a third time: to the body's own confidence.
    std::vector<u16> apm_t;
    size_t apm_base = 0;
    int apm_wgt = 0;
    std::vector<u16> apm2_t;
    size_t apm2_base = 0;
    int last_pmix = 2048;
    u32 last_mixrow = 0;
    // absence-of-surprise coordinate: how many consecutive bytes has the body's expectation
    // gone unconfounded? Long quiet = deep inside well-modeled territory; calibration should
    // know which regime it is in. Dyadic buckets, zero extra lookups.
    u32 quiet_run = 0;
    u32 link_depth = 0;                       // [[ .. ]] nesting; every word inside capitalizes
    u8 digit_run = 0;                         // consecutive digits — positional structure of numbers
    u32 prev_word_hash = 0;                   // order-2 word context feed
    u32 prev2_word_hash = 0;                  // two words back — order-3 word context
    u8 err_hist = 0;                          // last 8 bytes' expense flags (miss rhythm)
    u8 miss_age = 15;                         // bytes since last expensive byte (the bruise age)
    bool rest_mid = false;                    // deep-match: o2..o6 rest this byte
    u64 nl_last = 0;                          // position of last newline
    u32 nl_gap = 0;                           // last line length (the tempo)
    u8 prev_word_len_b = 0;                   // previous word's length bucket (duration rhythm)
    u32 meter_key = 0;                        // beat proximity, refreshed per byte
    u32 err_run = 0;
    bool w3_active = false;                   // slot 9 gathers only at word_len <= 1
    u8 word_len = 0;                          // letters into current word (jurisdiction gate)
    bool w2_active = false;                   // slot 0 gathers only when word_len <= 3
    bool byte_wrong = false;
    u32 rowB = 0, rowC = 0, row2 = 0;
    int dA = 0, dB = 0, dC = 0;

    void apm_init() {
        apm_t.resize(262144u * 33u);
        for (u32 c = 0; c < 262144u; ++c)
            for (int i = 0; i < 33; ++i)
                apm_t[c*33u + static_cast<u32>(i)] = static_cast<u16>(squash((i - 16) * 128));
        apm2_t.resize(262144u * 33u);
        for (u32 c = 0; c < 262144u; ++c)
            for (int i = 0; i < 33; ++i)
                apm2_t[c*33u + static_cast<u32>(i)] = static_cast<u16>(squash((i - 16) * 128));
    }
    int apm2_pp(int pr, u32 cx) {
        int s = stretch(pr) + 2048;
        int i = s >> 7;
        int wgt = s & 127;
        apm2_base = static_cast<size_t>(cx) * 33u + static_cast<size_t>(i);
        return (apm2_t[apm2_base]*(128-wgt) + apm2_t[apm2_base+1]*wgt) >> 7;
    }
    u32 quiet_bucket() const { u32 v = quiet_run > 255u ? 255u : quiet_run; u32 b = 0; while (v) { v >>= 1; ++b; } return b & 7u; }
    int apm_pp(int pr, u32 cx) {
        int s = stretch(pr) + 2048;             // 1..4095
        int i = s >> 7;                          // 0..31
        apm_wgt = s & 127;
        apm_base = static_cast<size_t>(cx) * 33u + static_cast<size_t>(i);
        return (apm_t[apm_base]*(128-apm_wgt) + apm_t[apm_base+1]*apm_wgt) >> 7;
    }
    void apm_upd(int bit) {
        const int g = bit << 12;
        u16& a = apm_t[apm_base];
        u16& b = apm_t[apm_base+1];
        a = static_cast<u16>(a + ((g - static_cast<int>(a)) >> 6));
        b = static_cast<u16>(b + ((g - static_cast<int>(b)) >> 6));
        u16& a2 = apm2_t[apm2_base];
        u16& b2 = apm2_t[apm2_base+1];
        a2 = static_cast<u16>(a2 + ((g - static_cast<int>(a2)) >> 6));
        b2 = static_cast<u16>(b2 + ((g - static_cast<int>(b2)) >> 6));
    }

    static bool is_letter(u8 b) { return (b>='a'&&b<='z')||(b>='A'&&b<='Z'); }
    static u32 cls(u8 b) {
        if (g_unit_alpha && b >= 0x80) {
            if (b <= 0xFB) return 1u;          // unit code bytes read as lowercase-letter-like
            if (b == 0xFE || b == 0xFF) return 2u; // cap flags read as capital-like
            return 9u;                          // ESC / NOSPACE stay "other"
        }
        if (b>='a'&&b<='z') return 1u; if (b>='A'&&b<='Z') return 2u;
        if (b>='0'&&b<='9') return 3u; if (b==' '||b=='\t') return 4u;
        if (b=='\n'||b=='\r') return 5u;
        if (b=='<'||b=='>'||b=='/'||b=='='||b=='"') return 6u;
        if (b=='['||b==']'||b=='{'||b=='}'||b=='|'||b=='_') return 7u;
        if (b=='.'||b==','||b==';'||b==':'||b=='-'||b=='('||b==')') return 8u;
        return 9u;
    }

    void new_byte_hashes() {
        // one 32-bit hash per context order, computed once per byte
        u32 h1 = mix32(0x1000193u ^ b1*0x9e3779b9u);
        u32 h2 = mix32(h1 ^ b2*0x85ebca6bu);
        u32 h3 = mix32(h2 ^ b3*0xc2b2ae35u);
        u32 h4 = mix32(h3 ^ b4*0x27d4eb2du);
        u32 h5 = mix32(h4 ^ b5*0x165667b1u);
        u32 h6 = mix32(h5 ^ b6*0x2545f491u);
        u32 h7 = mix32(h6 ^ b7*0x9E3779B1u);
        u32 h8 = mix32(h7 ^ b8*0x7FEB352Du);   // order-8: one more link in the same chain
        u32 hw = mix32(word_hash * 0x9e3779b1u + 0x1234567u);
        // case-structure family: the microscope says UPPER bytes bleed 2.65x average bits.
        // Capitals follow sentence ends, start [[wiki links]], run in acronyms — all causal.
        const u32 linkf = (b2 == '[' && b1 == '[') ? 1u : 0u;
        u32 hc = mix32(0xCAFEBABEu ^ b1 * 0x9e3779b9u ^ word_hash * 0x85ebca6bu
                       ^ (static_cast<u32>(caps_run) * 0xc2b2ae35u)
                       ^ (static_cast<u32>(sent_end) << 30) ^ (linkf << 29)
                       ^ (static_cast<u32>(prev_word_caps) << 28)
                       ^ (link_depth << 26));
        u32 hw2 = mix32((prev_word_hash * 0x2545F491u) ^ (word_hash * 0x9e3779b1u) ^ 0xB5297A4Du);
        u32 hw3 = mix32((prev2_word_hash * 0x9E3779B1u) ^ (prev_word_hash * 0x85EBCA6Bu) ^ (word_hash * 0xC2B2AE35u) ^ 0x6C078965u);
        w2_active = (word_len <= 3u);
        w3_active = (word_len <= 1u);
        rest_mid = (match_len >= 32u);        // movie-memory territory: mid-orders sit down
        {   // meter: distance to the predicted next newline (last + last interval), bucketed
            const u64 here = hist.size();
            const u64 predicted = nl_last + (nl_gap ? nl_gap : 1u);
            const u64 d = predicted > here ? predicted - here : here - predicted;
            meter_key = d <= 2u ? 3u : (d <= 8u ? 2u : (d <= 24u ? 1u : 0u));
        }
        hbase[0]=hw2; hbase[1]=h2; hbase[2]=h3; hbase[3]=h4; hbase[4]=h5; hbase[5]=h6; hbase[6]=hw; hbase[7]=hc; hbase[8]=h8; hbase[9]=hw3;
        // latency hiding: every table line this byte will touch is knowable right now.
        // Issue the prefetches, then do bit 7's arithmetic while the lines are in flight.
        if (twist) {
            for (u32 m = 0; m < 10u; ++m) {
                if (g_rightsize && m == 1) hb2[m] = (static_cast<u32>(b1) << 16) | (static_cast<u32>(b2) << 8); // direct
                else                       hb2[m] = hbase[m] * kCtxStrideInv;
                if (m == 0u && !w2_active) continue;   // abstaining: no prefetch, no DRAM
                if (m == 9u && !w3_active) continue;
                // resting organs still get their lines PRE-WARMED (byte-invisible) so
                // region exits wake into warm memory instead of a cold-read burst
                const u32 fm = fam_mask[m];
                const u32 base = hb2[m] & fm;        // 255-cell window [base+1, base+255]
                __builtin_prefetch(&t_hash[m][base], 1, 1);
                __builtin_prefetch(&t_hash[m][(base + 64u) & fm], 1, 1);
                __builtin_prefetch(&t_hash[m][(base + 128u) & fm], 1, 1);
                __builtin_prefetch(&t_hash[m][(base + 192u) & fm], 1, 1);
            }
        } else {
        for (u32 m = 0; m < 7u; ++m) {
            const u32 base = cache_local ? (hbase[m] & (cm_mask & ~255u))
                                         : ((hbase[m] + 0x57F4A9u) & cm_mask);
            __builtin_prefetch(&t_hash[m][base], 1, 1);
            if (cache_local) __builtin_prefetch(&t_hash[m][base + 128u], 1, 1);
        }
        }
        // match model: arm the vote for this byte if a match run is live
        if (match_len > 0 && match_ptr < hist.size()) {
            match_byte = hist[match_ptr];
            match_valid_byte = true;
        } else {
            match_byte = 0;
            match_valid_byte = false;
        }
        cur_bit = 7;
        byte_wrong = false;
    }

    // BATCH: encoder knows the byte, and within one byte all 9 table cells per bit are
    // provably disjoint from every other bit's cells (tree levels are disjoint ctx ranges;
    // ctx->slot is injective per byte in all three layouts). Therefore hoisting ALL reads to
    // byte start is semantically identical to interleaved read/write — bit-exact by proof,
    // and the loads issue back-to-back instead of load-use stalling per bit.
    u32 pre_idx[8][11];
    int pre_st[8][11];
    void preload_byte(u8 actual) {
        u32 c = 1;
        for (int i = 7; i >= 0; --i) {
            const int k = 7 - i;
            pre_idx[k][0] = c & 255u;
            pre_st[k][0] = stretch(t_order0[pre_idx[k][0]] & 4095u);
            for (u32 m = 0; m < 10; ++m) {
                if (m == 0u && !w2_active) { pre_idx[k][1] = 0xFFFFFFFFu; pre_st[k][1] = 0; continue; }
                if (m == 9u && !w3_active) { pre_idx[k][10] = 0xFFFFFFFFu; pre_st[k][10] = 0; continue; }
                if (rest_mid && m >= 1u && m <= 5u) { pre_idx[k][m+1] = 0xFFFFFFFFu; pre_st[k][m+1] = 0; continue; }
                const u32 ix = twist ? ((hb2[m] + c) & fam_mask[m])
                    : (cache_local ? ((hbase[m] & (cm_mask & ~255u)) | (c & 255u))
                                   : ((hbase[m] + c * 0x57F4A9u) & cm_mask));
                pre_idx[k][m+1] = ix;
                pre_st[k][m+1] = stretch(t_hash[m][ix] & 4095u);
            }
            c = (c << 1) | ((actual >> i) & 1u);
        }
    }

    // predict probability(bit==1) for the current bit; ctx = bit-tree node (1..255)
    // fills idx[] and st[] for the update step
    u32 predict(u32 ctx, u32* idx, int* st, const u32* pi = nullptr, const int* ps = nullptr) {
        if (pi) {
            for (u32 sslot = 0; sslot < 11u; ++sslot) { idx[sslot] = pi[sslot]; st[sslot] = ps[sslot]; }
        } else {
        // gather the 8 family votes, stretch them
        idx[0] = ctx & 255u;
        st[0] = stretch(t_order0[idx[0]] & 4095u);
        for (u32 m = 0; m < 10; ++m) {
            // Two layouts, runtime-selectable:
            //  scatter: full-hash slot per (context, bit-node) — max discrimination, max ratio.
            //  block:   one 256-slot block per (model, byte-context), bit-node picks the slot
            //           inside — 7 cache regions per byte instead of ~56 scattered lines,
            //           ~1.9x faster at large cm_bits for ~1% ratio.
            if (m == 0u && !w2_active) { idx[1] = 0xFFFFFFFFu; st[1] = 0; continue; }
            if (m == 9u && !w3_active) { idx[10] = 0xFFFFFFFFu; st[10] = 0; continue; }
            if (rest_mid && m >= 1u && m <= 5u) { idx[m+1] = 0xFFFFFFFFu; st[m+1] = 0; continue; }
            u32 i = twist ? ((hb2[m] + ctx) & fam_mask[m])
                : (cache_local
                ? ((hbase[m] & (cm_mask & ~255u)) | (ctx & 255u))
                : ((hbase[m] + ctx * 0x57F4A9u) & cm_mask));
            idx[m+1] = i;
            st[m+1] = stretch(t_hash[m][i] & 4095u);
        }
        }
        // match model vote: if the byte that followed this exact context last time is still
        // consistent with the bits decoded so far, vote for its next bit with confidence that
        // grows with match run length. The mixer learns how much to trust it, like any family.
        if (match_valid_byte) {
            const int e = (match_byte >> cur_bit) & 1;
            const u32 ml = match_len > 28 ? 28u : match_len;
            const int s = static_cast<int>(160u + ml * 64u); // 224..1952, capped inside stretch range
            st[11] = e ? s : -s;
        } else {
            st[11] = 0;
        }
        idx[11] = 0; // match model has no table cell to update
        // mix in stretch domain with per-node weights
        const u32 mb = match_valid_byte ? (match_len >= 32 ? 3u : (match_len >= 8 ? 2u : 1u)) : 0u;
        const u32 qb = quiet_bucket() >> 1;   // 0..3 coarse quiet regime
        last_mixrow = ((qb << 10) | (mb << 8) | (ctx & 255u)) * kNumModels;
        rowB = static_cast<u32>(b1) * kNumModels;
        rowC = (cls(b1) * 10u + cls(b2)) * kNumModels;
        row2 = (ctx & 255u) * 3u;
        u32 vpos = 0, vneg = 0;
        s64 dotA = 0, dotB = 0, dotC = 0;
#if HAVE_NEON_MIX
        if (g_simd) {
            dot12_simd(&w[last_mixrow], &wB[rowB], &wC[rowC], st, dotA, dotB, dotC, vpos, vneg);
        } else
#endif
        {
            const s32* wa = &w[last_mixrow];
            const s32* wb = &wB[rowB];
            const s32* wc = &wC[rowC];
            for (u32 m = 0; m < kNumModels; ++m) {
                vpos += static_cast<u32>(st[m] > 400);
                vneg += static_cast<u32>(st[m] < -400);
                dotA += static_cast<s64>(wa[m]) * st[m];
                dotB += static_cast<s64>(wb[m]) * st[m];
                dotC += static_cast<s64>(wc[m]) * st[m];
            }
        }
        dA = static_cast<int>(dotA >> 16); if (dA > 2047) dA = 2047; if (dA < -2047) dA = -2047;
        dB = static_cast<int>(dotB >> 16); if (dB > 2047) dB = 2047; if (dB < -2047) dB = -2047;
        dC = static_cast<int>(dotC >> 16); if (dC > 2047) dC = 2047; if (dC < -2047) dC = -2047;
        const s32* w2r = &w2[row2];
        s64 dot2 = static_cast<s64>(w2r[0])*dA + static_cast<s64>(w2r[1])*dB + static_cast<s64>(w2r[2])*dC;
        int d = static_cast<int>(dot2 >> 16);
        if (d >  2047) d =  2047;
        if (d < -2047) d = -2047;
        int p = squash(d);
        last_pmix = p;
        // calibrate by measured track record: stage 1 by order-1 byte, stage 2 by
        // (match bucket, partial-byte node) — two independent views, chained lightly
        const u32 mbk = match_len == 0 ? 0u : (match_len < 8 ? 1u : (match_len < 32 ? 2u : 3u));
        // committee shape, fused: vpos/vneg were counted in the dot loop that already
        // walks st[] — the standalone counting pass is erased. Identical statistic.
        const u32 conf = (vpos >= 7u || vneg >= 7u) ? 3u
                       : ((vpos >= 4u && vneg <= 1u) || (vneg >= 4u && vpos <= 1u)) ? 2u
                       : (vpos + vneg >= 4u) ? 1u : 0u;
        const u32 age_b = miss_age == 0u ? 0u : (miss_age == 1u ? 1u : (miss_age == 2u ? 2u :
                          (miss_age <= 4u ? 3u : (miss_age <= 6u ? 4u : (miss_age <= 8u ? 5u :
                          (miss_age <= 12u ? 6u : 7u))))));
        const int pa = apm_pp(p, (age_b << 15) | (conf << 13) | (mbk << 11) | (quiet_bucket() << 8) | b1);
        int p1 = (3*p + pa) >> 2;
        const u32 dbk = digit_run == 0 ? 0u : (digit_run == 1 ? 1u : (digit_run <= 3 ? 2u : 3u));
        const int pa2 = apm2_pp(p1, (meter_key << 16) | (static_cast<u32>(prev_word_len_b) << 14)
                                  | (dbk << 12) | (mbk << 10)
                                  | ((static_cast<u32>(b1)*31u + static_cast<u32>(b2)) & 1023u));
        int pf = (3*p1 + pa2) >> 2;
        if (pf < 1) pf = 1;
        if (pf > 4095) pf = 4095;
        return static_cast<u32>(pf);
    }

    // evidence-scaled rule update: state = [4-bit count | 12-bit probability].
    // A fresh rule moves at >>2 (first evidence is everything); a proven rule moves at >>7
    // (one surprise cannot erase thousands of confirmations). Rate decays dyadically as
    // evidence accumulates: pattern = boundary + rule + residue, with the rule's confidence
    // now proportional to what it has already absorbed. Zero extra memory or lookups.
    static inline void upd_state(u16& s, int target) {
        const u32 cnt = s >> 12;
        const int p = static_cast<int>(s & 4095u);
        static const int kShift[16] = {1,1,2,2,2,2,3,3,3,3,3,3,3,3,3,3};
        const int np = p + ((target - p) >> kShift[cnt]);
        const u32 nc = cnt < 15u ? cnt + 1u : 15u;
        s = static_cast<u16>((nc << 12) | static_cast<u32>(np & 4095));
    }

    // update all family probabilities and mixer weights with the actual bit
    void update(u32 ctx, const u32* idx, const int* st, u32 p_mix, int bit) {
        const int target = bit << 12;
        upd_state(t_order0[idx[0]], target);
        for (u32 m = 0; m < 10; ++m) { if (idx[m+1] == 0xFFFFFFFFu) continue; upd_state(t_hash[m][idx[m+1]], target); }
        // (model 8, the match vote, has no table cell — the mixer weight below is its memory)
        // mixer weights: influence moves in proportion to contribution to the error.
        // The mixer is judged by its OWN output (pre-calibration), the APM by the final bit.
        if ((bit == 1 && p_mix < 2048u) || (bit == 0 && p_mix >= 2048u)) byte_wrong = true;
        const int errA = target - squash(dA);
        const int errB = target - squash(dB);
        const int errC = target - squash(dC);
        const int errF = target - last_pmix; // combiner's error
        s32* wa = &w[last_mixrow];
        s32* wb = &wB[rowB];
        s32* wc = &wC[rowC];
#if HAVE_NEON_MIX
        if (g_simd) {
            upd12_simd(wa, st, errA);
            upd12_simd(wb, st, errB);
            upd12_simd(wc, st, errC);
        } else
#endif
        for (u32 m = 0; m < kNumModels; ++m) {
            s32 na = wa[m] + ((st[m] * errA) >> 10);
            if (na >  (1<<20)) na =  (1<<20); if (na < -(1<<20)) na = -(1<<20);
            wa[m] = na;
            s32 nb = wb[m] + ((st[m] * errB) >> 10);
            if (nb >  (1<<20)) nb =  (1<<20); if (nb < -(1<<20)) nb = -(1<<20);
            wb[m] = nb;
            s32 nc = wc[m] + ((st[m] * errC) >> 10);
            if (nc >  (1<<20)) nc =  (1<<20); if (nc < -(1<<20)) nc = -(1<<20);
            wc[m] = nc;
        }
        s32* w2r = &w2[row2];
        const int din[3] = {dA, dB, dC};
        for (u32 k = 0; k < 3u; ++k) {
            s32 nw = w2r[k] + ((din[k] * errF) >> 10);
            if (nw >  (1<<20)) nw =  (1<<20); if (nw < -(1<<20)) nw = -(1<<20);
            w2r[k] = nw;
        }
        apm_upd(bit);
        // match consistency within this byte: once the actual bits diverge from the matched
        // byte, its vote is silenced for the remaining bits of this byte
        if (match_valid_byte && bit != ((match_byte >> cur_bit) & 1)) match_valid_byte = false;
        --cur_bit;
    }

    // BRAID support: reset positional state (match run, byte registers, quiet regime) while
    // preserving all learned state (CM tables, mixer weights, APM). Used between chunks of one
    // lineage: statistics transfer across the file-gap, positions do not.
    void reset_positional(const WarmSnapshotPos* pos, u64 reserve_hint);

    void absorb(u8 b) {
        // match model maintenance: extend the run if it predicted correctly, break otherwise
        if (match_len > 0 && match_ptr < hist.size() && hist[match_ptr] == b) {
            ++match_ptr;
            if (match_len < 65535u) ++match_len;
        } else {
            match_len = 0;
        }
        hist.push_back(b);
        // O(1) rolling match hash: the last 8 bytes live packed in one u64, maintained with a
        // single shift-or per byte. Same information as the old 8-iteration loop, ~8x cheaper.
        last8 = (last8 << 8) | b;
        if (hist.size() >= 8) {
            const size_t n = hist.size();
            u64 z = last8 * 0x9E3779B97F4A7C15ULL;
            z ^= z >> 29;
            z *= 0xBF58476D1CE4E5B9ULL;
            z ^= z >> 32;
            const u32 h = static_cast<u32>(z) & mm_mask;
            if (match_len == 0) {
                const u32 mp = mtab[h];
                if (mp != 0xFFFFFFFFu && mp < n) { match_ptr = mp; match_len = 1; }
            }
            mtab[h] = static_cast<u32>(n);
        }
        if (b == '\n') { const u64 pos = hist.size(); nl_gap = static_cast<u32>(pos - nl_last); nl_last = pos; }
        if (!is_letter(b) && is_letter(b1))
            prev_word_len_b = word_len <= 3u ? 0u : (word_len <= 6u ? 1u : (word_len <= 9u ? 2u : 3u));
        if (!is_letter(b) && is_letter(b1) && word_hash) { prev2_word_hash = prev_word_hash; prev_word_hash = word_hash; } // shift chain BEFORE reset
        if (is_letter(b)) { if (word_len < 15u) ++word_len; } else word_len = 0;
        if (g_unit_alpha && b >= 0x80 && b <= 0xFB) {
            word_hash = word_hash * 0x101u + b;      // unit codes extend the word shape
        } else if (g_unit_alpha && (b == 0xFE || b == 0xFF)) {
            if (caps_run < 15u) ++caps_run;          // cap residue = a capital just happened
        } else if (is_letter(b)) word_hash = word_hash * 0x101u + (b | 0x20u);
        else word_hash = 0;
        if (is_letter(b) && !is_letter(b1)) cur_word_caps = (b >= 'A' && b <= 'Z') ? 1u : 0u;
        if (!is_letter(b) && is_letter(b1)) prev_word_caps = cur_word_caps;
        if (b >= 'A' && b <= 'Z') { if (caps_run < 15u) ++caps_run; }
        else caps_run = 0;
        if (b >= '0' && b <= '9') { if (digit_run < 15u) ++digit_run; } else digit_run = 0;
        if (b == '[' && b1 == '[') { if (link_depth < 3u) ++link_depth; }
        else if (b == ']' && b1 == ']') { if (link_depth) --link_depth; }
        if (b == '.' || b == '!' || b == '?') sent_end = 1;
        else if (b != ' ' && b != '\n' && b != '\r' && b != '\t') sent_end = 0;
        if (byte_wrong) quiet_run = 0; else if (quiet_run < 65535u) ++quiet_run;
        b8=b7; b7=b6; b6=b5; b5=b4; b4=b3; b3=b2; b2=b1; b1=b;
    }
};

// ---------------- byte encode/decode over the bit model ----------------
static bool g_batch = false;
static void encode_byte_cm(RangeEncoder& enc, BitCMBody& body, u8 actual) {
    body.new_byte_hashes();
    if (g_batch) body.preload_byte(actual);
    u32 ctx = 1;
    u32 idx[BitCMBody::kNumModels];
    int st[BitCMBody::kNumModels];
    u32 mlen0 = body.match_len;                       // match state at byte start
    unsigned long long mbits = 0;
    for (int i = 7; i >= 0; --i) {
        int bit = (actual >> i) & 1;
        const int k = 7 - i;
        u32 p = g_batch ? body.predict(ctx, idx, st, body.pre_idx[k], body.pre_st[k])
                        : body.predict(ctx, idx, st);
        {
            u32 q = bit ? p : (4096u - p);
            if (q < 1u) q = 1u; if (q > 4095u) q = 4095u;
            mbits += (unsigned long long)g_logmb[q];
        }
        enc.encode_bit_p(p, bit);
        body.update(ctx, idx, st, p, bit);
        ctx = (ctx << 1) | static_cast<u32>(bit);
    }
    if (g_resmap) {
        const u32 mbk = mlen0 == 0 ? 0u : (mlen0 < 8 ? 1u : (mlen0 < 32 ? 2u : 3u));
        const u32 bkt = res_cls(actual) * 4u + mbk;
        g_res_mbits[bkt] += mbits;
        g_res_bytes[bkt] += 1ull;
    }
    if (g_errledger) {
        g_err_pat_mb[body.err_hist] += mbits;
        g_err_pat_n[body.err_hist] += 1ull;
    }
    {   // rhythm register update — ALWAYS (the weapon's state)
        const bool exp8 = mbits > 4000ull;
        if (g_errledger) {
            if (exp8) { if (body.err_run < 16u) ++body.err_run; }
            else if (body.err_run) { ++g_err_run[body.err_run > 16u ? 16u : body.err_run]; body.err_run = 0; }
        }
        body.err_hist = static_cast<u8>((body.err_hist << 1) | (exp8 ? 1u : 0u));
        if (exp8) body.miss_age = 0; else if (body.miss_age < 15u) ++body.miss_age;
    }
    body.absorb(actual);
}

static u8 decode_byte_cm(RangeDecoder& dec, BitCMBody& body) {
    body.new_byte_hashes();
    u32 ctx = 1;
    u32 idx[BitCMBody::kNumModels];
    int st[BitCMBody::kNumModels];
    unsigned long long mbits = 0;                     // decoder mirrors the cost arithmetic
    for (int i = 7; i >= 0; --i) {
        u32 p = body.predict(ctx, idx, st);
        int bit = dec.decode_bit_p(p);
        {
            u32 q = bit ? p : (4096u - p);
            if (q < 1u) q = 1u; if (q > 4095u) q = 4095u;
            mbits += (unsigned long long)g_logmb[q];
        }
        body.update(ctx, idx, st, p, bit);
        ctx = (ctx << 1) | static_cast<u32>(bit);
    }
    {
        const bool exp8d = mbits > 4000ull;
        body.err_hist = static_cast<u8>((body.err_hist << 1) | (exp8d ? 1u : 0u)); // lockstep register
        if (exp8d) body.miss_age = 0; else if (body.miss_age < 15u) ++body.miss_age;
    }
    u8 out = static_cast<u8>(ctx & 0xFF);
    body.absorb(out);
    return out;
}

static void put_u64(std::vector<u8>& out, u64 x) { for (int i = 0; i < 8; ++i) out.push_back(static_cast<u8>(x >> (8*i))); }
static void put_u32(std::vector<u8>& out, u32 x) { for (int i = 0; i < 4; ++i) out.push_back(static_cast<u8>(x >> (8*i))); }

// ---------------- warm-start snapshot: the learned PRIOR, not the positional state ----------------
// After chunk 0 encodes, its CM tables / mixer weights / APM calibration are a trained model of
// this file's statistics. Chunks 1..N-1 initialize from that snapshot instead of from ignorance.
// Deliberately NOT captured: hist, mtab, match state, byte-context registers, quiet_run — those
// reference absolute positions or warm up in a handful of bytes. The decoder reconstructs the
// identical snapshot after decoding chunk 0 (encoder/decoder chunk-0 state is bit-identical),
// so the scheme stays exactly decodable and chunks 1..N-1 still decode in parallel.
static bool g_warm_match = false;
struct WarmSnapshot {
    std::array<u16,256> t_order0{};
    std::vector<u16> t_hash[10];
    std::vector<s32> w, wB, wC, w2;
    std::vector<u16> apm_t, apm2_t;
    // shared match prefix: chunk 0's literal bytes + its position table. Decodable because
    // every decoder possesses chunk 0 before touching chunks 1+. Long-range repeats into the
    // file's opening (boilerplate, markup, headers) become visible to every chunk.
    std::vector<u8> hist0;
    std::vector<u32> mtab0;
    u64 last8_0 = 0;
    bool valid = false;
};

static void warm_capture(const BitCMBody& b, WarmSnapshot& s, u32 cl) {
    s.t_order0 = b.t_order0;
    for (int m = 0; m < 10; ++m) s.t_hash[m] = b.t_hash[m];
    if (cl < 15u) {
        for (auto& v : s.t_order0) v = clamp_cnt(v, cl);
        for (int m = 0; m < 10; ++m) for (auto& v : s.t_hash[m]) v = clamp_cnt(v, cl);
    }
    s.w = b.w; s.wB = b.wB; s.wC = b.wC; s.w2 = b.w2;
    s.apm_t = b.apm_t; s.apm2_t = b.apm2_t;
    if (g_warm_match) { s.hist0 = b.hist; s.mtab0 = b.mtab; s.last8_0 = b.last8;
        g_warm_pos.hist0 = b.hist; g_warm_pos.mtab0 = b.mtab; g_warm_pos.last8_0 = b.last8; }
    s.valid = true;
}

static void warm_apply(BitCMBody& b, const WarmSnapshot& s) {
    if (!s.valid) return;
    b.t_order0 = s.t_order0;
    for (int m = 0; m < 10; ++m) b.t_hash[m] = s.t_hash[m];
    b.w = s.w; b.wB = s.wB; b.wC = s.wC; b.w2 = s.w2;
    b.apm_t = s.apm_t; b.apm2_t = s.apm2_t;
    if (g_warm_match && !s.hist0.empty()) {
        b.hist = s.hist0;                     // chunk-0 bytes become a read-visible match prefix
        b.hist.reserve(s.hist0.size() + b.hist.capacity());
        b.mtab = s.mtab0;                     // positions < len0 stay valid: hist really holds them
        b.last8 = s.last8_0;
        b.match_ptr = 0; b.match_len = 0;     // no live run carries across an arbitrary boundary
    }
}

void BitCMBody::reset_positional(const WarmSnapshotPos* pos, u64 reserve_hint) {
    hist.clear(); hist.reserve(static_cast<size_t>(reserve_hint));
    last8 = 0;
    if (pos && !pos->hist0.empty()) {
        hist = pos->hist0;
        hist.reserve(pos->hist0.size() + static_cast<size_t>(reserve_hint));
        mtab = pos->mtab0;
        last8 = pos->last8_0;
    } else {
        std::fill(mtab.begin(), mtab.end(), 0xFFFFFFFFu);
    }
    // restore plasticity at the lineage boundary: keep every learned probability, re-open the
    // adaptation rate. Same clamp rule as warm_apply, applied per boundary. Deterministic.
    if (g_warm_clamp < 15u) {
        for (auto& v : t_order0) v = clamp_cnt(v, g_warm_clamp);
        for (int m = 0; m < 10; ++m)
            for (auto& v : t_hash[m]) v = clamp_cnt(v, g_warm_clamp);
    }
    match_ptr = 0; match_len = 0; match_byte = 0; match_valid_byte = false;
    cur_bit = 7;
    b1=b2=b3=b4=b5=b6=b7=b8=0;
    word_hash = 0; caps_run = 0; sent_end = 0; cur_word_caps = 0; prev_word_caps = 0;
    quiet_run = 0; byte_wrong = false;
    link_depth = 0;
    digit_run = 0;
    prev_word_hash = 0;
    word_len = 0; w2_active = false;
    prev2_word_hash = 0; w3_active = false;
    err_hist = 0; err_run = 0; miss_age = 15;
    nl_last = 0; nl_gap = 0; prev_word_len_b = 0; meter_key = 0; rest_mid = false;
}

static WarmSnapshot g_warm;
#include <atomic>
static std::atomic<u32> g_warm_drinkers{0};
static void warm_release_if_done(u32 lanes_total, bool verify_keeps) {
    if (verify_keeps) return;
    if (g_warm_drinkers.fetch_add(1) + 1 == lanes_total) {
        WarmSnapshot empty;
        std::swap(g_warm, empty);            // free ~300MB of table snapshot (one-time drink)
        // g_warm_pos stays: the positional prefix is re-drunk at EVERY chunk boundary
    }
}
static bool g_warm_mode = false;
static u32 g_prefetch_dist = 0;   // shadow lookahead distance in bytes (0 = off)
static bool g_twist = false;      // bijective contiguity relabeling (archive-identical to scatter)
static bool g_pf_families = true; // full shadow prefetch (families+mtab) vs mtab-only
static u32 g_interleave = 1;      // chunks advanced in lockstep per task
static bool g_braid = false;      // 4 continuous lineages instead of star-shaped priors


// ---------------- lookahead shadow: the encoder knows the future, so it never waits ----------------
// A tiny replica of the body's INPUT-ONLY context registers (byte history, word shape, caps,
// rolling match hash). It runs PD bytes ahead of the coding loop and issues prefetches for every
// exact table cell the real machine will touch — all 8 ctx nodes per family (the byte's bits are
// known to the encoder, so the full bit-tree path is known), plus the match-table line.
// Prefetches change no architectural state: bit-exactness is untouched by construction.
struct ShadowCtx {
    u8 b1=0,b2=0,b3=0,b4=0,b5=0,b6=0,b7=0,b8=0;
    u32 link_depth=0;
    u32 prev_word_hash=0;
    u32 prev2_word_hash=0;
    u8 word_len=0;
    u32 word_hash=0; u8 caps_run=0, sent_end=0, cur_word_caps=0, prev_word_caps=0;
    u64 last8=0; u64 nbytes=0;
    void init_from(const BitCMBody& b) {
        b1=b.b1;b2=b.b2;b3=b.b3;b4=b.b4;b5=b.b5;b6=b.b6;b7=b.b7;b8=b.b8;
        link_depth=b.link_depth;
        prev_word_hash=b.prev_word_hash;
        prev2_word_hash=b.prev2_word_hash;
        word_len=b.word_len;
        word_hash=b.word_hash; caps_run=b.caps_run; sent_end=b.sent_end;
        cur_word_caps=b.cur_word_caps; prev_word_caps=b.prev_word_caps;
        last8=b.last8; nbytes=b.hist.size();
    }
    // prefetch every line byte `v` will touch, given shadow context == body context before v
    inline void prefetch_byte(const BitCMBody& body, u8 v) const {
        u32 hb[10];   // FIX: was hb[9] while hb[9] is written below -- stack overflow (UB)
        u32 h1 = mix32(0x1000193u ^ b1*0x9e3779b9u);
        u32 h2 = mix32(h1 ^ b2*0x85ebca6bu);
        u32 h3 = mix32(h2 ^ b3*0xc2b2ae35u);
        u32 h4 = mix32(h3 ^ b4*0x27d4eb2du);
        u32 h5 = mix32(h4 ^ b5*0x165667b1u);
        u32 h6 = mix32(h5 ^ b6*0x2545f491u);
        u32 h7 = mix32(h6 ^ b7*0x9E3779B1u);
        u32 h8 = mix32(h7 ^ b8*0x7FEB352Du);   // order-8: one more link in the same chain
        u32 hw = mix32(word_hash * 0x9e3779b1u + 0x1234567u);
        const u32 linkf = (b2=='[' && b1=='[') ? 1u : 0u;
        u32 hc = mix32(0xCAFEBABEu ^ b1*0x9e3779b9u ^ word_hash*0x85ebca6bu
                       ^ (static_cast<u32>(caps_run)*0xc2b2ae35u)
                       ^ (static_cast<u32>(sent_end)<<30) ^ (linkf<<29)
                       ^ (static_cast<u32>(prev_word_caps)<<28)
                       ^ (link_depth << 26));
        u32 h7s=mix32(h6 ^ b7*0x9E3779B1u);
        u32 h8s=mix32(h7s ^ b8*0x7FEB352Du);
        u32 hw2s = mix32((prev_word_hash * 0x2545F491u) ^ (word_hash * 0x9e3779b1u) ^ 0xB5297A4Du);
        u32 hw3s = mix32((prev2_word_hash * 0x9E3779B1u) ^ (prev_word_hash * 0x85EBCA6Bu) ^ (word_hash * 0xC2B2AE35u) ^ 0x6C078965u);
        const bool w2a = (word_len <= 3u);
        const bool w3a = (word_len <= 1u);
        hb[0]=hw2s;hb[1]=h2;hb[2]=h3;hb[3]=h4;hb[4]=h5;hb[5]=h6;hb[6]=hw;hb[7]=hc;hb[8]=h8s;hb[9]=hw3s;
        if (body.twist) {
            for (u32 m=0;m<10;++m) {
                if (m == 0u && !w2a) continue;
                if (m == 9u && !w3a) continue;
                // shadow runs ahead of the coder and cannot know future match depth; it prefetches conservatively
                u32 base2;
                if (g_rightsize && m == 1) base2 = (static_cast<u32>(b1) << 16) | (static_cast<u32>(b2) << 8);
                else                       base2 = hb[m] * BitCMBody::kCtxStrideInv;
                const u32 fm = body.fam_mask[m];
                const u32 base = base2 & fm;
                __builtin_prefetch(&body.t_hash[m][base], 1, 1);
                __builtin_prefetch(&body.t_hash[m][(base + 128u) & fm], 1, 1);
            }
            return;
        }
        if (body.cache_local) {
            for (u32 m=0;m<10;++m) {
                const u32 base = hb[m] & (body.cm_mask & ~255u);
                __builtin_prefetch(&body.t_hash[m][base], 1, 1);
                __builtin_prefetch(&body.t_hash[m][base+64u], 1, 1);
                __builtin_prefetch(&body.t_hash[m][base+128u], 1, 1);
                __builtin_prefetch(&body.t_hash[m][base+192u], 1, 1);
            }
        } else {
            // encoder knows the bits, so the full 8-node bit-tree path is known exactly
            u32 c = 1u;
            for (int k=7;k>=0;--k) {
                for (u32 m=0;m<10;++m) {
                    const u32 i = (hb[m] + c*0x57F4A9u) & body.cm_mask;
                    __builtin_prefetch(&body.t_hash[m][i], 1, 1);
                }
                c = (c<<1) | ((v>>k)&1u);
            }
        }
    }
    // advance shadow past byte v, prefetching the match-table line the body will hit there
    inline void absorb(const BitCMBody& body, u8 v) {
        last8 = (last8<<8) | v;
        ++nbytes;
        if (nbytes >= 8) {
            u64 z = last8 * 0x9E3779B97F4A7C15ULL;
            z ^= z>>29; z *= 0xBF58476D1CE4E5B9ULL; z ^= z>>32;
            const u32 h = static_cast<u32>(z) & body.mm_mask;
            __builtin_prefetch(&body.mtab[h], 1, 1);
        }
        if (!BitCMBody::is_letter(v) && BitCMBody::is_letter(b1) && word_hash) { prev2_word_hash = prev_word_hash; prev_word_hash = word_hash; }
        if (BitCMBody::is_letter(v)) { if (word_len < 15u) ++word_len; } else word_len = 0;
        if (BitCMBody::is_letter(v)) word_hash = word_hash*0x101u + (v|0x20u);
        else word_hash = 0;
        if (BitCMBody::is_letter(v) && !BitCMBody::is_letter(b1)) cur_word_caps = (v>='A'&&v<='Z')?1u:0u;
        if (!BitCMBody::is_letter(v) && BitCMBody::is_letter(b1)) prev_word_caps = cur_word_caps;
        if (v>='A'&&v<='Z') { if (caps_run<15u) ++caps_run; } else caps_run = 0;
        if (v=='[' && b1=='[') { if (link_depth < 3u) ++link_depth; }
        else if (v==']' && b1==']') { if (link_depth) --link_depth; }
        if (v=='.'||v=='!'||v=='?') sent_end = 1;
        else if (v!=' '&&v!='\n'&&v!='\r'&&v!='\t') sent_end = 0;
        b8=b7;b7=b6;b6=b5;b5=b4;b4=b3;b3=b2;b2=b1;b1=v;
    }
};

// ---------------- chunk framework (kept from v217E; set --chunk-bytes >= file size for one sequential body) ----------------
struct ChunkResult {
    u64 index = 0;
    u64 start = 0;
    u64 raw_size = 0;
    u64 stream_size = 0;
    bool exact = true;
    u64 first_mismatch = 0;
    double encode_seconds = 0.0;
    double decode_seconds = 0.0;
    std::vector<u8> stream;
};

static std::vector<u8> read_slice(const std::string& path, u64 start, u64 len) {
    std::ifstream f(path, std::ios::binary);
    if (!f) die("cannot open input: " + path);
    f.seekg(static_cast<std::streamoff>(start));
    std::vector<u8> buf(static_cast<size_t>(len));
    if (len) f.read(reinterpret_cast<char*>(buf.data()), static_cast<std::streamsize>(len));
    return buf;
}

static ChunkResult encode_chunk_streamed(
    const std::string& path,
    u64 index,
    u64 start,
    u64 len,
    u32 cm_bits,
    u32 mm_bits,
    bool cache_local_layout,
    bool verify,
    bool keep_stream
);

static ChunkResult encode_chunk(
    const std::vector<u8>& input,
    u64 index,
    u64 start,
    u64 len,
    u32 cm_bits,
    u32 mm_bits,
    bool cache_local_layout,
    bool verify,
    bool keep_stream
) {
    ChunkResult r;
    r.index = index;
    r.start = start;
    r.raw_size = len;
    auto t0 = std::chrono::steady_clock::now();

    BitCMBody body_enc(cm_bits, mm_bits, len);
    body_enc.cache_local = cache_local_layout; body_enc.twist = g_twist;
    if (index > 0) warm_apply(body_enc, g_warm);   // chunks 1+: inherit the trained prior
    RangeEncoder renc;
    renc.out.reserve(static_cast<size_t>(len > 1024 ? (len / 2) + 1024 : 4096));
    const u32 PD = g_prefetch_dist;
    if (PD == 0) {
        for (u64 i = 0; i < len; ++i) {
            encode_byte_cm(renc, body_enc, input[static_cast<size_t>(start + i)]);
            if ((i & 0xFFFFu) == 0xFFFFu) progress_add(65536ull);   // every 64KB
        }
        progress_add(len & 0xFFFFull);
    } else {
        ShadowCtx sh; sh.init_from(body_enc);
        u64 ahead = 0;                       // bytes the shadow has absorbed
        const u64 lim = len;
        for (; ahead + 1 < PD && ahead < lim; ++ahead) {   // prime the pipeline
            if (g_pf_families) sh.prefetch_byte(body_enc, input[static_cast<size_t>(start + ahead)]);
            sh.absorb(body_enc, input[static_cast<size_t>(start + ahead)]);
        }
        for (u64 i = 0; i < len; ++i) {
            if (ahead < lim) {
                if (g_pf_families) sh.prefetch_byte(body_enc, input[static_cast<size_t>(start + ahead)]);
                sh.absorb(body_enc, input[static_cast<size_t>(start + ahead)]);
                ++ahead;
            }
            encode_byte_cm(renc, body_enc, input[static_cast<size_t>(start + i)]);
            if ((i & 0xFFFFu) == 0xFFFFu) progress_add(65536ull);   // every 64KB
        }
        progress_add(len & 0xFFFFull);
    }
    renc.flush();
    if (g_warm_mode && index == 0) warm_capture(body_enc, g_warm, g_warm_clamp);
    auto t1 = std::chrono::steady_clock::now();
    r.stream_size = static_cast<u64>(renc.out.size());

    if (verify) {
        BitCMBody body_dec(cm_bits, mm_bits, len);
        body_dec.cache_local = cache_local_layout; body_dec.twist = g_twist;
        if (index > 0) warm_apply(body_dec, g_warm); // decoder applies the identical prior
        RangeDecoder rdec(renc.out);
        for (u64 i = 0; i < len; ++i) {
            const u8 got = decode_byte_cm(rdec, body_dec);
            const u8 want = input[static_cast<size_t>(start + i)];
            if (got != want) {
                r.exact = false;
                r.first_mismatch = start + i;
                break;
            }
        }
    }
    auto t2 = std::chrono::steady_clock::now();
    r.encode_seconds = std::chrono::duration<double>(t1 - t0).count();
    r.decode_seconds = std::chrono::duration<double>(t2 - t1).count();

    if (keep_stream) r.stream.swap(renc.out);
    return r;
}

static ChunkResult encode_chunk_streamed(
    const std::string& path, u64 index, u64 start, u64 len,
    u32 cm_bits, u32 mm_bits, bool cache_local_layout, bool verify, bool keep_stream
) {
    std::vector<u8> slice = read_slice(path, start, len);
    ChunkResult r = encode_chunk(slice, index, 0, len, cm_bits, mm_bits, cache_local_layout, verify, keep_stream);
    r.start = start;
    return r;
}

// Pair-interleaved encode: two independent chunks advance byte-by-byte in lockstep within one
// thread. While chunk A's table lines are in flight (DRAM latency), chunk B's arithmetic issues,
// and vice versa — the out-of-order core overlaps the stalls. Latency hiding, no intrinsics.
static void encode_chunk_pair(
    const std::vector<u8>& input,
    ChunkResult* ra, u64 sa, u64 la,
    ChunkResult* rb, u64 sb, u64 lb,
    u32 cm_bits, u32 mm_bits, bool cache_local_layout, bool verify, bool keep_stream
) {
    auto t0 = std::chrono::steady_clock::now();
    BitCMBody A(cm_bits, mm_bits, la), B(cm_bits, mm_bits, lb);
    A.cache_local = cache_local_layout; B.cache_local = cache_local_layout; A.twist = g_twist; B.twist = g_twist;
    RangeEncoder ea, eb;
    ea.out.reserve(static_cast<size_t>(la/2+1024));
    eb.out.reserve(static_cast<size_t>(lb/2+1024));
    const u64 n = la > lb ? la : lb;
    for (u64 i = 0; i < n; ++i) {
        if (i < la) encode_byte_cm(ea, A, input[static_cast<size_t>(sa + i)]);
        if (i < lb) encode_byte_cm(eb, B, input[static_cast<size_t>(sb + i)]);
    }
    ea.flush(); eb.flush();
    auto t1 = std::chrono::steady_clock::now();
    ra->stream_size = ea.out.size(); rb->stream_size = eb.out.size();
    ra->raw_size = la; rb->raw_size = lb; ra->start = sa; rb->start = sb;
    if (verify) {
        BitCMBody DA(cm_bits, mm_bits, la); DA.cache_local = cache_local_layout; DA.twist = g_twist;
        BitCMBody DB(cm_bits, mm_bits, lb); DB.cache_local = cache_local_layout; DB.twist = g_twist;
        RangeDecoder da(ea.out), db(eb.out);
        const u64 vn = n;
        for (u64 i = 0; i < vn; ++i) {
            if (i < la && ra->exact) {
                const u8 got = decode_byte_cm(da, DA);
                if (got != input[static_cast<size_t>(sa + i)]) { ra->exact = false; ra->first_mismatch = sa + i; }
            }
            if (i < lb && rb->exact) {
                const u8 got = decode_byte_cm(db, DB);
                if (got != input[static_cast<size_t>(sb + i)]) { rb->exact = false; rb->first_mismatch = sb + i; }
            }
        }
    }
    auto t2 = std::chrono::steady_clock::now();
    ra->encode_seconds = rb->encode_seconds = std::chrono::duration<double>(t1 - t0).count() / 2.0;
    ra->decode_seconds = rb->decode_seconds = std::chrono::duration<double>(t2 - t1).count() / 2.0;
    if (keep_stream) { ra->stream.swap(ea.out); rb->stream.swap(eb.out); }
}


// N-way interleaved encode: N independent chunks advance byte-by-byte in lockstep in ONE thread.
// While one body's table lines are in DRAM flight, the others' arithmetic issues — the same
// latency-hiding as the pair prototype, but with tunable depth. Pure scheduling: archive bytes
// per chunk are identical to sequential encode of the same chunk.
static void encode_chunk_group(
    const std::vector<u8>& input,
    std::vector<ChunkResult*> rs, const std::vector<u64>& starts, const std::vector<u64>& lens,
    u32 cm_bits, u32 mm_bits, bool cache_local_layout, bool verify, bool keep_stream
) {
    const size_t N = rs.size();
    auto t0 = std::chrono::steady_clock::now();
    std::vector<std::unique_ptr<BitCMBody>> bodies(N);
    std::vector<std::unique_ptr<ShadowCtx>> shadows(N);
    std::vector<u64> aheads(N, 0);
    std::vector<RangeEncoder> encs(N);
    const u32 PD = g_prefetch_dist;
    u64 n = 0;
    for (size_t k = 0; k < N; ++k) {
        bodies[k] = std::make_unique<BitCMBody>(cm_bits, mm_bits, lens[k]);
        bodies[k]->cache_local = cache_local_layout; bodies[k]->twist = g_twist;
        warm_apply(*bodies[k], g_warm);          // group path is only used for chunks >= 1
        encs[k].out.reserve(static_cast<size_t>(lens[k]/2 + 1024));
        if (n < lens[k]) n = lens[k];
        if (PD) {
            shadows[k] = std::make_unique<ShadowCtx>();
            shadows[k]->init_from(*bodies[k]);
            for (; aheads[k] + 1 < PD && aheads[k] < lens[k]; ++aheads[k]) {
                shadows[k]->prefetch_byte(*bodies[k], input[static_cast<size_t>(starts[k] + aheads[k])]);
                shadows[k]->absorb(*bodies[k], input[static_cast<size_t>(starts[k] + aheads[k])]);
            }
        }
    }
    for (u64 i = 0; i < n; ++i) {
        if (PD) {
            for (size_t k = 0; k < N; ++k) {         // issue ALL bodies' future misses first...
                if (aheads[k] < lens[k]) {
                    shadows[k]->prefetch_byte(*bodies[k], input[static_cast<size_t>(starts[k] + aheads[k])]);
                    shadows[k]->absorb(*bodies[k], input[static_cast<size_t>(starts[k] + aheads[k])]);
                    ++aheads[k];
                }
            }
        }
        for (size_t k = 0; k < N; ++k)               // ...then do everyone's arithmetic over them
            if (i < lens[k]) encode_byte_cm(encs[k], *bodies[k], input[static_cast<size_t>(starts[k] + i)]);
    }
    for (size_t k = 0; k < N; ++k) encs[k].flush();
    auto t1 = std::chrono::steady_clock::now();
    for (size_t k = 0; k < N; ++k) {
        rs[k]->stream_size = encs[k].out.size();
        rs[k]->raw_size = lens[k]; rs[k]->start = starts[k];
    }
    if (verify) {
        for (size_t k = 0; k < N; ++k) {
            BitCMBody dec(cm_bits, mm_bits, lens[k]);
            dec.cache_local = cache_local_layout; dec.twist = g_twist;
            warm_apply(dec, g_warm);
            RangeDecoder rd(encs[k].out);
            for (u64 i = 0; i < lens[k]; ++i) {
                const u8 got = decode_byte_cm(rd, dec);
                if (got != input[static_cast<size_t>(starts[k] + i)]) {
                    rs[k]->exact = false; rs[k]->first_mismatch = starts[k] + i; break;
                }
            }
        }
    }
    auto t2 = std::chrono::steady_clock::now();
    const double es = std::chrono::duration<double>(t1 - t0).count() / static_cast<double>(N);
    const double ds = std::chrono::duration<double>(t2 - t1).count() / static_cast<double>(N);
    for (size_t k = 0; k < N; ++k) { rs[k]->encode_seconds = es; rs[k]->decode_seconds = ds; }
    if (keep_stream) for (size_t k = 0; k < N; ++k) rs[k]->stream.swap(encs[k].out);
}

static u64 get_u64(const std::vector<u8>& v, size_t& o){ u64 x=0; for(int i=0;i<8;++i) x |= (u64)v[o+i] << (8*i); o+=8; return x; }
static u32 get_u32(const std::vector<u8>& v, size_t& o){ u32 x=0; for(int i=0;i<4;++i) x |= (u32)v[o+i] << (8*i); o+=4; return x; }


// ---------------- decode-side lookahead: prefetch the NEXT byte's rows ----------------
// Mirrors THIS core's ShadowCtx twist branch (10 hashed models, w2/w3 word-length
// gating), reading the live body's registers -- which already sit at the next-byte
// state once decode_byte_cm has absorbed the current byte. Row addresses depend only
// on context before the byte, never its value, so decode needs no future knowledge.
// Semantically inert; pays off when lanes share a thread (other lanes' arithmetic
// becomes this body's DRAM lead time).
static inline void prefetch_next_rows(const BitCMBody& body) {
    u32 hb[10];
    u32 h1 = mix32(0x1000193u ^ body.b1*0x9e3779b9u);
    u32 h2 = mix32(h1 ^ body.b2*0x85ebca6bu);
    u32 h3 = mix32(h2 ^ body.b3*0xc2b2ae35u);
    u32 h4 = mix32(h3 ^ body.b4*0x27d4eb2du);
    u32 h5 = mix32(h4 ^ body.b5*0x165667b1u);
    u32 h6 = mix32(h5 ^ body.b6*0x2545f491u);
    u32 h7 = mix32(h6 ^ body.b7*0x9E3779B1u);
    u32 h8 = mix32(h7 ^ body.b8*0x7FEB352Du);
    (void)h1; (void)h8;
    u32 hw = mix32(body.word_hash * 0x9e3779b1u + 0x1234567u);
    const u32 linkf = (body.b2=='[' && body.b1=='[') ? 1u : 0u;
    u32 hc = mix32(0xCAFEBABEu ^ body.b1*0x9e3779b9u ^ body.word_hash*0x85ebca6bu
                   ^ (static_cast<u32>(body.caps_run)*0xc2b2ae35u)
                   ^ (static_cast<u32>(body.sent_end)<<30) ^ (linkf<<29)
                   ^ (static_cast<u32>(body.prev_word_caps)<<28)
                   ^ (body.link_depth << 26));
    u32 h7s = mix32(h6 ^ body.b7*0x9E3779B1u);
    u32 h8s = mix32(h7s ^ body.b8*0x7FEB352Du);
    u32 hw2s = mix32((body.prev_word_hash * 0x2545F491u) ^ (body.word_hash * 0x9e3779b1u) ^ 0xB5297A4Du);
    u32 hw3s = mix32((body.prev2_word_hash * 0x9E3779B1u) ^ (body.prev_word_hash * 0x85EBCA6Bu) ^ (body.word_hash * 0xC2B2AE35u) ^ 0x6C078965u);
    const bool w2a = (body.word_len <= 3u);
    const bool w3a = (body.word_len <= 1u);
    hb[0]=hw2s;hb[1]=h2;hb[2]=h3;hb[3]=h4;hb[4]=h5;hb[5]=h6;hb[6]=hw;hb[7]=hc;hb[8]=h8s;hb[9]=hw3s;
    if (body.twist) {
        for (u32 m=0;m<10;++m) {
            if (m == 0u && !w2a) continue;
            if (m == 9u && !w3a) continue;
            u32 base2;
            if (g_rightsize && m == 1) base2 = (static_cast<u32>(body.b1) << 16) | (static_cast<u32>(body.b2) << 8);
            else                       base2 = hb[m] * BitCMBody::kCtxStrideInv;
            const u32 fm = body.fam_mask[m];
            const u32 base = base2 & fm;
            __builtin_prefetch(&body.t_hash[m][base], 1, 1);
            __builtin_prefetch(&body.t_hash[m][(base + 128u) & fm], 1, 1);
        }
    } else {
        for (u32 m=0;m<10;++m) {
            const u32 i = (hb[m] + 0x57F4A9u) & body.cm_mask;   // bit-tree root node
            __builtin_prefetch(&body.t_hash[m][i], 1, 1);
        }
    }
    if (body.hist.size() >= 8) {
        u64 z = body.last8 * 0x9E3779B97F4A7C15ULL;
        z ^= z>>29; z *= 0xBF58476D1CE4E5B9ULL; z ^= z>>32;
        const u32 h = static_cast<u32>(z) & body.mm_mask;
        __builtin_prefetch(&body.mtab[h], 0, 1);
    }
}

static int extract_main(const std::string& archive_path, const std::string& out_path, u32 threads) {
    auto t0 = std::chrono::steady_clock::now();
    std::vector<u8> a;
    { std::ifstream f(archive_path, std::ios::binary); if(!f) die("cannot open archive: "+archive_path);
      f.seekg(0,std::ios::end); a.resize((size_t)f.tellg()); f.seekg(0); f.read((char*)a.data(),(std::streamsize)a.size()); }
    if (a.size() >= 24 && (memcmp(a.data(), "MDLBSTOR", 8) == 0 || memcmp(a.data(), "MDLBSTOF", 8) == 0)) {
        auto t0s = std::chrono::steady_clock::now();
        size_t so = 8;
        const u64 raw_size = get_u64(a, so);
        g_progress_total = raw_size;
        const u64 want_fnv = get_u64(a, so);
        if (a.size() != so + raw_size) die("stored archive truncated or trailing garbage");
        u64 fnv = 1469598103934665603ULL;
        for (u64 i = 0; i < raw_size; ++i) { fnv ^= a[so + static_cast<size_t>(i)]; fnv *= 1099511628211ULL; }
        if (fnv != want_fnv) die("INTEGRITY FAILURE: checksum mismatch in stored archive");
        std::vector<u8> out(a.begin() + static_cast<long>(so), a.end());
        progress_add(raw_size);
        write_all(out_path, out);
        auto t1s = std::chrono::steady_clock::now();
        std::cout << "[mdlbsg] extracted_bytes=" << raw_size << "\n";
        std::cout << "[mdlbsg] integrity=verified\n";
        std::cout << "[mdlbsg] wall_seconds=" << std::chrono::duration<double>(t1s-t0s).count() << "\n";
        return 0;
    }
    if (a.size() < 43 || (memcmp(a.data(), "MDLB301A", 8) != 0 && memcmp(a.data(), "MDLB301F", 8) != 0)) die("not an MDLB301A archive (older archives lack the self-describing header)");
    size_t o = 8;
    const u64 raw_size = get_u64(a,o);
    g_progress_total = raw_size;              // decode progress is measured in bytes
    const u64 want_fnv = get_u64(a,o);
    const u32 cm_bits = a[o++]; const u32 mm_bits = a[o++];
    g_w2_bits = a[o++]; g_w3_bits = a[o++];
    const u8 layout = a[o++]; g_warm_clamp = a[o++];
    const u8 fl = a[o++];
    g_rightsize = fl & 1u; g_warm_mode = (fl >> 1) & 1u; g_warm_match = (fl >> 2) & 1u; g_unit_alpha = (fl >> 3) & 1u;
    const bool braid = (fl >> 4) & 1u;
    const u32 L = a[o++];                              // lineage count from the birth certificate
    g_twist = (layout == 2u); const bool cache_local = (layout == 1u);
    const u64 chunk_bytes = get_u64(a,o); (void)chunk_bytes;
    const u32 chunks = get_u32(a,o);
    std::vector<u64> craw(chunks), cstr(chunks), coff(chunks);
    for (u32 c = 0; c < chunks; ++c) { craw[c] = get_u64(a,o); cstr[c] = get_u64(a,o); }
    for (u32 c = 0; c < chunks; ++c) { coff[c] = o; o += cstr[c]; }
    if (o != a.size()) die("archive truncated or trailing garbage");
    std::vector<u8> out(static_cast<size_t>(raw_size));
    std::vector<u64> starts(chunks); { u64 s2=0; for(u32 c=0;c<chunks;++c){ starts[c]=s2; s2+=craw[c]; } }
    // chunk 0: cold, exactly as encoded
    {
        BitCMBody dec(cm_bits, mm_bits, craw[0]);
        dec.cache_local = cache_local; dec.twist = g_twist;
        std::vector<u8> st(a.begin()+(long)coff[0], a.begin()+(long)(coff[0]+cstr[0]));
        RangeDecoder rd(st);
        for (u64 i = 0; i < craw[0]; ++i) {
            out[static_cast<size_t>(i)] = decode_byte_cm(rd, dec);
            if ((i & 0xFFFFu) == 0xFFFFu) progress_add(65536ull);
        }
        progress_add(craw[0] & 0xFFFFull);
        if (g_warm_mode && chunks > 1) warm_capture(dec, g_warm, g_warm_clamp);
    }
    // chunks 1+: LIFELONG LINEAGES — lineage t owns chunks 1+t, 1+t+L, ... with ONE body
    // whose learned state flows chunk-to-chunk; only positional state resets per chunk.
    // Exact mirror of the braid encoder. Lineages decode in parallel with each other.
    if (chunks > 1) {
        if (!braid || !g_warm_mode) die("archive uses a non-braid layout this extractor does not support yet");
        // LOCKSTEP LANE DECODE -- the encoder's latency-hiding trick, ported to decode.
        // Lanes are semantic (each is a continuous lineage) so they can't be split, but
        // they CAN share OS threads: each thread advances its lanes byte-by-byte in
        // lockstep, so one body's DRAM miss overlaps the others' arithmetic. Per-lane
        // call order is IDENTICAL to the one-thread-per-lane version -- only cross-lane
        // scheduling changes, so decoded bytes cannot change. Archive bytes untouched.
        u32 T = threads ? threads : std::max<u32>(1u, std::thread::hardware_concurrency());
        if (T > L) T = L;   // more threads than lanes cannot help; lanes cannot split
        struct LaneState {
            std::unique_ptr<BitCMBody> body;
            // The stream lives behind a unique_ptr so its ADDRESS survives moves of
            // LaneState: RangeDecoder holds a reference to it, and a moved vector
            // would leave that reference pointing at an empty husk (that exact bug
            // produced silent zero-fill decode -- caught by the integrity check).
            std::unique_ptr<std::vector<u8>> stream;
            std::unique_ptr<RangeDecoder> rd;
            u64 ci = 0, pos = 0, len = 0;
            bool done = false;
        };
        std::vector<std::thread> group;
        for (u32 g = 0; g < T; ++g) {
            group.emplace_back([&, g]() {
                std::vector<LaneState> ls;   // lanes g, g+T, g+2T, ... interleave here
                auto load_chunk = [&](LaneState& s) {
                    while (true) {
                        if (s.ci >= chunks) { s.done = true; s.rd.reset(); return; }
                        s.body->reset_positional(g_warm_match ? &g_warm_pos : nullptr, craw[s.ci]);
                        s.stream = std::make_unique<std::vector<u8>>(a.begin()+(long)coff[s.ci], a.begin()+(long)(coff[s.ci]+cstr[s.ci]));
                        s.rd = std::make_unique<RangeDecoder>(*s.stream);
                        s.pos = 0; s.len = craw[s.ci];
                        if (s.len > 0) return;
                        s.ci += L;           // zero-length chunk: nothing to decode, move on
                    }
                };
                for (u32 t = g; t < L; t += T) {
                    LaneState s;
                    s.body = std::make_unique<BitCMBody>(cm_bits, mm_bits, chunk_bytes);
                    s.body->cache_local = cache_local; s.body->twist = g_twist;
                    warm_apply(*s.body, g_warm);
                    s.ci = 1 + t;
                    load_chunk(s);
                    ls.push_back(std::move(s));
                }
                while (true) {
                    bool any = false;
                    for (auto& s : ls) {
                        if (s.done) continue;
                        any = true;
                        out[static_cast<size_t>(starts[s.ci] + s.pos)] = decode_byte_cm(*s.rd, *s.body);
                        // issue next-byte prefetches only when other lanes will run in
                        // between -- with one lane per thread there is no lead time to buy
                        if (ls.size() > 1) prefetch_next_rows(*s.body);
                        if ((s.pos & 0xFFFFu) == 0xFFFFu) progress_add(65536ull);
                        ++s.pos;
                        if (s.pos == s.len) {
                            progress_add(s.len & 0xFFFFull);
                            s.ci += L;
                            load_chunk(s);
                        }
                    }
                    if (!any) break;
                }
            });
        }
        for (auto& th : group) th.join();
    }
    u64 fnv = 1469598103934665603ULL;
    for (u64 i = 0; i < raw_size; ++i) { fnv ^= out[static_cast<size_t>(i)]; fnv *= 1099511628211ULL; }
    if (fnv != want_fnv) die("INTEGRITY FAILURE: checksum mismatch after extraction");
    write_all(out_path, out);
    auto t1 = std::chrono::steady_clock::now();
    std::cout << "[mdlbsg] extracted_bytes=" << raw_size << "\n";
    std::cout << "[mdlbsg] integrity=verified\n";
    std::cout << "[mdlbsg] wall_seconds=" << std::chrono::duration<double>(t1-t0).count() << "\n";
    return 0;
}

int main(int argc, char** argv) {
    std::string input_path, archive_path, report_path, extract_to;
    bool do_extract = false;
    u32 cm_bits = 22;
    u32 mm_bits = 22;
    bool cache_local_layout = false;
    u64 mem_budget_gb = 8;
    bool pair_mode = false;
    bool stream_input = false;
    u64 chunk_bytes = 16ULL * 1024ULL * 1024ULL;
    u32 threads = std::max<u32>(1u, std::thread::hardware_concurrency());
    bool verify = true;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto need = [&](const std::string&) -> std::string { if (i+1>=argc) die("missing arg value"); return argv[++i]; };
        if (a == "--input") input_path = need(a);
        else if (a == "--archive") archive_path = need(a);
        else if (a == "--report") report_path = need(a);
        else if (a == "--cm-bits") cm_bits = static_cast<u32>(std::stoul(need(a)));
        else if (a == "--mm-bits") mm_bits = static_cast<u32>(std::stoul(need(a)));
        else if (a == "--layout") { std::string v = need(a); cache_local_layout = (v == "block"); g_twist = (v == "twist"); }
        else if (a == "--mem-budget-gb") mem_budget_gb = static_cast<u64>(std::stoull(need(a)));
        else if (a == "--pair") pair_mode = (need(a) != "0");
        else if (a == "--stream-input") stream_input = (need(a) != "0");
        else if (a == "--chunk-bytes") chunk_bytes = static_cast<u64>(std::stoull(need(a)));
        else if (a == "--threads") threads = static_cast<u32>(std::stoul(need(a)));
        else if (a == "--verify") verify = (need(a) != "0");
        else if (a == "--warm") g_warm_mode = (need(a) != "0");
        else if (a == "--warm-clamp") g_warm_clamp = static_cast<u32>(std::stoul(need(a)));
        else if (a == "--warm-match") g_warm_match = (need(a) != "0");
        else if (a == "--prefetch-dist") g_prefetch_dist = static_cast<u32>(std::stoul(need(a)));
        else if (a == "--prefetch-mode") g_pf_families = (need(a) != "mtab");
        else if (a == "--braid") g_braid = (need(a) != "0");
        else if (a == "--batch") g_batch = (need(a) != "0");
        else if (a == "--unit-alphabet") g_unit_alpha = (need(a) != "0");
        else if (a == "--rightsize") g_rightsize = (need(a) != "0");
        else if (a == "--residual-map") g_resmap = (need(a) != "0");
        else if (a == "--progress-file") g_progress_path = need(a);
        else if (a == "--content") g_content_folder = (need(a) == "folder");
        else if (a == "--error-ledger") g_errledger = (need(a) != "0");
        else if (a == "--extract") { do_extract = true; extract_to = need(a); }
        else if (a == "--time-ledger") g_timeledger = (need(a) != "0");
        else if (a == "--w2-bits") g_w2_bits = static_cast<u32>(std::stoul(need(a)));
        else if (a == "--w3-bits") g_w3_bits = static_cast<u32>(std::stoul(need(a)));
        else if (a == "--simd") g_simd = (need(a) != "0");
        else if (a == "--interleave") g_interleave = std::max(1u, static_cast<u32>(std::stoul(need(a))));
        else die("unknown arg: " + a);
    }
    simd_self_proof();
    resmap_init(); // rhythm register is a MODEL feature now — cost table always live
    if (g_rightsize && !g_twist) die("--rightsize requires --layout twist");
    if (g_rightsize && cm_bits < 24) die("--rightsize requires --cm-bits >= 24");
    if (do_extract) {
        if (archive_path.empty()) die("--archive is required for --extract");
        return extract_main(archive_path, extract_to, threads);
    }
    if (input_path.empty()) die("--input required");
    if (chunk_bytes == 0) die("--chunk-bytes must be > 0");
    if (cm_bits < 16 || cm_bits > 30) die("--cm-bits must be 16..30");
    threads = std::max<u32>(1u, threads);
    // ---- memory guard: thrash is silent death; make it loud and impossible ----
    // Per-chunk body estimate: 8 hashed tables (u16) + match table (u32) + history buffer.
    {
        const u64 body_bytes = 10ull * ((1ull << cm_bits) * 2ull)
                             + ((1ull << mm_bits) * 4ull)
                             + chunk_bytes + (64ull << 20);
        const u64 budget = mem_budget_gb << 30;
        u32 fit = static_cast<u32>(std::max<u64>(1ull, (budget / std::max<u64>(1ull, body_bytes)) / g_interleave));
        std::cout << "[v234] per_thread_body_bytes=" << body_bytes
                  << " (" << (body_bytes >> 20) << " MB)"
                  << " mem_budget=" << mem_budget_gb << "GB"
                  << " -> max_concurrent_bodies=" << fit << "\n";
        if (threads > fit) {
            std::cout << "[v234] WARNING: requested threads=" << threads
                      << " would need " << ((threads * body_bytes) >> 30)
                      << "GB and cause swap-thrash. Clamping threads=" << fit << ".\n"
                      << "[v234] To use more threads: lower --cm-bits/--mm-bits/--chunk-bytes"
                      << " or raise --mem-budget-gb if you truly have the RAM.\n";
            threads = fit;
        }
    }

    std::vector<u8> input;
    u64 raw_size = 0;
    if (stream_input) {
        std::ifstream f(input_path, std::ios::binary);
        if (!f) die("cannot open input: " + input_path);
        f.seekg(0, std::ios::end);
        raw_size = static_cast<u64>(f.tellg());
        std::cout << "[v234] stream_input=1 (input read per-chunk; ~1GB less resident memory)\n";
    } else {
        input = read_all(input_path);
        raw_size = static_cast<u64>(input.size());
    }
    const u64 chunks = raw_size == 0 ? 1 : ((raw_size + chunk_bytes - 1) / chunk_bytes);
    g_progress_total = static_cast<unsigned long long>(raw_size);   // progress is measured in BYTES
    const bool keep_stream = !archive_path.empty();
    std::vector<ChunkResult> kept;
    if (keep_stream) kept.resize(static_cast<size_t>(chunks));

    auto t0 = std::chrono::steady_clock::now();

    u64 total_stream_bytes = 0;
    bool exact = true;
    u64 first_mismatch = 0;
    double encode_sum = 0.0, decode_sum = 0.0;

    std::deque<std::future<ChunkResult>> active;
    auto collect_one = [&](bool force) {
        if (active.empty()) return;
        if (!force && active.size() < threads) return;
        ChunkResult r = active.front().get();
        active.pop_front();
        total_stream_bytes += r.stream_size;
        encode_sum += r.encode_seconds;
        decode_sum += r.decode_seconds;
        if (!r.exact && exact) { exact = false; first_mismatch = r.first_mismatch; }
        if (keep_stream) kept[static_cast<size_t>(r.index)] = std::move(r);
    };

    if (pair_mode) {
        // prototype path: pairs run in this thread so the interleave effect is measured cleanly
        std::vector<ChunkResult> prs(static_cast<size_t>(chunks));
        for (u64 ci = 0; ci < chunks; ci += 2) {
            const u64 sa = ci * chunk_bytes;
            const u64 la = std::min<u64>(chunk_bytes, raw_size - sa);
            ChunkResult& ra = prs[static_cast<size_t>(ci)];
            ra.index = ci;
            if (ci + 1 < chunks) {
                const u64 sb = (ci + 1) * chunk_bytes;
                const u64 lb = std::min<u64>(chunk_bytes, raw_size - sb);
                ChunkResult& rb = prs[static_cast<size_t>(ci + 1)];
                rb.index = ci + 1;
                encode_chunk_pair(input, &ra, sa, la, &rb, sb, lb,
                                  cm_bits, mm_bits, cache_local_layout, verify, keep_stream);
            } else {
                ra = encode_chunk(input, ci, sa, la, cm_bits, mm_bits, cache_local_layout, verify, keep_stream);
            }
        }
        for (auto& r : prs) {
            total_stream_bytes += r.stream_size;
            encode_sum += r.encode_seconds; decode_sum += r.decode_seconds;
            if (!r.exact && exact) { exact = false; first_mismatch = r.first_mismatch; }
            if (keep_stream) kept[static_cast<size_t>(r.index)] = std::move(r);
        }
    } else {
    u64 first_ci = 0;
    if (g_warm_mode && chunks > 1) {
        // chunk 0 runs alone: its finished body IS the prior for everyone else.
        const u64 len0 = std::min<u64>(chunk_bytes, raw_size);
        ChunkResult r0 = stream_input
            ? encode_chunk_streamed(input_path, 0, 0, len0, cm_bits, mm_bits, cache_local_layout, verify, keep_stream)
            : encode_chunk(input, 0, 0, len0, cm_bits, mm_bits, cache_local_layout, verify, keep_stream);
        total_stream_bytes += r0.stream_size;
        encode_sum += r0.encode_seconds; decode_sum += r0.decode_seconds;
        if (!r0.exact && exact) { exact = false; first_mismatch = r0.first_mismatch; }
        if (keep_stream) kept[0] = std::move(r0);
        std::cout << "[v234] warm prior captured from chunk 0 (clamp=" << g_warm_clamp << ")\n";
        first_ci = 1;
    }
    if (g_braid && g_warm_mode && chunks > 1) {
        // BRAID: L continuous lineages. Lineage t encodes chunks 1+t, 1+t+L, ... with ONE body
        // whose learned state (tables/mixer/APM) flows chunk-to-chunk; only positional state
        // resets at each boundary. Deterministic; decoder replays lineages in the same order.
        const u32 L = threads;
        std::vector<ChunkResult> brs(static_cast<size_t>(chunks));
        std::vector<std::thread> lanes;
        for (u32 t = 0; t < L; ++t) {
            lanes.emplace_back([&, t]() {
                BitCMBody enc_body(cm_bits, mm_bits, chunk_bytes);
                enc_body.cache_local = cache_local_layout; enc_body.twist = g_twist;
                warm_apply(enc_body, g_warm);          // lineage roots at the chunk-0 prior
                std::unique_ptr<BitCMBody> dec_body;
                if (verify) {
                    dec_body = std::make_unique<BitCMBody>(cm_bits, mm_bits, chunk_bytes);
                    dec_body->cache_local = cache_local_layout; dec_body->twist = g_twist;
                    warm_apply(*dec_body, g_warm);
                }
                warm_release_if_done(L, verify);       // last drinker frees the ~300MB source
                std::vector<u8> slice_buf;
                for (u64 ci = 1 + t; ci < chunks; ci += L) {
                    const u64 start = ci * chunk_bytes;
                    const u64 len = std::min<u64>(chunk_bytes, raw_size - start);
                    // streaming: this lineage reads only its own 16MB slice; the gigabyte never
                    // sits resident. Identical bytes, ~1GB less memory pressure on small machines.
                    const u8* src;
                    u64 off;
                    if (stream_input) {
                        slice_buf = read_slice(input_path, start, len);
                        src = slice_buf.data(); off = 0;
                    } else { src = input.data(); off = start; }
                    ChunkResult& r = brs[static_cast<size_t>(ci)];
                    r.index = ci; r.start = start; r.raw_size = len;
                    enc_body.reset_positional(g_warm_match ? &g_warm_pos : nullptr, len);
                    auto t0 = std::chrono::steady_clock::now();
                    RangeEncoder re; re.out.reserve(static_cast<size_t>(len/2 + 1024));
                    const u32 PD = g_prefetch_dist;
                    if (PD == 0) {
                        for (u64 i = 0; i < len; ++i) {
                            encode_byte_cm(re, enc_body, src[static_cast<size_t>(off + i)]);
                            if ((i & 0xFFFFu) == 0xFFFFu) progress_add(65536ull);
                        }
                        progress_add(len & 0xFFFFull);
                    } else {
                        ShadowCtx sh; sh.init_from(enc_body);
                        u64 ahead = 0;
                        for (; ahead + 1 < PD && ahead < len; ++ahead) {
                            if (g_pf_families) sh.prefetch_byte(enc_body, src[static_cast<size_t>(off + ahead)]);
                            sh.absorb(enc_body, src[static_cast<size_t>(off + ahead)]);
                        }
                        for (u64 i = 0; i < len; ++i) {
                            if (ahead < len) {
                                if (g_pf_families) sh.prefetch_byte(enc_body, src[static_cast<size_t>(off + ahead)]);
                                sh.absorb(enc_body, src[static_cast<size_t>(off + ahead)]);
                                ++ahead;
                            }
                            encode_byte_cm(re, enc_body, src[static_cast<size_t>(off + i)]);
                            if ((i & 0xFFFFu) == 0xFFFFu) progress_add(65536ull);
                        }
                        progress_add(len & 0xFFFFull);
                    }
                    re.flush();
                    auto t1 = std::chrono::steady_clock::now();
                    r.stream_size = re.out.size();
                    r.encode_seconds = std::chrono::duration<double>(t1 - t0).count();
                    if (verify) {
                        dec_body->reset_positional(g_warm_match ? &g_warm_pos : nullptr, len);
                        RangeDecoder rd(re.out);
                        for (u64 i = 0; i < len; ++i) {
                            const u8 got = decode_byte_cm(rd, *dec_body);
                            if (got != src[static_cast<size_t>(off + i)]) { r.exact = false; r.first_mismatch = start + i; break; }
                        }
                        auto t2 = std::chrono::steady_clock::now();
                        r.decode_seconds = std::chrono::duration<double>(t2 - t1).count();
                    }
                    if (keep_stream) r.stream.swap(re.out);
                }
            });
        }
        for (auto& th : lanes) th.join();
        for (u64 ci = 1; ci < chunks; ++ci) {
            ChunkResult& r = brs[static_cast<size_t>(ci)];
            total_stream_bytes += r.stream_size;
            encode_sum += r.encode_seconds; decode_sum += r.decode_seconds;
            if (!r.exact && exact) { exact = false; first_mismatch = r.first_mismatch; }
        }
        if (g_timeledger) {
            const u32 L = threads;
            std::vector<double> lane_sum(L, 0.0), lane_max(L, 0.0), lane_min(L, 1e18);
            std::vector<u32> lane_n(L, 0);
            for (u64 ci = 1; ci < chunks; ++ci) {
                const ChunkResult& r = brs[static_cast<size_t>(ci)];
                const u32 t = static_cast<u32>((ci - 1) % L);
                lane_sum[t] += r.encode_seconds; ++lane_n[t];
                if (r.encode_seconds > lane_max[t]) lane_max[t] = r.encode_seconds;
                if (r.encode_seconds < lane_min[t]) lane_min[t] = r.encode_seconds;
            }
            double lmax = 0, lmin = 1e18, lsum = 0;
            for (u32 t = 0; t < L; ++t) { lsum += lane_sum[t];
                if (lane_sum[t] > lmax) lmax = lane_sum[t];
                if (lane_sum[t] < lmin) lmin = lane_sum[t]; }
            printf("\n[time ledger] schedule anatomy (braid, %u lineages):\n", L);
            for (u32 t = 0; t < L; ++t)
                printf("  lineage %u: total %.1fs over %u chunks (chunk min %.1fs / max %.1fs)\n",
                       t, lane_sum[t], lane_n[t], lane_min[t], lane_max[t]);
            printf("  imbalance tax: slowest-fastest lineage = %.1fs (wall waits for slowest)\n", lmax - lmin);
            printf("  perfect-balance wall for this work: %.1fs\n", lsum / L);
            // chunk cost extremes: which content is expensive?
            double cmax=0, cmin=1e18; u64 imax=0, imin=0;
            for (u64 ci = 1; ci < chunks; ++ci) { const double e = brs[(size_t)ci].encode_seconds;
                if (e > cmax) { cmax = e; imax = ci; } if (e < cmin) { cmin = e; imin = ci; } }
            printf("  chunk spread: cheapest #%llu %.1fs, dearest #%llu %.1fs (%.2fx)\n",
                   (unsigned long long)imin, cmin, (unsigned long long)imax, cmax, cmax/(cmin>0?cmin:1));
            printf("  per-chunk costs (fuel for the scheduling mint):\n");
            for (u64 ci = 1; ci < chunks; ++ci)
                printf("    chunk %2llu lane %u: %.2fs\n", (unsigned long long)ci,
                       (unsigned)((ci-1)%L), brs[(size_t)ci].encode_seconds);

        }
        for (u64 ci = 1; ci < chunks; ++ci) {
            ChunkResult& r = brs[static_cast<size_t>(ci)];
            if (keep_stream) kept[static_cast<size_t>(r.index)] = std::move(r);
        }
    } else if (g_interleave > 1 && !stream_input) {
        // grouped lockstep tasks: each task interleaves g_interleave chunks in one thread
        std::vector<ChunkResult> grs(static_cast<size_t>(chunks));
        std::deque<std::future<void>> gactive;
        for (u64 ci = first_ci; ci < chunks; ) {
            std::vector<ChunkResult*> rp; std::vector<u64> st, ln;
            for (u32 k = 0; k < g_interleave && ci < chunks; ++k, ++ci) {
                grs[static_cast<size_t>(ci)].index = ci;
                rp.push_back(&grs[static_cast<size_t>(ci)]);
                st.push_back(ci * chunk_bytes);
                ln.push_back(std::min<u64>(chunk_bytes, raw_size - ci * chunk_bytes));
            }
            gactive.emplace_back(std::async(std::launch::async, [&, rp, st, ln]() {
                encode_chunk_group(input, rp, st, ln, cm_bits, mm_bits, cache_local_layout, verify, keep_stream);
            }));
            if (gactive.size() >= threads) { gactive.front().get(); gactive.pop_front(); }
        }
        while (!gactive.empty()) { gactive.front().get(); gactive.pop_front(); }
        for (u64 ci = first_ci; ci < chunks; ++ci) {
            ChunkResult& r = grs[static_cast<size_t>(ci)];
            total_stream_bytes += r.stream_size;
            encode_sum += r.encode_seconds; decode_sum += r.decode_seconds;
            if (!r.exact && exact) { exact = false; first_mismatch = r.first_mismatch; }
            if (keep_stream) kept[static_cast<size_t>(r.index)] = std::move(r);
        }
    } else {
    for (u64 ci = first_ci; ci < chunks; ++ci) {
        const u64 start = ci * chunk_bytes;
        const u64 len = std::min<u64>(chunk_bytes, raw_size - start);
        if (stream_input)
            active.emplace_back(std::async(std::launch::async, encode_chunk_streamed,
                input_path, ci, start, len, cm_bits, mm_bits, cache_local_layout, verify, keep_stream));
        else
            active.emplace_back(std::async(std::launch::async, encode_chunk,
                std::cref(input), ci, start, len, cm_bits, mm_bits, cache_local_layout, verify, keep_stream));
        collect_one(false);
    }
    while (!active.empty()) collect_one(true);
    }
    }

    const u64 header_bytes = 8 + 8 + 8 + 8 + 8 + 4 + chunks * 16ULL;
    u64 archive_bytes = header_bytes + total_stream_bytes; // mutable: stored fallback overrides
    long long saved = static_cast<long long>(raw_size) - static_cast<long long>(archive_bytes); // recomputed below if stored fallback fires
    auto t1 = std::chrono::steady_clock::now();
    const double wall_s = std::chrono::duration<double>(t1 - t0).count();

    if (keep_stream) {
        std::vector<u8> archive;
        archive.reserve(static_cast<size_t>(std::min<u64>(archive_bytes, 1024ULL*1024ULL*1024ULL)));
        const char magic_file[8] = {'M','D','L','B','3','0','1','A'};
        const char magic_dir[8]  = {'M','D','L','B','3','0','1','F'};
        const char* magic = g_content_folder ? magic_dir : magic_file;
        archive.insert(archive.end(), magic, magic+8);
        put_u64(archive, raw_size);
        // Checksum reads the FILE directly, never the in-memory buffer: with --stream-input 1
        // (used by default so a 1GB file is never fully resident) that buffer is empty, and
        // indexing into it here is a null read — this exact bug crashed on small single-chunk
        // streamed inputs. Re-reading the file is correct regardless of streaming mode.
        u64 fnv = 1469598103934665603ULL;
        {
            std::ifstream cf(input_path, std::ios::binary);
            if (!cf) die("cannot reopen input for checksum: " + input_path);
            std::vector<u8> cbuf(1u << 20);
            while (cf) {
                cf.read(reinterpret_cast<char*>(cbuf.data()), static_cast<std::streamsize>(cbuf.size()));
                const std::streamsize got = cf.gcount();
                for (std::streamsize ci = 0; ci < got; ++ci) { fnv ^= cbuf[static_cast<size_t>(ci)]; fnv *= 1099511628211ULL; }
            }
        }
        put_u64(archive, fnv);
        archive.push_back(static_cast<u8>(cm_bits));
        archive.push_back(static_cast<u8>(mm_bits));
        archive.push_back(static_cast<u8>(g_w2_bits));
        archive.push_back(static_cast<u8>(g_w3_bits));
        archive.push_back(static_cast<u8>(g_twist ? 2u : (cache_local_layout ? 1u : 0u)));
        archive.push_back(static_cast<u8>(g_warm_clamp));
        archive.push_back(static_cast<u8>((g_rightsize?1u:0u) | (g_warm_mode?2u:0u) | (g_warm_match?4u:0u) | (g_unit_alpha?8u:0u) | (g_braid?16u:0u)));
        archive.push_back(static_cast<u8>(threads));   // lineage count: defines the braid weave
        put_u64(archive, chunk_bytes);
        put_u32(archive, static_cast<u32>(chunks));
        for (const auto& r : kept) { put_u64(archive, r.raw_size); put_u64(archive, r.stream_size); }
        for (const auto& r : kept) archive.insert(archive.end(), r.stream.begin(), r.stream.end());
        // STORED FALLBACK: never hand back something bigger than the original. A cold
        // model on a tiny/incompressible input can lose to its own fixed header + the
        // learning curve it hasn't gotten to climb yet -- exactly what a one-line test
        // file hits. Same discipline zip uses: if compression didn't help, store raw.
        const u64 stored_overhead = 8 + 8 + 8; // magic + raw_size + checksum
        if (archive.size() > raw_size + stored_overhead) {
            std::vector<u8> stored;
            stored.reserve(static_cast<size_t>(raw_size + stored_overhead));
            const char smagic_file[8] = {'M','D','L','B','S','T','O','R'};
            const char smagic_dir[8]  = {'M','D','L','B','S','T','O','F'};
            const char* smagic = g_content_folder ? smagic_dir : smagic_file;
            stored.insert(stored.end(), smagic, smagic+8);
            put_u64(stored, raw_size);
            put_u64(stored, fnv);
            { std::ifstream cf(input_path, std::ios::binary);
              if (!cf) die("cannot reopen input for stored fallback: " + input_path);
              std::vector<u8> cbuf(1u << 20);
              while (cf) { cf.read(reinterpret_cast<char*>(cbuf.data()), static_cast<std::streamsize>(cbuf.size()));
                  const std::streamsize got = cf.gcount();
                  stored.insert(stored.end(), cbuf.begin(), cbuf.begin() + got); } }
            write_all(archive_path, stored);
            archive_bytes = stored.size();
            saved = static_cast<long long>(raw_size) - static_cast<long long>(archive_bytes);
            std::cout << "[v234] stored_fallback=true (input too small/incompressible -- copied as-is)\n";
        } else {
            write_all(archive_path, archive);
        }
    }

    std::cout << "[v234] input_bytes=" << raw_size << "\n";
    std::cout << "[v234] archive_bytes=" << archive_bytes << "\n";
    std::cout << "[v234] saved_vs_raw_bytes=" << saved << "\n";
    std::cout << "[v234] exact_replay=" << (verify ? (exact ? "true" : "false") : "not_checked") << "\n";
    resmap_print(total_stream_bytes);
    errledger_print();
    std::cout << "[v234] chunks=" << chunks << "\n";
    std::cout << "[v234] chunk_bytes=" << chunk_bytes << "\n";
    std::cout << "[v234] threads=" << threads << "\n";
    std::cout << "[v234] cm_bits=" << cm_bits << "\n";
    std::cout << "[v234] wall_seconds=" << wall_s << "\n";

    if (!report_path.empty()) {
        std::ofstream rf(report_path, std::ios::binary);
        if (!rf) die("cannot open report: " + report_path);
        rf << "{\n";
        rf << "  \"version\": \"v221\",\n";
        rf << "  \"name\": \"MDLBSG_V234_PAIR_INTERLEAVE\",\n";
        rf << "  \"input_path\": \"" << input_path << "\",\n";
        rf << "  \"input_bytes\": " << raw_size << ",\n";
        rf << "  \"archive_bytes\": " << archive_bytes << ",\n";
        rf << "  \"saved_vs_raw_bytes\": " << saved << ",\n";
        rf << "  \"exact_replay\": " << (verify && exact ? "true" : "false") << ",\n";
        rf << "  \"exact_replay_checked\": " << (verify ? "true" : "false") << ",\n";
        rf << "  \"first_mismatch\": " << first_mismatch << ",\n";
        rf << "  \"native_only\": true,\n";
        rf << "  \"external_compressor_active_path\": false,\n";
        rf << "  \"startup_mining_performed\": false,\n";
        rf << "  \"phrase_bank_used\": false,\n";
        rf << "  \"architecture\": \"bitwise_binary_decomposition_8family_stretch_domain_mixing\",\n";
        rf << "  \"models\": \"order0_direct,order1..6_hashed,word_shape_hash\",\n";
        rf << "  \"cm_bits\": " << cm_bits << ",\n";
        rf << "  \"chunk_bytes\": " << chunk_bytes << ",\n";
        rf << "  \"chunks\": " << chunks << ",\n";
        rf << "  \"threads\": " << threads << ",\n";
        rf << "  \"encode_cpu_seconds_sum\": " << std::setprecision(9) << encode_sum << ",\n";
        rf << "  \"decode_verify_cpu_seconds_sum\": " << std::setprecision(9) << decode_sum << ",\n";
        rf << "  \"wall_seconds\": " << std::setprecision(9) << wall_s << "\n";
        rf << "}\n";
    }

    if (verify && !exact) { std::cerr << "[v234] MISMATCH DETECTED at " << first_mismatch << "\n"; return 2; }
    return 0;
}