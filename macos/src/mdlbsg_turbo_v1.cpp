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

static void die_payload_gone() {
    std::cout << "[v234] ERROR: the compressor's work file disappeared mid-run (another program or a cleanup removed it). Nothing was harmed -- just run the compression again.\n";
    std::exit(3);
}
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

// ---------------- exact integer NEON mixer (aarch64) ----------------
// s64 accumulation of s32*s32 products is order-independent (no saturation, fits s64), and the
// weight update is element-wise — both are exactly reproducible in SIMD. The binary PROVES this
// at startup: neon vs scalar on randomized vectors; any mismatch aborts the run.
static bool g_simd = true;
#if defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
static inline s64 dot10_neon(const s32* w, const int* st) {
    int32x4_t w0 = vld1q_s32(w),      w1 = vld1q_s32(w + 4);
    int32x4_t s0 = vld1q_s32(st),     s1 = vld1q_s32(st + 4);
    int64x2_t acc = vmull_s32(vget_low_s32(w0), vget_low_s32(s0));
    acc = vmlal_s32(acc, vget_high_s32(w0), vget_high_s32(s0));
    acc = vmlal_s32(acc, vget_low_s32(w1),  vget_low_s32(s1));
    acc = vmlal_s32(acc, vget_high_s32(w1), vget_high_s32(s1));
    s64 r = vaddvq_s64(acc);
    r += static_cast<s64>(w[8]) * st[8];
    r += static_cast<s64>(w[9]) * st[9];
    return r;
}
static inline void upd10_neon(s32* w, const int* st, int err) {
    const int32x4_t verr = vdupq_n_s32(err);
    const int32x4_t vmaxv = vdupq_n_s32(1 << 20), vminv = vdupq_n_s32(-(1 << 20));
    for (int k = 0; k < 8; k += 4) {
        int32x4_t sv = vld1q_s32(st + k);
        int32x4_t wv = vld1q_s32(w + k);
        int32x4_t d  = vshrq_n_s32(vmulq_s32(sv, verr), 10);
        int32x4_t nv = vminq_s32(vmaxq_s32(vaddq_s32(wv, d), vminv), vmaxv);
        vst1q_s32(w + k, nv);
    }
    for (int k = 8; k < 10; ++k) {
        s32 n = w[k] + ((st[k] * err) >> 10);
        if (n >  (1<<20)) n =  (1<<20); if (n < -(1<<20)) n = -(1<<20);
        w[k] = n;
    }
}
static void simd_self_proof() {
    if (!g_simd) return;
    u64 x = 0x9E3779B97F4A7C15ULL;
    auto rnd = [&]() { x ^= x<<13; x ^= x>>7; x ^= x<<17; return x; };
    for (int trial = 0; trial < 4096; ++trial) {
        s32 w[10]; s32 w2c[10]; int st[10]; 
        for (int k = 0; k < 10; ++k) {
            w[k] = static_cast<s32>(rnd() % (1u<<21)) - (1<<20); w2c[k] = w[k];
            st[k] = static_cast<int>(rnd() % 4096) - 2048;
        }
        int err = static_cast<int>(rnd() % 8192) - 4096;
        s64 a = 0; for (int k = 0; k < 10; ++k) a += static_cast<s64>(w[k]) * st[k];
        s64 b = dot10_neon(w, st);
        if (a != b) die("SIMD SELF-PROOF FAILED (dot) — refusing to run");
        for (int k = 0; k < 10; ++k) {
            s32 n = w[k] + ((st[k] * err) >> 10);
            if (n >  (1<<20)) n =  (1<<20); if (n < -(1<<20)) n = -(1<<20);
            w[k] = n;
        }
        upd10_neon(w2c, st, err);
        for (int k = 0; k < 10; ++k) if (w[k] != w2c[k]) die("SIMD SELF-PROOF FAILED (upd) — refusing to run");
    }
    std::cout << "[v234] simd self-proof: 4096 randomized trials, neon == scalar exactly\n";
}
#define HAVE_NEON_MIX 1
#elif defined(__AVX2__)
// ---------------- exact integer AVX2 mixer (x86-64) ----------------
// The NEON kernel's twin: identical contract (exact s64 dot, elementwise clamped
// update), identical startup self-proof -- any avx2/scalar mismatch aborts the run.
// Function names are kept so every call site stays untouched; on x86 the "_neon"
// suffix simply means "the SIMD path".
#include <immintrin.h>
static inline s64 dot10_neon(const s32* w, const int* st) {
    __m256i wv = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(w));
    __m256i sv = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(st));
    // widening 32x32->64 multiplies: even lanes directly, odd lanes shifted down.
    // mul_epi32 sign-extends from bit 31 of each 64-bit lane's low half, which is
    // exactly the odd lane's own sign bit after the logical shift -- exact.
    __m256i pe  = _mm256_mul_epi32(wv, sv);
    __m256i po  = _mm256_mul_epi32(_mm256_srli_epi64(wv, 32), _mm256_srli_epi64(sv, 32));
    __m256i acc = _mm256_add_epi64(pe, po);
    __m128i s2  = _mm_add_epi64(_mm256_castsi256_si128(acc), _mm256_extracti128_si256(acc, 1));
    s64 r = static_cast<s64>(_mm_extract_epi64(s2, 0)) + static_cast<s64>(_mm_extract_epi64(s2, 1));
    r += static_cast<s64>(w[8]) * st[8];
    r += static_cast<s64>(w[9]) * st[9];
    return r;
}
static inline void upd10_neon(s32* w, const int* st, int err) {
    const __m256i verr = _mm256_set1_epi32(err);
    const __m256i vmaxv = _mm256_set1_epi32(1 << 20), vminv = _mm256_set1_epi32(-(1 << 20));
    __m256i sv = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(st));
    __m256i wv = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(w));
    __m256i d  = _mm256_srai_epi32(_mm256_mullo_epi32(sv, verr), 10);
    __m256i nv = _mm256_min_epi32(_mm256_max_epi32(_mm256_add_epi32(wv, d), vminv), vmaxv);
    _mm256_storeu_si256(reinterpret_cast<__m256i*>(w), nv);
    for (int k = 8; k < 10; ++k) {
        s32 n = w[k] + ((st[k] * err) >> 10);
        if (n >  (1<<20)) n =  (1<<20); if (n < -(1<<20)) n = -(1<<20);
        w[k] = n;
    }
}
static void simd_self_proof() {
    if (!g_simd) return;
    u64 x = 0x9E3779B97F4A7C15ULL;
    auto rnd = [&]() { x ^= x<<13; x ^= x>>7; x ^= x<<17; return x; };
    for (int trial = 0; trial < 4096; ++trial) {
        s32 w[10]; s32 w2c[10]; int st[10];
        for (int k = 0; k < 10; ++k) {
            w[k] = static_cast<s32>(rnd() % (1u<<21)) - (1<<20); w2c[k] = w[k];
            st[k] = static_cast<int>(rnd() % 4096) - 2048;
        }
        int err = static_cast<int>(rnd() % 8192) - 4096;
        s64 a = 0; for (int k = 0; k < 10; ++k) a += static_cast<s64>(w[k]) * st[k];
        s64 b = dot10_neon(w, st);
        if (a != b) die("SIMD SELF-PROOF FAILED (dot) -- refusing to run");
        for (int k = 0; k < 10; ++k) {
            s32 n = w[k] + ((st[k] * err) >> 10);
            if (n >  (1<<20)) n =  (1<<20); if (n < -(1<<20)) n = -(1<<20);
            w[k] = n;
        }
        upd10_neon(w2c, st, err);
        for (int k = 0; k < 10; ++k) if (w[k] != w2c[k]) die("SIMD SELF-PROOF FAILED (upd) -- refusing to run");
    }
    std::cout << "[v234] simd self-proof: 4096 randomized trials, avx2 == scalar exactly\n";
}
#define HAVE_NEON_MIX 1
#else
static void simd_self_proof() {}
#define HAVE_NEON_MIX 0
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
static std::atomic<unsigned long long> g_progress_written{0};
static unsigned long long g_progress_total = 0;   // total BYTES of input
// Called as bytes are encoded. Writes the file only when the whole percent changes,
// so a 1GB run does ~100 tiny writes, not millions -- and lanes racing each other
// can't thrash it.
static void progress_add(unsigned long long n) {
    if (g_progress_path.empty() || g_progress_total == 0) return;
    const unsigned long long b = g_progress_bytes.fetch_add(n) + n;
    // Write every 4MB of progress (and at completion), NOT every whole percent.
    // Percent-gated writes freeze the UI on big inputs: 1% of 4GB is 40MB, so the
    // progress file didn't even EXIST until 40MB in -- a window that looks dead
    // is a window people force-quit. Byte-gated writes keep motion visible at any
    // input size for the cost of one tiny fopen per 4MB.
    unsigned long long lastw = g_progress_written.load();
    if (b < lastw + (4ull << 20) && b < g_progress_total) return;
    if (!g_progress_written.compare_exchange_strong(lastw, b)) return;  // another thread has it
    FILE* f = std::fopen(g_progress_path.c_str(), "w");
    if (f) { std::fprintf(f, "%llu %llu\n", b, g_progress_total); std::fclose(f); }
}
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
// slot-3 organ selector: true = indirect family (what followed this bigram
// historically, used AS the boundary -- cmix's indirect-hash, transplanted into
// the slot the ablation study proved weakest). Travels in the archive header so
// old archives decode with the legacy order-4 family.
static int g_slot3 = -1;  // -1=adaptive per chunk (default), 0=ord4, 2=sparse{b1,b3}, 3=sparse{b2,b4}
static int g_chunk0_mode = -2;                 // chunk-0's chosen mode, consulted at body construction
static std::vector<u8> g_slot3_map;            // per-chunk boundary decisions (encoder + decoder)

// Score the three boundary candidates on sampled windows: tiny last-byte tables,
// hits = how often "same boundary, same next byte" held. ~2ms per 16MB chunk
// against a multi-second encode -- the router picks the boundary type per chunk
// the same way it already picks store-versus-engine, and the decision rides the
// archive as 2 bits so the decoder never has to re-derive anything.
static int pick_slot3(const u8* p, u64 len) {
    if (g_slot3 >= 0) return g_slot3;                       // static override
    if (len < 65536) return 0;
    // Decision rule grounded in measurement, not proxy: the full-system A/B showed
    // sparse{b2,b4} wins on structured-punctuation data (json/csv-class, +2.2KB per
    // 8MB) and loses on code; byte-hit proxies could not see this because sp24's
    // value is mixer CALIBRATION, not unique byte hits -- the oracle experiment
    // proved the switching machinery delivers exactly the predicted bytes when the
    // decision is right. So the router detects the data class directly.
    u64 punct = 0; const u64 SW = std::min<u64>(len, 65536);
    for (u64 i = 0; i < SW; ++i) {
        const u8 c = p[i];
        punct += (c=='"' || c=='{' || c=='}' || c==':' || c==',' || c=='[' || c==']');
    }
    return (punct * 10 > SW) ? 3 : 0;
}

struct BitCMBody {
    static constexpr u32 kNumModels = 10;     // order0, order1..6, word, case-structure, match
    static constexpr u32 kMixCtx = 4096;      // (quiet bucket 0..3) x (match bucket) x (node)
    u32 cm_bits;                              // log2 size of each hashed model table
    u32 cm_mask;
    u32 fam_mask[8];                          // per-family index mask (rightsize: o1/o2 direct)
    u32 mm_bits;                              // log2 size of match-position table
    u32 mm_mask;

    // Per-model adaptive bit probabilities (12-bit, init 2048 = "no opinion").
    std::array<u16,256> t_order0;             // direct partial-byte table
    std::vector<u16> t_hash[8];               // order1..6, word, case-structure

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
    // fast-match agree-bit states, bucketed by capped run length. [count|prob] like
    // every other cell. Lane-persistent (not reset per chunk) on BOTH sides -- the
    // decoder's lanes walk the identical sequence, so persistence stays symmetric.
    u16 t_agree[64];

    // causal byte history + word-shape hash
    u8 b1=0,b2=0,b3=0,b4=0,b5=0,b6=0;
    u32 word_hash = 0;
    std::vector<u16> ind_tab;                 // bigram -> last two bytes that followed it
    int slot3_mode = 0;                       // this chunk's slot-3 boundary: 0=ord4 2=sparse13 3=sparse24
    int slot3_table_mode = -1;                // -1 = fresh table, compatible with any mode
    void set_slot3(int m) {
        // swapping the boundary invalidates the table's learned rules -- clear it,
        // exactly like reset_positional clears positional state at a chunk boundary.
        // Only pays the memset when the variant actually CHANGES between chunks.
        slot3_mode = m;
        if (slot3_table_mode != -1 && m != slot3_table_mode)
            std::fill(t_hash[3].begin(), t_hash[3].end(), static_cast<u16>(2048));
        slot3_table_mode = m;
    }
    u8 caps_run = 0;      // consecutive capitals just seen
    u8 sent_end = 0;      // last non-space byte was . ! ?
    u8 cur_word_caps = 0; // current word began with a capital
    u8 prev_word_caps = 0;// previous word began with a capital (proper nouns travel in packs)

    // per-byte cached model base indices (recomputed once per byte)
    std::array<u32,8> hbase{};
    // TWIST layout: store cell idx at physical slot (idx * KINV) & mask, where KINV is the
    // modular inverse of the ctx stride 0x57F4A9 mod 2^32. Then slot(hbase + ctx*K) =
    // hbase*KINV + ctx: one byte-context's 255 bit-tree nodes become PHYSICALLY CONTIGUOUS.
    // A bijective relabeling preserves every collision and every cell value -> the archive is
    // bit-identical to scatter. Only the memory geometry changes: ~4 lines per family per byte
    // instead of ~8 scattered lines, all prefetchable at byte start.
    static constexpr u32 kCtxStrideInv = 0xABFDEF99u; // (0x57F4A9)^-1 mod 2^32
    bool twist = false;
    std::array<u32,8> hb2{};

    explicit BitCMBody(u32 bits, u32 mmbits, u64 reserve_hint)
        : cm_bits(bits), cm_mask((1u<<bits)-1u), mm_bits(mmbits), mm_mask((1u<<mmbits)-1u) {
        for (int q = 0; q < 64; ++q) t_agree[q] = 2048;
        if (g_chunk0_mode >= 0) slot3_mode = g_chunk0_mode;
        else if (g_slot3 >= 0) slot3_mode = g_slot3;
        t_order0.fill(2048);
        for (int m = 0; m < 8; ++m) {
            u32 fb = cm_bits;
            if (g_rightsize) { if (m == 0) fb = 16; else if (m == 1) fb = 24; }
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
    bool byte_wrong = false;
    u32 rowB = 0, rowC = 0, row2 = 0;
    int dA = 0, dB = 0, dC = 0;

    void apm_init() {
        apm_t.resize(2048u * 33u);
        for (u32 c = 0; c < 2048u; ++c)
            for (int i = 0; i < 33; ++i)
                apm_t[c*33u + static_cast<u32>(i)] = static_cast<u16>(squash((i - 16) * 128));
        apm2_t.resize(1024u * 33u);
        for (u32 c = 0; c < 1024u; ++c)
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

    void arm_match() {
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
    void new_byte_hashes() { compute_family_hashes(); arm_match(); }
    void compute_family_hashes() {
        // one 32-bit hash per context order, computed once per byte
        u32 h1 = mix32(0x1000193u ^ b1*0x9e3779b9u);
        u32 h2 = mix32(h1 ^ b2*0x85ebca6bu);
        u32 h3 = mix32(h2 ^ b3*0xc2b2ae35u);
        // h4 stays in the chain so orders 5-6 keep PURE suffix boundaries; only the
        // PUBLISHED slot-3 hash swaps to the indirect organ when active.
        u32 h4 = mix32(h3 ^ b4*0x27d4eb2du);
        u32 h4pub = h4;
        if (slot3_mode == 2)      h4pub = mix32(0x5EA5C0DEu ^ b1*0x9e3779b9u ^ b3*0x27d4eb2du);   // gap: skip b2
        else if (slot3_mode == 3) h4pub = mix32(0x0DDBA115u ^ b2*0x85ebca6bu ^ b4*0x165667b1u);   // gap: skip b1
        u32 h5 = mix32(h4 ^ b5*0x165667b1u);
        u32 h6 = mix32(h5 ^ b6*0x2545f491u);
        u32 hw = mix32(word_hash * 0x9e3779b1u + 0x1234567u);
        // case-structure family: the microscope says UPPER bytes bleed 2.65x average bits.
        // Capitals follow sentence ends, start [[wiki links]], run in acronyms — all causal.
        const u32 linkf = (b2 == '[' && b1 == '[') ? 1u : 0u;
        u32 hc = mix32(0xCAFEBABEu ^ b1 * 0x9e3779b9u ^ word_hash * 0x85ebca6bu
                       ^ (static_cast<u32>(caps_run) * 0xc2b2ae35u)
                       ^ (static_cast<u32>(sent_end) << 30) ^ (linkf << 29)
                       ^ (static_cast<u32>(prev_word_caps) << 28));
        hbase[0]=h1; hbase[1]=h2; hbase[2]=h3; hbase[3]=h4pub; hbase[4]=h5; hbase[5]=h6; hbase[6]=hw; hbase[7]=hc;
        // latency hiding: every table line this byte will touch is knowable right now.
        // Issue the prefetches, then do bit 7's arithmetic while the lines are in flight.
        if (twist) {
            for (u32 m = 0; m < 8u; ++m) {
                if (g_rightsize && m == 0)      hb2[m] = static_cast<u32>(b1) << 8;               // direct
                else if (g_rightsize && m == 1) hb2[m] = (static_cast<u32>(b1) << 16) | (static_cast<u32>(b2) << 8); // direct
                else                            hb2[m] = hbase[m] * kCtxStrideInv;
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
    }

    // BATCH: encoder knows the byte, and within one byte all 9 table cells per bit are
    // provably disjoint from every other bit's cells (tree levels are disjoint ctx ranges;
    // ctx->slot is injective per byte in all three layouts). Therefore hoisting ALL reads to
    // byte start is semantically identical to interleaved read/write — bit-exact by proof,
    // and the loads issue back-to-back instead of load-use stalling per bit.
    u32 pre_idx[8][9];
    int pre_st[8][9];
    void preload_byte(u8 actual) {
        u32 c = 1;
        for (int i = 7; i >= 0; --i) {
            const int k = 7 - i;
            pre_idx[k][0] = c & 255u;
            pre_st[k][0] = stretch(t_order0[pre_idx[k][0]] & 4095u);
            for (u32 m = 0; m < 8; ++m) {
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
            for (u32 sslot = 0; sslot < 9u; ++sslot) { idx[sslot] = pi[sslot]; st[sslot] = ps[sslot]; }
        } else {
        // gather the 8 family votes, stretch them
        idx[0] = ctx & 255u;
        st[0] = stretch(t_order0[idx[0]] & 4095u);
        for (u32 m = 0; m < 8; ++m) {
            // Two layouts, runtime-selectable:
            //  scatter: full-hash slot per (context, bit-node) — max discrimination, max ratio.
            //  block:   one 256-slot block per (model, byte-context), bit-node picks the slot
            //           inside — 7 cache regions per byte instead of ~56 scattered lines,
            //           ~1.9x faster at large cm_bits for ~1% ratio.
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
            st[9] = e ? s : -s;
        } else {
            st[9] = 0;
        }
        idx[9] = 0; // match model has no table cell to update
        // mix in stretch domain with per-node weights
        const u32 mb = match_valid_byte ? (match_len >= 32 ? 3u : (match_len >= 8 ? 2u : 1u)) : 0u;
        const u32 qb = quiet_bucket() >> 1;   // 0..3 coarse quiet regime
        last_mixrow = ((qb << 10) | (mb << 8) | (ctx & 255u)) * kNumModels;
        rowB = static_cast<u32>(b1) * kNumModels;
        rowC = (cls(b1) * 10u + cls(b2)) * kNumModels;
        row2 = (ctx & 255u) * 3u;
        s64 dotA = 0, dotB = 0, dotC = 0;
#if HAVE_NEON_MIX
        if (g_simd) {
            dotA = dot10_neon(&w[last_mixrow], st);
            dotB = dot10_neon(&wB[rowB], st);
            dotC = dot10_neon(&wC[rowC], st);
        } else
#endif
        {
            const s32* wa = &w[last_mixrow];
            const s32* wb = &wB[rowB];
            const s32* wc = &wC[rowC];
            for (u32 m = 0; m < kNumModels; ++m) {
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
        const int pa = apm_pp(p, (quiet_bucket() << 8) | b1);
        int p1 = (3*p + pa) >> 2;
        const int pa2 = apm2_pp(p1, (static_cast<u32>(b1)*31u + static_cast<u32>(b2)) & 1023u);
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
        for (u32 m = 0; m < 8; ++m) upd_state(t_hash[m][idx[m+1]], target);
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
            upd10_neon(wa, st, errA);
            upd10_neon(wb, st, errB);
            upd10_neon(wc, st, errC);
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
        if (b == '.' || b == '!' || b == '?') sent_end = 1;
        else if (b != ' ' && b != '\n' && b != '\r' && b != '\t') sent_end = 0;
        if (byte_wrong) quiet_run = 0; else if (quiet_run < 65535u) ++quiet_run;
        b6=b5; b5=b4; b4=b3; b3=b2; b2=b1; b1=b;
    }
};

// ---------------- byte encode/decode over the bit model ----------------
static bool g_batch = false;
// ---- match-run fast path (LZP-over-CM) ----------------------------------------
// When the match model has been right for >= g_fastmatch consecutive bytes, stop
// paying ~4000 cycles of full context mixing per byte it already predicts: encode
// ONE adaptive "did the run hold?" bit and move on. The decision reads only state
// both sides share (match_len, armed byte), so the router can never desynchronize;
// on a miss we pay one extra bit and fall back to the full engine for that byte.
// The threshold travels in the archive header -- archives are self-describing.
static u32 g_fastmatch = 512;
// ================= FORMAT V2: GLOBAL CONTENT-DEFINED DEDUP =====================
// The ledger proved it on real data: most of the compressible value in file
// collections is DUPLICATION, and per-bit context mixing is the wrong instrument
// for harvesting duplication -- it pays modeling price on every byte of every
// copy it can reach, and reaches almost none of them across chunk boundaries.
// So collapse duplicates FIRST, globally, at LZ-class speed: content-defined
// blocks (anchors chosen by the bytes, so copies align at any offset), candidate
// match by fingerprint, then ALWAYS byte-verified -- a hash is a hint, never a
// proof. The engine then models only the unique residue. v2 is a transform
// wrapped around the v1 archive: same engine, same router, same fastmatch,
// two independent integrity checks (inner v1 fnv on the payload, outer fnv on
// the reconstructed original).
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <unordered_map>

static inline u64 fp_mix(u64 x);   // defined with the routing probes below
static bool g_dedup = true;
// Work files live in the SYSTEM temp dir: unique names (mkstemp), invisible to
// the user, always writable. The first draft parked a multi-hundred-MB
// ".payload.tmp" in Downloads next to the archive -- one innocent folder
// cleanup mid-run killed the encode. A tool must never leave its organs where
// the user can tidy them away.
static std::string v2_temp_path(const char* tag) {
    const char* td = std::getenv("TMPDIR"); std::string d = (td && *td) ? td : "/tmp";
    if (!d.empty() && d.back() != '/') d += '/';
    std::string tmpl = d + "mdlbsg_" + tag + "_XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end()); buf.push_back('\0');
    int fd = ::mkstemp(buf.data());
    if (fd < 0) return tmpl.substr(0, tmpl.size() - 7);   // fallback: predictable name
    ::close(fd);
    return std::string(buf.data());
}
static const char V2MAGIC[8] = {'M','D','L','B','S','G','v','2'};

static u64 gear_tab_v2[256];
static void v2_init_gear() {
    u64 x = 0x9E3779B97F4A7C15ULL;
    for (int i = 0; i < 256; ++i) { x ^= x >> 12; x ^= x << 25; x ^= x >> 27; gear_tab_v2[i] = x * 0x2545F4914F6CDD1DULL; }
}
static inline u64 v2_fnv(const u8* p, u64 n, u64 h = 1469598103934665603ULL) {
    for (u64 i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}
static void v2_varint(std::vector<u8>& v, u64 x) {
    while (x >= 128) { v.push_back(static_cast<u8>(x) | 128u); x >>= 7; }
    v.push_back(static_cast<u8>(x));
}
static u64 v2_readvar(const u8* p, u64& o) {
    u64 x = 0; int s = 0; u8 b;
    do { b = p[o++]; x |= (u64)(b & 127u) << s; s += 7; } while (b & 128u);
    return x;
}

struct V2Stats { u64 blocks=0, dup_blocks=0, dup_bytes=0, residue_bytes=0, recipe_bytes=0; };

// dedup input -> payload file: [u64 recipe_len][recipe][residue]
static V2Stats v2_dedup_encode(const std::string& in_path, const std::string& payload_path, u64& orig_size, u64& orig_fnv) {
    v2_init_gear();
    V2Stats st;
    int fd = ::open(in_path.c_str(), O_RDONLY);
    if (fd < 0) die("v2: cannot open input");
    struct stat sb; ::fstat(fd, &sb);
    const u64 N = static_cast<u64>(sb.st_size);
    orig_size = N;
    const u8* p = static_cast<const u8*>(::mmap(nullptr, N ? N : 1, PROT_READ, MAP_PRIVATE, fd, 0));
    if (p == MAP_FAILED) die("v2: mmap input failed");
    orig_fnv = v2_fnv(p, N);

    const u64 MINB = 1024, MAXB = 65536, MASK = 0xFFFu;  // ~4KB average blocks
    std::unordered_map<u64, std::pair<u64,u64>> table;    // fp -> (offset, len) of first sight
    table.reserve(N / 3072 + 64);
    std::vector<u8> recipe; recipe.reserve(1u<<20);
    FILE* rf = std::fopen(payload_path.c_str(), "wb");
    if (!rf) die("v2: cannot open payload");
    u64 placeholder = 0; std::fwrite(&placeholder, 8, 1, rf);  // recipe_len patched later

    u64 pos = 0, lit_start = 0;
    auto flush_lit = [&](u64 upto){
        if (upto > lit_start) {
            v2_varint(recipe, ((upto - lit_start) << 1) | 0u);   // tag 0: literal
            std::fwrite(p + lit_start, 1, upto - lit_start, rf);
            st.residue_bytes += upto - lit_start;
        }
    };
    while (pos < N) {
        // find next content-defined boundary from pos
        u64 h = 0, i = pos, blk_end = std::min(N, pos + MAXB);
        u64 boundary = blk_end;
        for (; i < blk_end; ++i) {
            h = (h << 1) + gear_tab_v2[p[i]];
            if (i - pos + 1 >= MINB && (h & MASK) == 0u) { boundary = i + 1; break; }
        }
        const u64 blen = boundary - pos;
        const u64 fp = fp_mix(v2_fnv(p + pos, blen) ^ blen);
        ++st.blocks;
        auto it = table.find(fp);
        bool matched = false;
        if (it != table.end()) {
            const u64 soff = it->second.first, slen = it->second.second;
            if (slen == blen && std::memcmp(p + soff, p + pos, blen) == 0) {   // hash is a hint; bytes are the proof
                u64 ext = 0;                                                    // extend forward past the block
                while (pos + blen + ext < N && soff + blen + ext < pos && p[soff + blen + ext] == p[pos + blen + ext]) ++ext;
                flush_lit(pos);
                v2_varint(recipe, ((blen + ext) << 1) | 1u);                    // tag 1: copy
                v2_varint(recipe, soff);
                ++st.dup_blocks; st.dup_bytes += blen + ext;
                pos += blen + ext; lit_start = pos;
                matched = true;
            }
        }
        if (!matched) {
            table.emplace(fp, std::make_pair(pos, blen));
            pos += blen;                                                        // stays literal
        }
    }
    flush_lit(N);
    // append recipe AFTER residue? No: layout is [len][recipe][residue] -- rewrite via temp assembly
    std::fclose(rf);
    // assemble final payload: recipe first (so decode can parse ops before residue)
    {
        std::string tmp2 = payload_path + ".fin";
        FILE* out = std::fopen(tmp2.c_str(), "wb");
        u64 rl = recipe.size();
        std::fwrite(&rl, 8, 1, out);
        if (rl) std::fwrite(recipe.data(), 1, rl, out);
        FILE* res = std::fopen(payload_path.c_str(), "rb");
        std::fseek(res, 8, SEEK_SET);
        std::vector<u8> buf(1u<<20);
        size_t got;
        while ((got = std::fread(buf.data(), 1, buf.size(), res)) > 0) std::fwrite(buf.data(), 1, got, out);
        std::fclose(res); std::fclose(out);
        std::remove(payload_path.c_str());
        std::rename(tmp2.c_str(), payload_path.c_str());
    }
    st.recipe_bytes = recipe.size();
    ::munmap(const_cast<u8*>(p), N ? N : 1); ::close(fd);
    return st;
}

// payload file -> reconstructed original at out_path (mmap-backed, RAM-safe)
static void v2_reconstruct(const std::string& payload_path, const std::string& out_path, u64 orig_size, u64 want_fnv) {
    int pf = ::open(payload_path.c_str(), O_RDONLY);
    if (pf < 0) die("v2: cannot open payload for reconstruct");
    struct stat sb; ::fstat(pf, &sb);
    const u64 PN = static_cast<u64>(sb.st_size);
    const u8* pay = static_cast<const u8*>(::mmap(nullptr, PN ? PN : 1, PROT_READ, MAP_PRIVATE, pf, 0));
    if (pay == MAP_FAILED) die("v2: mmap payload failed");
    u64 rl; std::memcpy(&rl, pay, 8);
    const u8* recipe = pay + 8;
    const u8* residue = pay + 8 + rl;

    int of = ::open(out_path.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (of < 0) die("v2: cannot create output");
    if (::ftruncate(of, static_cast<off_t>(orig_size)) != 0) die("v2: cannot size output");
    u8* out = orig_size ? static_cast<u8*>(::mmap(nullptr, orig_size, PROT_READ | PROT_WRITE, MAP_SHARED, of, 0)) : nullptr;
    if (orig_size && out == MAP_FAILED) die("v2: mmap output failed");

    u64 ro = 0, w = 0, rcur = 0;
    while (ro < rl) {
        const u64 op = v2_readvar(recipe, ro);
        const u64 len = op >> 1;
        if ((op & 1u) == 0u) { std::memcpy(out + w, residue + rcur, len); rcur += len; w += len; }
        else {
            const u64 s = v2_readvar(recipe, ro);
            std::memcpy(out + w, out + s, len);          // sources never overlap the copy (enforced at encode)
            w += len;
        }
    }
    if (w != orig_size) die("v2: reconstruct size mismatch");
    const u64 fnv = v2_fnv(out, orig_size);
    if (fnv != want_fnv) die("v2: OUTER INTEGRITY FAILURE after reconstruct");
    if (orig_size) ::munmap(out, orig_size);
    ::close(of); ::munmap(const_cast<u8*>(pay), PN ? PN : 1); ::close(pf);
}

static void encode_byte_cm(RangeEncoder& enc, BitCMBody& body, u8 actual) {
    body.arm_match();
    if (g_fastmatch && body.match_valid_byte && body.match_len >= g_fastmatch) {
        const int agree = (actual == body.match_byte) ? 1 : 0;
        const u32 bkt = body.match_len > 255u ? 63u : (body.match_len >> 2);
        u16& s = body.t_agree[bkt];
        u32 p = s & 4095u; if (p < 1u) p = 1u; if (p > 4095u) p = 4095u;
        enc.encode_bit_p(p, agree);
        BitCMBody::upd_state(s, agree << 12);
        if (agree) { body.absorb(actual); return; }
        // miss: one bit spent, now let the full engine carry this byte
    }
    body.compute_family_hashes();
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
        if (g_resmap) {
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
    body.absorb(actual);
}

static u8 decode_byte_cm(RangeDecoder& dec, BitCMBody& body) {
    body.arm_match();
    if (g_fastmatch && body.match_valid_byte && body.match_len >= g_fastmatch) {
        const u32 bkt = body.match_len > 255u ? 63u : (body.match_len >> 2);
        u16& s = body.t_agree[bkt];
        u32 p = s & 4095u; if (p < 1u) p = 1u; if (p > 4095u) p = 4095u;
        const int agree = dec.decode_bit_p(p);
        BitCMBody::upd_state(s, agree << 12);
        if (agree) { const u8 b = body.match_byte; body.absorb(b); return b; }
    }
    body.compute_family_hashes();
    u32 ctx = 1;
    u32 idx[BitCMBody::kNumModels];
    int st[BitCMBody::kNumModels];
    for (int i = 7; i >= 0; --i) {
        u32 p = body.predict(ctx, idx, st);
        int bit = dec.decode_bit_p(p);
        body.update(ctx, idx, st, p, bit);
        ctx = (ctx << 1) | static_cast<u32>(bit);
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
    std::vector<u16> t_hash[8];
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
    for (int m = 0; m < 8; ++m) s.t_hash[m] = b.t_hash[m];
    if (cl < 15u) {
        for (auto& v : s.t_order0) v = clamp_cnt(v, cl);
        for (int m = 0; m < 8; ++m) for (auto& v : s.t_hash[m]) v = clamp_cnt(v, cl);
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
    for (int m = 0; m < 8; ++m) b.t_hash[m] = s.t_hash[m];
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
        for (int m = 0; m < 8; ++m)
            for (auto& v : t_hash[m]) v = clamp_cnt(v, g_warm_clamp);
    }
    match_ptr = 0; match_len = 0; match_byte = 0; match_valid_byte = false;
    cur_bit = 7;
    b1=b2=b3=b4=b5=b6=0;
    word_hash = 0; caps_run = 0; sent_end = 0; cur_word_caps = 0; prev_word_caps = 0;
    quiet_run = 0; byte_wrong = false;
}

static WarmSnapshot g_warm;
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
    u8 b1=0,b2=0,b3=0,b4=0,b5=0,b6=0;
    u32 word_hash=0; u8 caps_run=0, sent_end=0, cur_word_caps=0, prev_word_caps=0;
    u64 last8=0; u64 nbytes=0;
    void init_from(const BitCMBody& b) {
        b1=b.b1;b2=b.b2;b3=b.b3;b4=b.b4;b5=b.b5;b6=b.b6;
        word_hash=b.word_hash; caps_run=b.caps_run; sent_end=b.sent_end;
        cur_word_caps=b.cur_word_caps; prev_word_caps=b.prev_word_caps;
        last8=b.last8; nbytes=b.hist.size();
    }
    // prefetch every line byte `v` will touch, given shadow context == body context before v
    inline void prefetch_byte(const BitCMBody& body, u8 v) const {
        u32 hb[8];
        u32 h1 = mix32(0x1000193u ^ b1*0x9e3779b9u);
        u32 h2 = mix32(h1 ^ b2*0x85ebca6bu);
        u32 h3 = mix32(h2 ^ b3*0xc2b2ae35u);
        // h4 stays in the chain so orders 5-6 keep PURE suffix boundaries; only the
        // PUBLISHED slot-3 hash swaps to the indirect organ when active.
        u32 h4 = mix32(h3 ^ b4*0x27d4eb2du);
        u32 h4pub = h4;
        if (body.slot3_mode == 2)      h4pub = mix32(0x5EA5C0DEu ^ b1*0x9e3779b9u ^ b3*0x27d4eb2du);
        else if (body.slot3_mode == 3) h4pub = mix32(0x0DDBA115u ^ b2*0x85ebca6bu ^ b4*0x165667b1u);
        u32 h5 = mix32(h4 ^ b5*0x165667b1u);
        u32 h6 = mix32(h5 ^ b6*0x2545f491u);
        u32 hw = mix32(word_hash * 0x9e3779b1u + 0x1234567u);
        const u32 linkf = (b2=='[' && b1=='[') ? 1u : 0u;
        u32 hc = mix32(0xCAFEBABEu ^ b1*0x9e3779b9u ^ word_hash*0x85ebca6bu
                       ^ (static_cast<u32>(caps_run)*0xc2b2ae35u)
                       ^ (static_cast<u32>(sent_end)<<30) ^ (linkf<<29)
                       ^ (static_cast<u32>(prev_word_caps)<<28));
        hb[0]=h1;hb[1]=h2;hb[2]=h3;hb[3]=h4;hb[4]=h5;hb[5]=h6;hb[6]=hw;hb[7]=hc;
        if (body.twist) {
            for (u32 m=0;m<8;++m) {
                u32 base2;
                if (g_rightsize && m == 0)      base2 = static_cast<u32>(b1) << 8;
                else if (g_rightsize && m == 1) base2 = (static_cast<u32>(b1) << 16) | (static_cast<u32>(b2) << 8);
                else                            base2 = hb[m] * BitCMBody::kCtxStrideInv;
                const u32 fm = body.fam_mask[m];
                const u32 base = base2 & fm;
                __builtin_prefetch(&body.t_hash[m][base], 1, 1);
                __builtin_prefetch(&body.t_hash[m][(base + 128u) & fm], 1, 1);
            }
            return;
        }
        if (body.cache_local) {
            for (u32 m=0;m<8;++m) {
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
                for (u32 m=0;m<8;++m) {
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
        if (BitCMBody::is_letter(v)) word_hash = word_hash*0x101u + (v|0x20u);
        else word_hash = 0;
        if (BitCMBody::is_letter(v) && !BitCMBody::is_letter(b1)) cur_word_caps = (v>='A'&&v<='Z')?1u:0u;
        if (!BitCMBody::is_letter(v) && BitCMBody::is_letter(b1)) prev_word_caps = cur_word_caps;
        if (v>='A'&&v<='Z') { if (caps_run<15u) ++caps_run; } else caps_run = 0;
        if (v=='.'||v=='!'||v=='?') sent_end = 1;
        else if (v!=' '&&v!='\n'&&v!='\r'&&v!='\t') sent_end = 0;
        b6=b5;b5=b4;b4=b3;b3=b2;b2=b1;b1=v;
    }
};

// ---------------- chunk framework (kept from v217E; set --chunk-bytes >= file size for one sequential body) ----------------
struct ChunkResult {
    u64 index = 0;
    u64 start = 0;
    u64 raw_size = 0;
    u64 stream_size = 0;
    bool exact = true;
    bool stored = false;   // incompressible chunk copied raw; the model never saw it
    u64 first_mismatch = 0;
    double encode_seconds = 0.0;
    double decode_seconds = 0.0;
    std::vector<u8> stream;
};

// ---- incompressibility probe -------------------------------------------------
// Already-compressed data (PNG/JPEG/zip/mp4) is entropy-coded: ~8.0 bits/byte with
// no structure left to model. Running the CM engine over it costs full modeling
// effort per bit and wins nothing -- the 17-minutes-on-a-PNG-folder failure mode.
// Sample a few 64KB windows; if even the MOST structured window is near-random,
// store the chunk raw. Min-across-windows is deliberately conservative: one
// modelable window anywhere and the whole chunk goes to the engine, so mixed
// chunks can never lose ratio to this shortcut. Text ~4.5 b/B, base64 6.0, DNA
// 2.0 -- all far below the 7.35 line; only genuinely sealed data crosses it.
static bool chunk_looks_incompressible(const u8* p, u64 len) {
    if (len < 65536) return false;                  // too small to be worth routing
    const u64 W = 65536;
    const int NS = (len >= 4*W) ? 4 : 1;
    double most_structured = 8.0;
    for (int s = 0; s < NS; ++s) {
        const u64 off = (NS == 1) ? 0 : ((len - W) * static_cast<u64>(s)) / static_cast<u64>(NS - 1);
        u32 hist[256] = {0};
        for (u64 i = 0; i < W; ++i) ++hist[p[off + i]];
        double H = 0.0;
        for (int b = 0; b < 256; ++b) if (hist[b]) {
            const double q = static_cast<double>(hist[b]) / static_cast<double>(W);
            H -= q * std::log2(q);
        }
        if (H < most_structured) most_structured = H;
    }
    return most_structured > 7.35;
}

// ---- duplicate-structure check ----------------------------------------------
// Order-0 entropy is blind to LONG-RANGE structure: two identical PNGs measure
// ~8.0 bits/byte each, yet the second is one giant match. A 42k-file game
// project is full of duplicate sprites; storing them raw handed back ~200MB on
// real data. So a chunk that LOOKS sealed must also prove it isn't duplicated:
// content-defined anchors (chosen by content, so copies align at any offset)
// are fingerprinted and tested against a global bloom of everything seen so
// far, plus a local set for within-chunk repeats. Only genuinely unique sealed
// data gets stored raw. Routing choices can never corrupt output -- the stored
// bitmap makes any decision decode exactly -- so this trades only speed/ratio.
// REACH DISCIPLINE. The first dedup probe used a GLOBAL bloom -- it detected
// duplicates anywhere in the file, but a lane's match model can only exploit
// duplicates inside its own chunk plus the chunk-0 warm history. Chunks whose
// only duplicates lay gigabytes away were sent to the engine, which burned full
// CM effort on matches it could not reach and gained nothing over storing.
// Detection must never exceed exploitation: count within-chunk repeats and
// chunk-0 hits ONLY. Side benefit: the chunk-0 anchor set is built before the
// lanes launch, so routing decisions are deterministic run to run.
static std::atomic<u32> g_c0_bloom[1u << 16];   // 256KB, 2^21 bits: chunk-0 anchors only
static bool g_c0_bloom_live = false;            // false until chunk 0's anchors are in
static inline u64 fp_mix(u64 x) {
    x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL; x ^= x >> 33; return x;
}
static inline u64 anchor_fp(const u8* p) {                 // FNV-1a over the 64B window
    u64 h = 1469598103934665603ULL;
    for (u64 k = 0; k < 64; ++k) { h ^= p[k]; h *= 1099511628211ULL; }
    return h;
}
static inline bool c0_bloom_test(u32 hh) {
    const u32 b1 = hh & 0x1FFFFFu, b2 = (hh >> 5) & 0x1FFFFFu;
    return (g_c0_bloom[b1 >> 5].load(std::memory_order_relaxed) >> (b1 & 31u) & 1u)
        && (g_c0_bloom[b2 >> 5].load(std::memory_order_relaxed) >> (b2 & 31u) & 1u);
}
static void c0_bloom_add(const u8* p, u64 len) {           // harvest chunk-0 anchors
    for (u64 i = 0; i + 8 + 64 <= len; ++i) {
        u64 v; std::memcpy(&v, p + i, 8);
        if ((fp_mix(v) & 0xFFFu) != 0) continue;
        const u32 hh = static_cast<u32>(fp_mix(anchor_fp(p + i)));
        const u32 b1 = hh & 0x1FFFFFu, b2 = (hh >> 5) & 0x1FFFFFu;
        g_c0_bloom[b1 >> 5].fetch_or(1u << (b1 & 31u), std::memory_order_relaxed);
        g_c0_bloom[b2 >> 5].fetch_or(1u << (b2 & 31u), std::memory_order_relaxed);
        i += 512;
    }
    g_c0_bloom_live = true;
}
static bool chunk_has_duplicate_structure(const u8* p, u64 len) {
    if (len < 4096) return false;
    u64 anchors = 0, dup_hits = 0;
    std::vector<u32> local; local.reserve(8192);
    for (u64 i = 0; i + 8 + 64 <= len; ++i) {
        u64 v; std::memcpy(&v, p + i, 8);
        if ((fp_mix(v) & 0xFFFu) != 0) continue;          // content-defined: ~1 anchor / 4KB
        const u32 hh = static_cast<u32>(fp_mix(anchor_fp(p + i)));
        ++anchors;
        bool dup = false;
        for (u32 q : local) if (q == hh) { dup = true; break; }        // reachable: same chunk
        if (!dup && g_c0_bloom_live && c0_bloom_test(hh)) dup = true;  // reachable: warm chunk 0
        if (dup) ++dup_hits;
        if (local.size() < 8192) local.push_back(hh);
        i += 512;                                          // don't re-anchor inside the window
    }
    if (anchors < 8) return false;                         // too few samples to judge
    return (dup_hits * 25) >= anchors;                     // >=4% REACHABLE duplication
}

static bool chunk_should_store(const u8* p, u64 len) {
    return chunk_looks_incompressible(p, len) && !chunk_has_duplicate_structure(p, len);
}

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
// The twist-path row addresses depend only on context BEFORE the byte -- never on the
// byte's value -- and after decode_byte_cm absorbs byte i the body's own registers
// already sit at the byte-i+1 state. So the decoder can prefetch its next rows with
// zero future knowledge: same hash chain as ShadowCtx::prefetch_byte's twist branch,
// read straight off the live body, plus the match-table line off the advanced last8.
// Semantically inert (prefetches cannot change outputs); pays off when lanes share a
// thread, because every other lane's arithmetic becomes this body's DRAM lead time.
static inline void prefetch_next_rows(const BitCMBody& body) {
    u32 hb[8];
    u32 h1 = mix32(0x1000193u ^ body.b1*0x9e3779b9u);
    u32 h2 = mix32(h1 ^ body.b2*0x85ebca6bu);
    u32 h3 = mix32(h2 ^ body.b3*0xc2b2ae35u);
    u32 h4 = mix32(h3 ^ body.b4*0x27d4eb2du);
    u32 h5 = mix32(h4 ^ body.b5*0x165667b1u);
    u32 h6 = mix32(h5 ^ body.b6*0x2545f491u);
    u32 hw = mix32(body.word_hash * 0x9e3779b1u + 0x1234567u);
    const u32 linkf = (body.b2=='[' && body.b1=='[') ? 1u : 0u;
    u32 hc = mix32(0xCAFEBABEu ^ body.b1*0x9e3779b9u ^ body.word_hash*0x85ebca6bu
                   ^ (static_cast<u32>(body.caps_run)*0xc2b2ae35u)
                   ^ (static_cast<u32>(body.sent_end)<<30) ^ (linkf<<29)
                   ^ (static_cast<u32>(body.prev_word_caps)<<28));
    hb[0]=h1;hb[1]=h2;hb[2]=h3;hb[3]=h4;hb[4]=h5;hb[5]=h6;hb[6]=hw;hb[7]=hc;
    if (body.twist) {
        for (u32 m=0;m<8;++m) {
            u32 base2;
            if (g_rightsize && m == 0)      base2 = static_cast<u32>(body.b1) << 8;
            else if (g_rightsize && m == 1) base2 = (static_cast<u32>(body.b1) << 16) | (static_cast<u32>(body.b2) << 8);
            else                            base2 = hb[m] * BitCMBody::kCtxStrideInv;
            const u32 fm = body.fam_mask[m];
            const u32 base = base2 & fm;
            __builtin_prefetch(&body.t_hash[m][base], 1, 1);
            __builtin_prefetch(&body.t_hash[m][(base + 128u) & fm], 1, 1);
        }
    } else {
        for (u32 m=0;m<8;++m) {
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

static int extract_main(const std::string& archive_path, const std::string& out_path, u32 threads_arg) {
    auto t0 = std::chrono::steady_clock::now();
    std::vector<u8> a;
    { std::ifstream f(archive_path, std::ios::binary); if(!f) die("cannot open archive: "+archive_path);
      f.seekg(0,std::ios::end); a.resize((size_t)f.tellg()); f.seekg(0); f.read((char*)a.data(),(std::streamsize)a.size()); }
    if (a.size() >= 24 && memcmp(a.data(), V2MAGIC, 8) == 0) {
        // v2: strip the wrapper, v1-decode the payload (inner integrity check runs
        // in there), then replay the dedup recipe and verify the OUTER checksum.
        size_t vo = 8;
        const u64 orig_size = get_u64(a, vo);
        const u64 orig_fnv  = get_u64(a, vo);
        // temps live next to the OUTPUT: the archive's directory may be read-only
        // (network share, backup volume) -- the output's is writable by definition.
        const std::string tmp_payload = v2_temp_path("xpayload");
        const std::string tmp_inner   = v2_temp_path("xinner");
        { std::ofstream f(tmp_inner, std::ios::binary);
          if (!f) die("v2: cannot create temp beside output: " + tmp_inner);
          f.write(reinterpret_cast<const char*>(a.data()) + 24, static_cast<std::streamsize>(a.size() - 24));
          if (!f) die("v2: temp write failed (disk full?): " + tmp_inner); }
        a.clear(); a.shrink_to_fit();
        const int rc = extract_main(tmp_inner, tmp_payload, threads_arg);
        std::remove(tmp_inner.c_str());
        if (rc != 0) { std::remove(tmp_payload.c_str()); return rc; }
        auto rt0 = std::chrono::steady_clock::now();
        v2_reconstruct(tmp_payload, out_path, orig_size, orig_fnv);
        std::remove(tmp_payload.c_str());
        std::cout << "[v2] reconstruct_seconds=" << std::chrono::duration<double>(std::chrono::steady_clock::now()-rt0).count() << "\n";
        std::cout << "[v2] outer_integrity=verified\n";
        std::cout << "[mdlbsg] wall_seconds=" << std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count() << "\n";
        return 0;
    }
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
    if (a.size() < 41 || (memcmp(a.data(), "MDLBTURA", 8) != 0 && memcmp(a.data(), "MDLBTURF", 8) != 0)) die("not an MDLBTURA (turbo/205s lineage) archive");
    size_t o = 8;
    const u64 raw_size = get_u64(a,o);
    g_progress_total = raw_size;              // decode progress is measured in bytes
    const u64 want_fnv = get_u64(a,o);
    const u32 cm_bits = a[o++]; const u32 mm_bits = a[o++];
    g_warm_clamp = a[o++];
    const u8 fl = a[o++];
    g_rightsize = fl & 1u; g_warm_mode = (fl >> 1) & 1u; g_warm_match = (fl >> 2) & 1u; const bool braid = (fl >> 3) & 1u; const bool has_stored = (fl >> 4) & 1u; const bool has_fm = (fl >> 5) & 1u; { const u32 s3c = (fl >> 6) & 3u;
      g_slot3 = (s3c == 0 ? 0 : (s3c == 1 ? 2 : (s3c == 2 ? 3 : -1))); }   // 3 = adaptive, map follows the stored bitmap
    const u32 L = a[o++];
    if (has_fm) { g_fastmatch = static_cast<u32>(a[o]) | (static_cast<u32>(a[o+1]) << 8); o += 2; }
    else g_fastmatch = 0u;   // obey the archive, not the CLI
    g_twist = true;   // this lineage's champion config is always twist layout
    const u64 chunk_bytes = get_u64(a,o); (void)chunk_bytes;
    const u32 chunks = get_u32(a,o);
    std::vector<u64> craw(chunks), cstr(chunks), coff(chunks);
    for (u32 c = 0; c < chunks; ++c) { craw[c] = get_u64(a,o); cstr[c] = get_u64(a,o); }
    std::vector<u8> stored_bits;
    if (has_stored) { stored_bits.assign(a.begin()+(long)o, a.begin()+(long)(o + (chunks+7)/8)); o += (chunks+7)/8; }
    auto chunk_stored = [&](u32 c) -> bool {
        return has_stored && ((stored_bits[c >> 3] >> (c & 7u)) & 1u);
    };
    g_slot3_map.assign(chunks, 0);
    if (g_slot3 < 0) {
        for (u32 c = 0; c < chunks; ++c)
            g_slot3_map[c] = (a[o + (c >> 2)] >> ((c & 3u) * 2u)) & 3u;
        o += (chunks + 3) / 4;
    } else {
        for (u32 c = 0; c < chunks; ++c) g_slot3_map[c] = static_cast<u8>(g_slot3);
    }
    for (u32 c = 0; c < chunks; ++c) { coff[c] = o; o += cstr[c]; }
    if (o != a.size()) die("archive truncated or trailing garbage");
    std::vector<u8> out(static_cast<size_t>(raw_size));
    std::vector<u64> starts(chunks); { u64 s2=0; for(u32 c=0;c<chunks;++c){ starts[c]=s2; s2+=craw[c]; } }
    const bool warm_ready = !chunk_stored(0);   // stored chunk 0 trained nothing; lanes start cold
    if (chunk_stored(0)) {
        std::copy(a.begin()+(long)coff[0], a.begin()+(long)(coff[0]+cstr[0]), out.begin());
        progress_add(craw[0]);
    } else {
        BitCMBody dec(cm_bits, mm_bits, craw[0]);
        dec.cache_local = false; dec.twist = g_twist;
        dec.set_slot3(static_cast<int>(g_slot3_map[0]));
        std::vector<u8> st(a.begin()+(long)coff[0], a.begin()+(long)(coff[0]+cstr[0]));
        RangeDecoder rd(st);
        for (u64 i = 0; i < craw[0]; ++i) {
            out[static_cast<size_t>(i)] = decode_byte_cm(rd, dec);
            if ((i & 0xFFFFu) == 0xFFFFu) progress_add(65536ull);
        }
        progress_add(craw[0] & 0xFFFFull);
        if (g_warm_mode && chunks > 1) warm_capture(dec, g_warm, g_warm_clamp);
    }
    if (chunks > 1) {
        if (!braid || !g_warm_mode) die("archive uses a non-braid layout this extractor does not support yet");
        // LOCKSTEP LANE DECODE -- the encoder's latency-hiding trick, ported to decode.
        // Lanes are semantic (each is a continuous lineage) so they can't be split, but
        // they CAN share OS threads. When the machine has fewer cores than the archive
        // has lanes, each thread advances its lanes byte-by-byte in lockstep: while one
        // body's table line is in DRAM flight, the other bodies' arithmetic issues.
        // Per-lane call order (warm_apply once, reset_positional per chunk, bytes in
        // order) is IDENTICAL to the one-thread-per-lane version -- only cross-lane
        // scheduling changes, so decoded bytes cannot change. Archive bytes untouched.
        u32 T = threads_arg ? threads_arg : std::max<u32>(1u, std::thread::hardware_concurrency());
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
                        if (chunk_stored(static_cast<u32>(s.ci))) {
                            // raw chunk: copy bytes, the body never sees them -- mirrors
                            // the encoder exactly, so lineage state stays byte-identical.
                            std::copy(a.begin()+(long)coff[s.ci], a.begin()+(long)(coff[s.ci]+cstr[s.ci]),
                                      out.begin()+(long)starts[s.ci]);
                            progress_add(craw[s.ci]);
                            s.ci += L;
                            continue;
                        }
                        s.body->set_slot3(static_cast<int>(g_slot3_map[s.ci]));
                        s.body->reset_positional((g_warm_match && warm_ready) ? &g_warm_pos : nullptr, craw[s.ci]);
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
                    s.body->cache_local = false; s.body->twist = g_twist;
                    if (warm_ready) { warm_apply(*s.body, g_warm);
                        s.body->slot3_mode = s.body->slot3_table_mode = static_cast<int>(g_slot3_map[0]); }
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
        else if (a == "--slot3") { const std::string v = need(a);
            g_slot3 = (v == "auto" ? -1 : (v == "ord4" ? 0 : (v == "sp13" ? 2 : (v == "sp24" ? 3 : std::stoi(v))))); }
        else if (a == "--fastmatch") { g_fastmatch = static_cast<u32>(std::stoul(need(a))); if (g_fastmatch > 65535u) g_fastmatch = 65535u; }
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
        else if (a == "--simd") g_simd = (need(a) != "0");
        else if (a == "--interleave") g_interleave = std::max(1u, static_cast<u32>(std::stoul(need(a))));
        else if (a == "--extract") { do_extract = true; extract_to = need(a); }
        else if (a == "--dedup") g_dedup = (need(a) != "0");
        else die("unknown arg: " + a);
    }
    simd_self_proof();
    if (g_resmap) resmap_init();
    if (g_rightsize && !g_twist) die("--rightsize requires --layout twist");
    if (g_rightsize && cm_bits < 24) die("--rightsize requires --cm-bits >= 24");
    if (do_extract) {
        if (archive_path.empty()) die("--archive is required for --extract");
        return extract_main(archive_path, extract_to, threads);
    }
    if (input_path.empty()) die("--input required");
    if (chunk_bytes == 0) die("--chunk-bytes must be > 0");
    // ---- v2: global dedup pass BEFORE chunking ----
    std::string v2_orig_input; u64 v2_orig_size = 0, v2_orig_fnv = 0; std::string v2_payload;
    if (g_dedup && !archive_path.empty()) {
        v2_payload = v2_temp_path("payload");
        auto dt0 = std::chrono::steady_clock::now();
        V2Stats vst = v2_dedup_encode(input_path, v2_payload, v2_orig_size, v2_orig_fnv);
        const double dsec = std::chrono::duration<double>(std::chrono::steady_clock::now() - dt0).count();
        std::cout << "[v2] dedup_seconds=" << dsec
                  << " blocks=" << vst.blocks << " dup_blocks=" << vst.dup_blocks
                  << " dup_mb=" << vst.dup_bytes/1048576.0
                  << " residue_mb=" << vst.residue_bytes/1048576.0
                  << " recipe_mb=" << vst.recipe_bytes/1048576.0 << "\n";
        v2_orig_input = input_path;
        input_path = v2_payload;               // the whole existing pipeline runs on the residue
    }
    if (cm_bits < 16 || cm_bits > 30) die("--cm-bits must be 16..30");
    threads = std::max<u32>(1u, threads);
    // ---- memory guard: thrash is silent death; make it loud and impossible ----
    // Per-chunk body estimate: 8 hashed tables (u16) + match table (u32) + history buffer.
    {
        const u64 body_bytes = 8ull * ((1ull << cm_bits) * 2ull)
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
    // Announce liveness IMMEDIATELY: writing "0 total" here lets the window leave
    // "Preparing..." the instant the engine launches, before any byte is encoded --
    // table allocation on big configs takes seconds, and a UI with no heartbeat
    // during them reads as a hang.
    if (!g_progress_path.empty() && g_progress_total > 0) {
        FILE* f = std::fopen(g_progress_path.c_str(), "w");
        if (f) { std::fprintf(f, "0 %llu\n", g_progress_total); std::fclose(f); }
    }
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
    g_slot3_map.assign(static_cast<size_t>(chunks), 0);
    bool warm_ready = false;   // true only if chunk 0 actually trained a body
    if (g_warm_mode && chunks > 1) {
        // chunk 0 runs alone: its finished body IS the prior for everyone else.
        const u64 len0 = std::min<u64>(chunk_bytes, raw_size);
        std::vector<u8> probe0 = stream_input ? read_slice(input_path, 0, len0)
                                              : std::vector<u8>(input.begin(), input.begin() + static_cast<size_t>(len0));
        if (chunk_should_store(probe0.data(), len0)) {
            // sealed data cannot train a prior; copy it raw, lanes start cold.
            ChunkResult r0; r0.index = 0; r0.start = 0; r0.raw_size = len0;
            r0.stream_size = len0; r0.stored = true;
            if (keep_stream) r0.stream = std::move(probe0);
            progress_add(len0);
            total_stream_bytes += r0.stream_size;
            if (keep_stream) kept[0] = std::move(r0);
            std::cout << "[v234] chunk 0 incompressible -- stored raw, lanes start cold\n";
        } else {
            // chunk 0 will be every lane's warm history: its anchors define what
            // "reachable duplication" means for the rest of the file.
            if (g_warm_match) c0_bloom_add(probe0.data(), len0);
            g_slot3_map[0] = static_cast<u8>(pick_slot3(probe0.data(), len0));
            g_chunk0_mode = g_slot3_map[0];
            ChunkResult r0 = stream_input
                ? encode_chunk_streamed(input_path, 0, 0, len0, cm_bits, mm_bits, cache_local_layout, verify, keep_stream)
                : encode_chunk(input, 0, 0, len0, cm_bits, mm_bits, cache_local_layout, verify, keep_stream);
            total_stream_bytes += r0.stream_size;
            encode_sum += r0.encode_seconds; decode_sum += r0.decode_seconds;
            if (!r0.exact && exact) { exact = false; first_mismatch = r0.first_mismatch; }
            if (keep_stream) kept[0] = std::move(r0);
            warm_ready = true;
            std::cout << "[v234] warm prior captured from chunk 0 (clamp=" << g_warm_clamp << ")\n";
        }
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
                if (warm_ready) { warm_apply(enc_body, g_warm);   // lineage roots at the chunk-0 prior
                    enc_body.slot3_mode = enc_body.slot3_table_mode = static_cast<int>(g_slot3_map[0]); }
                std::unique_ptr<BitCMBody> dec_body;
                if (verify) {
                    dec_body = std::make_unique<BitCMBody>(cm_bits, mm_bits, chunk_bytes);
                    dec_body->cache_local = cache_local_layout; dec_body->twist = g_twist;
                    if (warm_ready) { warm_apply(*dec_body, g_warm);
                        dec_body->slot3_mode = dec_body->slot3_table_mode = static_cast<int>(g_slot3_map[0]); }
                }
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
                    if (chunk_should_store(src + off, len)) {
                        // sealed data: copy raw, and the body NEVER sees these bytes --
                        // the decoder skips them identically, keeping lineages symmetric.
                        r.stored = true; r.stream_size = len; r.exact = true;
                        if (keep_stream) r.stream.assign(src + off, src + off + len);
                        progress_add(len);
                        continue;
                    }
                    g_slot3_map[ci] = static_cast<u8>(pick_slot3(src + off, len));
                    enc_body.set_slot3(static_cast<int>(g_slot3_map[ci]));
                    enc_body.reset_positional((g_warm_match && warm_ready) ? &g_warm_pos : nullptr, len);
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
                        dec_body->set_slot3(static_cast<int>(g_slot3_map[ci]));
                        dec_body->reset_positional((g_warm_match && warm_ready) ? &g_warm_pos : nullptr, len);
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

    const u64 header_bytes = 8 + 8 + 8 + 5 + 8 + 4 + chunks * 16ULL;
    u64 archive_bytes = header_bytes + total_stream_bytes; // mutable: stored fallback overrides
    long long saved = static_cast<long long>(raw_size) - static_cast<long long>(archive_bytes); // recomputed below if stored fallback fires
    auto t1 = std::chrono::steady_clock::now();
    const double wall_s = std::chrono::duration<double>(t1 - t0).count();

    if (keep_stream) {
        std::vector<u8> archive;
        archive.reserve(static_cast<size_t>(std::min<u64>(archive_bytes, 1024ULL*1024ULL*1024ULL)));
        const char magic_file[8] = {'M','D','L','B','T','U','R','A'};
        const char magic_dir[8]  = {'M','D','L','B','T','U','R','F'};
        const char* magic = g_content_folder ? magic_dir : magic_file;   // TURBO/205s lineage archive
        archive.insert(archive.end(), magic, magic+8);
        put_u64(archive, raw_size);
        u64 fnv = 1469598103934665603ULL;
        { std::ifstream cf(input_path, std::ios::binary);
          if (!cf) die("cannot reopen input for checksum: " + input_path);
          std::vector<u8> cbuf(1u << 20);
          while (cf) { cf.read(reinterpret_cast<char*>(cbuf.data()), static_cast<std::streamsize>(cbuf.size()));
              const std::streamsize got = cf.gcount();
              for (std::streamsize ci = 0; ci < got; ++ci) { fnv ^= cbuf[static_cast<size_t>(ci)]; fnv *= 1099511628211ULL; } } }
        put_u64(archive, fnv);
        bool any_stored = false; u32 stored_n = 0;
        for (const auto& r : kept) if (r.stored) { any_stored = true; ++stored_n; }
        archive.push_back(static_cast<u8>(cm_bits));
        archive.push_back(static_cast<u8>(mm_bits));
        archive.push_back(static_cast<u8>(g_warm_clamp));
        archive.push_back(static_cast<u8>((g_rightsize?1u:0u) | (g_warm_mode?2u:0u) | (g_warm_match?4u:0u) | (g_braid?8u:0u) | (any_stored?16u:0u) | (g_fastmatch?32u:0u) | (static_cast<u32>((g_slot3 < 0 ? 3 : (g_slot3 == 0 ? 0 : (g_slot3 == 2 ? 1 : 2))) & 3u) << 6)));
        archive.push_back(static_cast<u8>(threads));
        if (g_fastmatch) {
            // 16-bit little-endian. The first draft wrote min(T,255) into one byte:
            // encoder ran at 512, archive said 255, and the decoder's fast path fired
            // one agree-bit early the moment a match run crossed 255 -- instant
            // desync. The header must carry the EXACT threshold the encoder used.
            const u32 fmv = g_fastmatch > 65535u ? 65535u : g_fastmatch;
            archive.push_back(static_cast<u8>(fmv & 0xFFu));
            archive.push_back(static_cast<u8>((fmv >> 8) & 0xFFu));
        }
        put_u64(archive, chunk_bytes);
        put_u32(archive, static_cast<u32>(chunks));
        for (const auto& r : kept) { put_u64(archive, r.raw_size); put_u64(archive, r.stream_size); }
        if (any_stored) {
            std::vector<u8> bitmap((chunks + 7) / 8, 0);
            for (u32 c = 0; c < chunks; ++c) if (kept[c].stored) bitmap[c >> 3] |= static_cast<u8>(1u << (c & 7u));
            archive.insert(archive.end(), bitmap.begin(), bitmap.end());
            std::cout << "[v234] stored_chunks=" << stored_n << "/" << chunks
                      << " (incompressible data copied raw, model effort saved)\n";
        }
        if (g_slot3 < 0) {
            std::vector<u8> smap((chunks + 3) / 4, 0);
            for (u32 c = 0; c < chunks; ++c) smap[c >> 2] |= static_cast<u8>((g_slot3_map[c] & 3u) << ((c & 3u) * 2u));
            archive.insert(archive.end(), smap.begin(), smap.end());
        }
        for (const auto& r : kept) archive.insert(archive.end(), r.stream.begin(), r.stream.end());
        archive_bytes = archive.size();
        saved = static_cast<long long>(raw_size) - static_cast<long long>(archive_bytes);
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
            if (!v2_payload.empty()) {
                std::vector<u8> hdr(V2MAGIC, V2MAGIC + 8);
                put_u64(hdr, v2_orig_size);
                put_u64(hdr, v2_orig_fnv);
                archive.insert(archive.begin(), hdr.begin(), hdr.end());
            }
            write_all(archive_path, archive);
            archive_bytes = archive.size();
            saved = static_cast<long long>((v2_payload.empty() ? raw_size : v2_orig_size)) - static_cast<long long>(archive_bytes);
        }
    }
    if (!v2_payload.empty()) std::remove(v2_payload.c_str());

    std::cout << "[v234] input_bytes=" << (v2_payload.empty() ? raw_size : v2_orig_size) << "\n";
    if (!v2_payload.empty()) std::cout << "[v2] dedup_removed_bytes=" << (v2_orig_size - raw_size) << "\n";
    std::cout << "[v234] archive_bytes=" << archive_bytes << "\n";
    std::cout << "[v234] saved_vs_raw_bytes=" << saved << "\n";
    std::cout << "[v234] exact_replay=" << (verify ? (exact ? "true" : "false") : "not_checked") << "\n";
    resmap_print(total_stream_bytes);
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