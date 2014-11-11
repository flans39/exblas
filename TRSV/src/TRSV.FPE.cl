
#pragma OPENCL EXTENSION cl_khr_fp64                   : enable  //For double precision numbers
#pragma OPENCL EXTENSION cl_khr_int64_base_atomics     : enable  //For 64 atomic operations
#pragma OPENCL EXTENSION cl_khr_byte_addressable_store : enable
#ifdef NVIDIA
    #pragma OPENCL EXTENSION cl_nv_pragma_unroll       : enable
#endif

#define BIN_COUNT  76
#define K          8                    //High-radix carry-save bits
#define digits     56
#define deltaScale 72057594037927936.0  //Assumes K > 0
#define f_words    39 
#define TSAFE      0


////////////////////////////////////////////////////////////////////////////////
// Auxiliary functions
////////////////////////////////////////////////////////////////////////////////
double TwoProductFMA(double a, double b, double *d) {
    double p = a * b;
    *d = fma(a, b, -p);
    return p;
}

#ifdef USE_KNUTH
    double KnuthTwoSum(double a, double b, double *s) {
        double r = a + b;
        double z = r - a;
        *s = (a - (r - z)) + (b - z);
        return r;
    }
#else
    //twosum
    double KnuthTwoSum(double a, double b, double *s) {
        double r = a + b;
        int doswap = fabs(b) > fabs(a);
        double a2 = doswap ? b : a;
        double b2 = doswap ? a : b;
        *s = (a2 - r) + b2;
        return r;
    }
#endif

// signedcarry in {-1, 0, 1}
long xadd(__global volatile long *sa, long x, uchar *of) {
    // OF and SF  -> carry=1
    // OF and !SF -> carry=-1
    // !OF        -> carry=0
    long y = atom_add(sa, x);
    long z = y + x; // since the value sa->accumulator[i] can be changed by another work item

    // TODO: cover also underflow
    *of = 0;
    if(x > 0 && y > 0 && z < 0)
        *of = 1;
    if(x < 0 && y < 0 && z > 0)
        *of = 1;

    return y;
}


////////////////////////////////////////////////////////////////////////////////
// Kulisch accumulator: rounding and accumulation functions
////////////////////////////////////////////////////////////////////////////////
double OddRoundSumNonnegative(double th, double tl) {
    union {
        double d;
        long l;
    } thdb;

    thdb.d = th + tl;
    // - if the mantissa of th is odd, there is nothing to do
    // - otherwise, round up as both tl and th are positive
    // in both cases, this means setting the msb to 1 when tl>0
    thdb.l |= (tl != 0.0);
    return thdb.d;
}

int Normalize(__global long *accumulator, int *imin, int *imax) {
    if (*imin > *imax)
        return 0;

    long carry_in = accumulator[*imin * BLOCK_SIZE] >> digits;
    accumulator[*imin * BLOCK_SIZE] -= carry_in << digits;
    int i;
    // Sign-extend all the way
    for (i = *imin + 1; i < BIN_COUNT; ++i) {
#if 1
        long carry_out = accumulator[i * BLOCK_SIZE] >> digits;    // Arithmetic shift
        accumulator[i * BLOCK_SIZE] += carry_in - (carry_out << digits);
#else
        // BUGGY
        // get carry of accumulator[i] + carry_in
        unsigned char overflow;
        long oldword = xadd(&accumulator[i], carry_in, &overflow);
        int s = oldword > 0;
        long carrybit = (s ? 1ll << K : -1ll << K);

        long carry_out = (accumulator[i] >> digits) + carrybit;// Arithmetic shift
        accumulator[i] -= carry_out << digits;
#endif
        carry_in = carry_out;
    }
    *imax = i - 1;

    if ((carry_in != 0) && (carry_in != -1)) {
        //TODO: handle overflow
        //status = Overflow;
    }

    return carry_in < 0;
}

double Round(__global long *accumulator) {
    int imin = 0;
    int imax = 75;
    int negative = Normalize(accumulator, &imin, &imax);

    //Find leading word
    int i;
    //Skip zeroes
    for (i = imax; accumulator[i * BLOCK_SIZE] == 0 && i >= imin; --i) {
    }
    if (negative) {
        //Skip ones
        for (; accumulator[i * BLOCK_SIZE] == ((1 << digits) - 1) && i >= imin; --i) {
        }
    }
    if (i < 0)
        //TODO: should we preserve sign of zero?
        return 0.0;

    long hiword = negative ? (1 << digits) - accumulator[i * BLOCK_SIZE] : accumulator[i * BLOCK_SIZE];
    double rounded = (double) hiword;
    double hi = ldexp(rounded, (i - f_words) * digits);
    if (i == 0)
        return negative ? -hi : hi;  // Correct rounding achieved
    hiword -= (long) rint(rounded);
    double mid = ldexp((double) hiword, (i - f_words) * digits);

    //Compute sticky
    long sticky = 0;
    for (int j = imin; j != i - 1; ++j)
        sticky |= negative ? (1 << digits) - accumulator[j * BLOCK_SIZE] : accumulator[j * BLOCK_SIZE];

    long loword = negative ? (1 << digits) - accumulator[(i - 1) * BLOCK_SIZE] : accumulator[(i - 1) * BLOCK_SIZE];
    loword |= !!sticky;
    double lo = ldexp((double) loword, (i - 1 - f_words) * digits);

    //Now add3(hi, mid, lo)
    //No overlap, we have already normalized
    if (mid != 0)
        lo = OddRoundSumNonnegative(mid, lo);

    //Final rounding
    hi = hi + lo;
    return negative ? -hi : hi;
}

void AccumulateWord(__global volatile long *sa, int i, long x) {
    // With atomic accumulator updates
    // accumulation and carry propagation can happen in any order,
    // as long as addition is atomic
    // only constraint is: never forget an overflow bit
    uchar overflow;
    long carry = x;
    long carrybit;
    long oldword = xadd(&sa[i * BLOCK_SIZE], x, &overflow);

    // To propagate over- or underflow
    while (overflow) {
        // Carry or borrow
        // oldword has sign S
        // x has sign S
        // accumulator[i] has sign !S (just after update)
        // carry has sign !S
        // carrybit has sign S
        carry = (oldword + carry) >> digits;    // Arithmetic shift
        bool s = oldword > 0;
        carrybit = (s ? 1l << K : -1l << K);

        // Cancel carry-save bits
        xadd(&sa[i * BLOCK_SIZE], (long) -(carry << digits), &overflow);
        if (TSAFE && (s ^ overflow))
            carrybit *= 2;
        carry += carrybit;

        ++i;
        if (i >= BIN_COUNT)
            return;
        oldword = xadd(&sa[i * BLOCK_SIZE], carry, &overflow);
    }
}

void Accumulate(__global volatile long *sa, double x) {
    if (x == 0)
        return;

    int e;
    frexp(x, &e);
    int exp_word = e / digits;  // Word containing MSbit
    int iup = exp_word + f_words;

    double xscaled = ldexp(x, -digits * exp_word);

    int i;
    for (i = iup; xscaled != 0; --i) {
        double xrounded = rint(xscaled);
        long xint = (long) xrounded;

        AccumulateWord(sa, i, xint);

        xscaled -= xrounded;
        xscaled *= deltaScale;
    }
}


////////////////////////////////////////////////////////////////////////////////
// Substitution algorithm
////////////////////////////////////////////////////////////////////////////////
/* loops until *sync > val.
 * Needs to be seperate function to force volatile onto *sync.
 */
void wait_until_ge(
    int tid,
    __global volatile int *sync,
    int col_to_wait,
    int *col_done
){
    if(tid == 0) {
        /* Only read global memory when necessary */
        if (*col_done < col_to_wait) {
            while(*sync < col_to_wait) {}
            *col_done = *sync;
        }
    }
    barrier(CLK_GLOBAL_MEM_FENCE);
}

/* Returns next block row index that requires processing */
int nextRow(
   __global volatile int *address
){
   __local volatile int old;
   if(get_local_id(0)==0 && get_local_id(1)==0)
      old = atomic_add(address, 1);

   barrier(CLK_GLOBAL_MEM_FENCE);
   return old;
}

/* Sets sync values correctly prior to call to trsv_ln_exec */
__kernel void trsv_init(
    __global int *sync
){
   sync[0] = -1; // Last ready column
   sync[1] = 0;  // Next row to assign
}

/* Copies a nbi x nbi block of a to provided cache.
 * Copies -a and only the half triangle
 */
void tocache(
    __global const double *a,
    __local double *cache,
    const uint nbi,
    const uint ntid,
    const uint trans,
    const uint isunit,
    const uint tid,
    const uint lda
){
    int x = tid % nbi;
    int y = tid / nbi;
    int ty = ntid / nbi;
    //int lidx = get_local_id(0);
    //int lidy = get_local_id(1);

    if(trans == 0) {
        /*for (int j = 0; j < BLOCK_SIZE; j+=threadsy) {
            if (lidx > (lidy + j))
                cache[threadsx * (lidy + j) + lidx] = a[lda * (lidy + j) + lidx];
            else if ((lidy + j) < BLOCK_SIZE)
                cache[threadsx * (lidy + j) + lidx] = 0.0;
            if (isunit && (lidx == (lidy + j)))
                cache[threadsx * (lidy + j) + lidx] = 1.0;
        }*/
        for (int i = 0; i < nbi; i += ty) {
            if (x > (i + y))
                cache[(i + y) * nbi + x] = -a[(i + y) * lda + x];
            else if ((i + y) < nbi)
                cache[(i + y) * nbi + x] = 0.0;
            if (!isunit && (x == (i + y)))
                cache[x * (nbi + 1)] = 1.0 / a[x * (lda + 1)];
        }
    }
}

__kernel void trsv_lnn(
    __global double *d_x,
    __global double *d_a,
    __global double *d_b,
    __global int *sync,
    __global long *d_Superaccs,
    const uint n
){
    __local double cache[BLOCK_SIZE * BLOCK_SIZE];

    int lidx = get_local_id(0);
    int lidy = get_local_id(1);
    int tid  = threadsx * lidy + lidx;
    int isunit = 0;

    __global long *l_working = d_Superaccs + get_group_id(0) * threadsy * threadsx * BIN_COUNT + (get_local_id(0) & (BLOCK_SIZE - 1));

    // Get row handled by this block
    int row = nextRow(&sync[1]);

    // Copy diagonal block to shared memory
    tocache(&d_a[row * BLOCK_SIZE * n + row * BLOCK_SIZE], cache, BLOCK_SIZE, threadsx * threadsy, 0, isunit, tid, n);
    barrier(CLK_LOCAL_MEM_FENCE);

    // Loop over blocks as they become available
    // Initialize accumulators
    for (uint i = 0; i < BIN_COUNT; i++)
        l_working[i * BLOCK_SIZE] = 0;
    // FPEs
    double x, s, r;
    double fpe[NBFPE] = {0.0};
    if(lidy == 0) {
        x = d_b[row * BLOCK_SIZE + lidx];
        #ifdef NVIDIA
          #pragma unroll
        #endif
        for(uint i = 0; i != NBFPE; ++i) {
            fpe[i] = KnuthTwoSum(fpe[i], x, &s);
            x = s;
        }
        if(x != 0.0)
            Accumulate(l_working, x);
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    int col_done = -1;

    for (int col = 0; col < row; col++) {
        wait_until_ge(tid, &sync[0], col, &col_done); // Wait for diagonal block to be done
        #ifdef NVIDIA
            #pragma unroll
        #endif
        for (int j = 0; j < BLOCK_SIZE; j+=threadsy) {
            r = 0.0;
            double ap = d_a[(col * BLOCK_SIZE + lidy) * n + row * BLOCK_SIZE + lidx + j * n];
            double xp = -d_x[col * BLOCK_SIZE + lidy + j];
            x = TwoProductFMA(ap, xp, &r);

            /*#ifdef NVIDIA
                #pragma unroll
            #endif
            for(uint i = 0; i != NBFPE; ++i) {
                fpe[i] = KnuthTwoSum(fpe[i], x, &s);
                x = s;
            }
            if(x != 0.0)*/
                Accumulate(l_working, x);

            /*#ifdef NVIDIA
                #pragma unroll
            #endif
            for(uint i = 0; i != NBFPE; ++i) {
                s = 0.0;
                fpe[i] = KnuthTwoSum(fpe[i], r, &s);
                r = s;
            }*/
            if(r != 0.0)
                Accumulate(l_working, r);
        }
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // Apply update from diagonal block (row, row)
    if (lidy == 0) {
        double val = 0.0;
        __local volatile double xs;
        #ifdef NVIDIA
            #pragma unroll
        #endif
        for (uint i = 0; i < BLOCK_SIZE; i++) {
            if (lidx == i) {
                //TODO: round only fpes when accumulator was not used
                //Flush to the accumulator
                #ifdef NVIDIA
                    #pragma unroll
                #endif
                for(uint i = 0; i != NBFPE; ++i)
                    Accumulate(l_working, fpe[i]);
                barrier(CLK_LOCAL_MEM_FENCE);

                val = Round(l_working);
                if (!isunit)
                    val *= cache[i * (BLOCK_SIZE + 1)];
                xs = val;
            }
            if (lidx > i) {
                r = 0.0;
                x = TwoProductFMA(cache[i * BLOCK_SIZE + lidx], xs, &r);

                #ifdef NVIDIA
                    #pragma unroll
                #endif
                for(uint i = 0; i != NBFPE; ++i) {
                    s = 0.0;
                    fpe[i] = KnuthTwoSum(fpe[i], x, &s);
                    x = s;
                }
                if(x != 0.0)
                    Accumulate(l_working, x);

                #ifdef NVIDIA
                    #pragma unroll
                #endif
                for(uint i = 0; i != NBFPE; ++i) {
                    s = 0.0;
                    fpe[i] = KnuthTwoSum(fpe[i], r, &s);
                    r = s;
                }
                if(r != 0.0)
                    Accumulate(l_working, r);
            }
        }
        d_x[row * BLOCK_SIZE + tid] = val;
    }

    // Notify other blocks that soln is ready for this row
    barrier(CLK_GLOBAL_MEM_FENCE); // Wait for d_x to be visible to other blocks
    if(tid == 0)
        atomic_add(&sync[0], 1);   // Use atomicAdd to bypass L1 miss
    barrier(CLK_GLOBAL_MEM_FENCE); // Flush sync[0] asap
}

