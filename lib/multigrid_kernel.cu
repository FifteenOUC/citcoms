/* -*- C -*- */
/* vim:set ft=c: */

#if __CUDA_ARCH__ < 130
/* for double-precision floating-point */
#error This code requires compute capability 1.3 or higher; try giving "-arch sm_13".
#endif


#include "global_defs.h"
#include "element_definitions.h"
#include <assert.h>
#include <stdio.h>


enum {
    CAPS_PER_PROC = 1,
    M = 1, /* cap # */
    NSD = 3, /* Spatial extent: 3d */
    MAX_EQN = NSD*14,
};


struct Some_variables {
    int num_zero_resid;
    int *zero_resid;
    
    struct /*MESH_DATA*/ {
        int NEQ;
        int NNO;
    } lmesh;
    
    struct ID *ID;
    
    higher_precision *Eqn_k[NSD+1];
    int *Node_map;
    
    double *BI;
    
    double *temp;
    unsigned int *NODE;
    
    int2 *term;
};


/*------------------------------------------------------------------------*/

static void construct_E(
    struct Some_variables **d_E,
    struct Some_variables *s_E, /* host's shadow copy of d_E */
    struct Some_variables *E
    )
{
    /* construct a copy of 'E' in device memory */
    
    int neq = E->lmesh.NEQ;
    int nno = E->lmesh.NNO;
    
    s_E->lmesh.NEQ = E->lmesh.NEQ;
    s_E->lmesh.NNO = E->lmesh.NNO;
    
    /* ID -- cf. allocate_common_vars()*/
    cudaMalloc((void **)&s_E->ID, (nno+1)*sizeof(struct ID));
    cudaMemcpy(s_E->ID, E->ID, (nno+1)*sizeof(struct ID), cudaMemcpyHostToDevice);
    
    /* Eqn_k, Node_map -- cf. construct_node_maps() */
    size_t matrix = MAX_EQN * nno;
    s_E->Eqn_k[0] = 0;
    cudaMalloc((void **)&s_E->Eqn_k[1], 3*matrix*sizeof(higher_precision));
    s_E->Eqn_k[2] = s_E->Eqn_k[1] + matrix;
    s_E->Eqn_k[3] = s_E->Eqn_k[2] + matrix;
    cudaMemcpy(s_E->Eqn_k[1], E->Eqn_k[1], matrix*sizeof(higher_precision), cudaMemcpyHostToDevice);
    cudaMemcpy(s_E->Eqn_k[2], E->Eqn_k[2], matrix*sizeof(higher_precision), cudaMemcpyHostToDevice);
    cudaMemcpy(s_E->Eqn_k[3], E->Eqn_k[3], matrix*sizeof(higher_precision), cudaMemcpyHostToDevice);
    cudaMalloc((void **)&s_E->Node_map, matrix*sizeof(int));
    cudaMemcpy(s_E->Node_map, E->Node_map, matrix*sizeof(int), cudaMemcpyHostToDevice);
    
    /* BI -- cf. allocate_velocity_vars() */
    cudaMalloc((void **)&s_E->BI, neq*sizeof(double));
    cudaMemcpy(s_E->BI, E->BI, neq*sizeof(double), cudaMemcpyHostToDevice);
    
    /* temp -- cf. allocate_velocity_vars() */
    cudaMalloc((void **)&s_E->temp, (neq+1)*sizeof(double));
    cudaMemcpy(s_E->temp, E->temp, (neq+1)*sizeof(double), cudaMemcpyHostToDevice);
    
    /* NODE -- cf. allocate_common_vars() */
    cudaMalloc((void **)&s_E->NODE, (nno+1)*sizeof(unsigned int));
    cudaMemcpy(s_E->NODE, E->NODE, (nno+1)*sizeof(unsigned int), cudaMemcpyHostToDevice);
    
    /* term */
    cudaMalloc((void **)&s_E->term, (neq+1) * MAX_EQN * sizeof(int2));
    cudaMemcpy(s_E->term, E->term, (neq+1) * MAX_EQN * sizeof(int2), cudaMemcpyHostToDevice);
    
    /* E */
    cudaMalloc((void**)d_E, sizeof(Some_variables));
    cudaMemcpy(*d_E, s_E, sizeof(Some_variables), cudaMemcpyHostToDevice);
    
    return;
}

static void destroy_E(
    struct Some_variables *d_E,
    struct Some_variables *s_E
    )
{
    cudaFree(s_E->ID);
    cudaFree(s_E->Eqn_k[1]);
    cudaFree(s_E->Node_map);
    cudaFree(s_E->BI);
    cudaFree(s_E->temp);
    cudaFree(s_E->NODE);
    cudaFree(s_E->term);
    cudaFree(d_E);
}


/*------------------------------------------------------------------------*/
/* from Element_calculations.c */

__global__ void n_assemble_del2_u(
    struct Some_variables *E,
    double *u, double *Au,
    int strip_bcs
    )
{
    int n = blockIdx.x + 1; /* 1 <= n <= E->lmesh.NNO */
    int doff = blockIdx.y + 1; /* 1 <= doff < NSD */ 
    unsigned int tid = threadIdx.x; /* 0 <= tid < MAX_EQN */
    
    /* Each block writes one element of Au in global memory: Au[eqn]. */
    int eqn = E->ID[n].doff[doff]; /* XXX: Compute this value? */
    
    if (strip_bcs) {
        /* See get_bcs_id_for_residual(). */
        unsigned int flags = E->NODE[n];
        unsigned int vb = 0x1 << doff; /* VBX, VBY, or VBZ */
        if (flags & vb) {
            /* no-op: Au[eqn] is zero */
            if (tid == 0) {
                Au[eqn] = 0.0;
            }
            /* XXX: Hundreds of blocks exit here (E->num_zero_resid).
               Does it matter? */
            return;
        }
    }
    
    /* The partial sum computed by this thread. */
    double acc;
    
    /* Part I: The terms here are easily derived from the block and
       thread indices. */
    {
        int e = n; /* 1 <= e <= E->lmesh.NNO */
        int i = (int)tid; /* 0 <= i < MAX_EQN */
        
        if (i < 3) {
            acc = 0.0;
        } else {
            int *C = E->Node_map + (e-1)*MAX_EQN;
            higher_precision *B = E->Eqn_k[doff]+(e-1)*MAX_EQN;
            double UU = u[C[i]];
            acc = B[i]*UU;
        }
    }
    
    /* Part II: These terms are more complicated. */
    {
        int2 *term = E->term + eqn*MAX_EQN;
        int2 pair = term[tid];
        int e = pair.x; /* 1 <= e <= E->lmesh.NNO */
        int i = pair.y; /* 0 <= i < MAX_EQN */
        
        if (i != -1) {
            /* XXX: Compute these values? */
            int eqn1 = E->ID[e].doff[1];
            int eqn2 = E->ID[e].doff[2];
            int eqn3 = E->ID[e].doff[3];
            
            double U1 = u[eqn1];
            double U2 = u[eqn2];
            double U3 = u[eqn3];
            
            higher_precision *B1, *B2, *B3;
            B1 = E->Eqn_k[1]+(e-1)*MAX_EQN;
            B2 = E->Eqn_k[2]+(e-1)*MAX_EQN;
            B3 = E->Eqn_k[3]+(e-1)*MAX_EQN;
            
            acc += B1[i]*U1 +
                   B2[i]*U2 +
                   B3[i]*U3;
        } else {
            /* XXX: A considerable number of threads idle here. */
        }
    }
    
    /* Reduce the partial sums for this block.
       Based on reduce2() in the CUDA SDK. */
    __shared__ double sum[MAX_EQN];
    sum[tid] = acc;
    __syncthreads();
    for (unsigned int s = MAX_EQN/2; s > 0; s >>= 1) {
        if (tid < s) {
            sum[tid] += sum[tid + s];
        }
        /* XXX: not always necessary */
        __syncthreads();
    }
    
    /* Each block writes one element of Au in global memory. */
    if (tid == 0) {
        Au[eqn] = sum[0];
        
        if (n == 1 && doff == 1) {
            /* Well, actually, the first block writes one more. */
            Au[E->lmesh.NEQ] = 0.0;
        }
    }
    
    return;
}


/*------------------------------------------------------------------------*/
/* These are based on the function from General_matrix_functions.c. */

__global__ void gauss_seidel_0(
    struct Some_variables *E,
    double *d0,
    double *Ad
    )
{
    const double zeroo = 0.0;
    int i;
    
    i = blockIdx.x; /* 0 <= i < E->lmesh.NEQ */
    d0[i] = Ad[i] = zeroo;
}

__global__ void gauss_seidel_1(
    struct Some_variables *E,
    double *F, double *Ad
    )
{
    const double zeroo = 0.0;
    const int neq = E->lmesh.NEQ;
    
    int i, doff, eqn;
    
    i = blockIdx.x + 1; /* 1 <= i <= E->lmesh.NNO */
    doff = blockIdx.y + 1; /* 1 <= doff < NSD */ 
    eqn = E->ID[i].doff[doff];
    
    if (E->NODE[i] & OFFSIDE) {
        E->temp[eqn] = (F[eqn] - Ad[eqn])*E->BI[eqn];
    } else {
        E->temp[eqn] = zeroo;
    }
    
    if (i == 1 && doff == 1) {
        E->temp[neq] = zeroo;
        Ad[neq] = zeroo;
    }
}

__global__ void gauss_seidel_2(
    struct Some_variables *E,
    double *F, double *Ad
    )
{
    int i, doff, eqn;
    
    i = blockIdx.x + 1; /* 1 <= i <= E->lmesh.NNO */
    doff = blockIdx.y + 1; /* 1 <= doff < NSD */ 
    eqn = E->ID[i].doff[doff];
    
    int *C;
    higher_precision *B;
    double UU, Ad_eqn;
    int j;
    
    C = E->Node_map+(i-1)*MAX_EQN;
    B = E->Eqn_k[doff]+(i-1)*MAX_EQN;
    
    /* load from global memory */
    Ad_eqn = Ad[eqn];
    
    /* Ad on boundaries differs after the following operation, but
       no communications are needed yet, because boundary Ad will
       not be used for the G-S iterations for interior nodes */
    
    for (j=3;j<MAX_EQN;j++)  {
        UU = E->temp[C[j]];
        Ad_eqn += B[j]*UU;
    }
    
    /* store to global memory */
    Ad[eqn] = Ad_eqn;
    
    if (!(E->NODE[i] & OFFSIDE))   {
        E->temp[eqn] = (F[eqn] - Ad_eqn)*E->BI[eqn];
    }

}

__global__ void gauss_seidel_3(
    struct Some_variables *E,
    double *d0,
    double *Ad
    )
{
    int n = blockIdx.x + 1; /* 1 <= n <= E->lmesh.NNO */
    int doff = blockIdx.y + 1; /* 1 <= doff < NSD */ 
    unsigned int tid = threadIdx.x; /* 0 <= tid < MAX_EQN */
    
    /* Each block writes one element of Ad and d0 in global memory:
       Ad[eqn], d0[eqn]. */
    int eqn = E->ID[n].doff[doff]; /* XXX: Compute this value? */
    
    __shared__ double sum[MAX_EQN];
    
    int2 *term = E->term + eqn*MAX_EQN;
    int2 pair = term[tid];
    int e = pair.x; /* 1 <= e <= E->lmesh.NNO */
    int i = pair.y; /* 0 <= i < MAX_EQN */
        
    if (i != -1) {
        /* XXX: Compute these values? */
        int eqn1 = E->ID[e].doff[1];
        int eqn2 = E->ID[e].doff[2];
        int eqn3 = E->ID[e].doff[3];
            
        higher_precision *B1, *B2, *B3;
        B1 = E->Eqn_k[1]+(e-1)*MAX_EQN;
        B2 = E->Eqn_k[2]+(e-1)*MAX_EQN;
        B3 = E->Eqn_k[3]+(e-1)*MAX_EQN;
        
        sum[tid] = B1[i]*E->temp[eqn1] +
                   B2[i]*E->temp[eqn2] +
                   B3[i]*E->temp[eqn3];
    } else {
        /* XXX: A considerable number of threads idle here. */
        sum[tid] = 0.0;
    }
    __syncthreads();
    
    /* Reduce the partial sums for this block.
       Based on reduce2() in the CUDA SDK. */
    for (unsigned int s = MAX_EQN/2; s > 0; s >>= 1) {
        if (tid < s) {
            sum[tid] += sum[tid + s];
        }
        /* XXX: not always necessary */
        __syncthreads();
    }
    
    if (tid == 0) {
        /* Each block writes one element of Ad... */
        Ad[eqn] += sum[0];
        /* ..and one element of d0. */
        d0[eqn] += E->temp[eqn];
    }
}


void host_n_assemble_del2_u(
    struct Some_variables *E,
    double *u, double *Au,
    int strip_bcs
    );

void host_gauss_seidel_0(
    struct Some_variables *E,
    double *d0,
    double *Ad
    );

void host_gauss_seidel_1(
    struct Some_variables *E,
    struct Some_variables *s_E,
    double *F, double *Ad
    );

void host_gauss_seidel_2(
    struct Some_variables *E,
    struct Some_variables *s_E,
    double *F, double *Ad
    );

void host_gauss_seidel_3(
    struct Some_variables *E,
    struct Some_variables *s_E,
    double *d0,
    double *Ad
    );


void do_gauss_seidel(
    struct Some_variables *E,
    double *d0,
    double *F, double *Ad,
    double acc,
    int *cycles,
    int guess
    )
{

    int count, steps;

    steps=*cycles;

    /* pointers to device memory */
    struct Some_variables *d_E = 0;
    double *d_d0 = 0, *d_F = 0, *d_Ad = 0;
    
    /* construct 'E' on the device */
    struct Some_variables s_E;
    construct_E(&d_E, &s_E, E);
    
    int neq = E->lmesh.NEQ;
    
    /* allocate memory on the device */
    cudaMalloc((void**)&d_d0, (1+neq)*sizeof(double));
    cudaMalloc((void**)&d_F, neq*sizeof(double));
    cudaMalloc((void**)&d_Ad, (1+neq)*sizeof(double));
    
    /* copy input to the device */
    cudaMemcpy(d_F, F, neq*sizeof(double), cudaMemcpyHostToDevice);
    
    if (guess) {
        /* copy more input to the device */
        d0[E->lmesh.NEQ] = 0.0; /* normally done by n_assemble_del2_u() */
        cudaMemcpy(d_d0, d0, (1+neq)*sizeof(double), cudaMemcpyHostToDevice);
        
        dim3 block(MAX_EQN, 1, 1);
        dim3 grid(E->lmesh.NNO, NSD, 1);
        if (0) n_assemble_del2_u<<< grid, block >>>(d_E, d_d0, d_Ad, 1);
        else host_n_assemble_del2_u(E, d_d0, d_Ad, 1);
    
    } else {
        dim3 block(1, 1, 1);
        dim3 grid(E->lmesh.NEQ, 1, 1);
        if (1) gauss_seidel_0<<< grid, block >>>(d_E, d_d0, d_Ad);
        else host_gauss_seidel_0(E, d_d0, d_Ad);
    }
    
    for (count = 0; count < steps; ++count) {
        {
            dim3 block(1, 1, 1);
            dim3 grid(E->lmesh.NNO, NSD, 1);
            if (1) gauss_seidel_1<<< grid, block >>>(d_E, d_F, d_Ad);
            else host_gauss_seidel_1(E, &s_E, d_F, d_Ad);
            if (0) gauss_seidel_2<<< grid, block >>>(d_E, d_F, d_Ad);
            else host_gauss_seidel_2(E, &s_E, d_F, d_Ad);
        }
        
        /* Ad on boundaries differs after the following operation */
        {
            dim3 block(MAX_EQN, 1, 1);
            dim3 grid(E->lmesh.NNO, NSD, 1);
            if (0) gauss_seidel_3<<< grid, block >>>(d_E, d_d0, d_Ad);
            else host_gauss_seidel_3(E, &s_E, d_d0, d_Ad);            
        }
    }
    
    /* wait for completion */
    if (cudaThreadSynchronize() != cudaSuccess) {
        assert(0 && "something went wrong");
    }
    
    /* copy output from device */
    cudaMemcpy(Ad, d_Ad, (1+neq)*sizeof(double), cudaMemcpyDeviceToHost);
    cudaMemcpy(d0, d_d0, (1+neq)*sizeof(double), cudaMemcpyDeviceToHost);
    
    /* free device memory */
    cudaFree(d_d0);
    cudaFree(d_F);
    cudaFree(d_Ad);
    
    destroy_E(d_E, &s_E);
    
    *cycles=count;
    
    return;
}


/*------------------------------------------------------------------------*/

static void assert_assumptions(struct All_variables *E, int level) {
    
    assert(E->control.NMULTIGRID);
    
    assert(E->sphere.caps_per_proc == CAPS_PER_PROC);
    
    assert(E->mesh.nsd == NSD);
    
    assert(E->parallel.nproc == 1);
}

static void collect_terms(
    struct Some_variables *E
    )
{
    /* Map out how to parallelize "Au[C[i]] += ..." and "Ad[C[j]] += ...". */
    
    const int neq = E->lmesh.NEQ;
    const int nno = E->lmesh.NNO;
    
    E->term = (int2 *)malloc((neq+1) * MAX_EQN * sizeof(int2));
    
    for (int e = 0; e <= neq; e++) {
        int2 *term = E->term + e*MAX_EQN;
        for (int j = 0; j < MAX_EQN; j++) {
            term[j].x = -1;
            term[j].y = -1;
        }
    }
    
    for (int e = 1; e <= nno; e++) {
        int *C = E->Node_map + (e-1)*MAX_EQN;
        for (int i = 0; i < MAX_EQN; i++) {
            int2 *term = E->term + C[i]*MAX_EQN;
            int j;
            for (j = 0; j < MAX_EQN; j++) {
                if (term[j].x == -1) {
                    term[j].x = e;
                    term[j].y = i;
                    break;
                }
            }
            assert(C[i] == neq || j < MAX_EQN);
        }
    }
    
    return;
}


void oy_gauss_seidel_2(
    struct Some_variables *E
    )
{
    const int neq = E->lmesh.NEQ;
    const int nno = E->lmesh.NNO;
    
    int *ti = (int *)malloc(3* nno * sizeof(int));
    int *ti_tally = (int *)malloc(3 * nno * sizeof(int));
    for (int i = 1; i <= nno; i++) {
        ti[i - 1] = 0;
        ti_tally[i - 1] = 0;
    }
    
    int *back = ti;
    
    int *temp = (int *)malloc((neq+1)*sizeof(int));
    int *temp_pre = (int *)malloc((neq+1)*sizeof(int));
    int *temp_post = (int *)malloc((neq+1)*sizeof(int));
    for (int i = 0; i <= neq; ++i) {
        temp[i] = 0;                   /* uninit */
        temp_pre[i] = 0;
        temp_post[i] = 0;
    }
    
    FILE *dot = fopen("gs2.dot", "w");
    
    fprintf(dot,
            "digraph G {\n"
            "    node [shape=box];\n\n");
    
    // job1[label="Job #1"];
    const int DOT_MIN = 270;
    const int DOT_MAX = 300;
    
    for (int i = 0; i <= neq && DOT_MIN <= i && i < DOT_MAX; ++i) {
        fprintf(dot, "    Ad_%d_0[label=\"Ad[%d]\"];\n", i, i);
    }
    int *Ad = (int *)malloc((neq+1)*sizeof(int));
    for (int i = 0; i <= neq; ++i) {
        Ad[i] = 0;
    }
    
    for (int i = 0; i <= neq && DOT_MIN <= i && i < DOT_MAX; ++i) {
        fprintf(dot, "    temp_%d_0[label=\"temp[%d]\"];\n", i, i);
    }
    for (int i = 1; i <= nno; i++) {
        int eqn1 = E->ID[i].doff[1];
        int eqn2 = E->ID[i].doff[2];
        int eqn3 = E->ID[i].doff[3];
        if (eqn3 < DOT_MIN || DOT_MAX <= eqn3) {
            continue;
        }
        if (!(E->NODE[i] & OFFSIDE)) {
            fprintf(dot, "    temp_%d_offside[label=\"temp[%d] OFFSIDE\"];\n", eqn1, eqn1);
            fprintf(dot, "    temp_%d_offside[label=\"temp[%d] OFFSIDE\"];\n", eqn2, eqn2);
            fprintf(dot, "    temp_%d_offside[label=\"temp[%d] OFFSIDE\"];\n", eqn3, eqn3);
        }
    }
    for (int j = 3; j < MAX_EQN; j++) {
        fprintf(dot, "    B1_%d_UU[label=\"B1[%d]*UU\"];\n", j, j);
        fprintf(dot, "    B2_%d_UU[label=\"B2[%d]*UU\"];\n", j, j);
        fprintf(dot, "    B3_%d_UU[label=\"B3[%d]*UU\"];\n", j, j);
    }
    fprintf(dot, "\n");
    
    for (int i = 1; i <= nno; i++) {
            
        int eqn1 = E->ID[i].doff[1];
        int eqn2 = E->ID[i].doff[2];
        int eqn3 = E->ID[i].doff[3];
            
        int *C = E->Node_map + (i-1)*MAX_EQN;
            
        //fprintf(stderr, "@@@ read: ");
        for (int j = 3; j < MAX_EQN; j++) {
            //double UU = E->temp[C[j]];
            //fprintf(stderr, "%d ", C[j]);
            
            /***
             *  This may read 'temp' elements which are not written by
             *  the OFFSIDE code below.  BUT, if a temp element IS
             *  written by the OFFSIDE code, the read here follows the
             *  write.
             */
            
            if (C[j] < DOT_MIN || DOT_MAX <= C[j]) {
            } else if (temp_pre[C[j]] || temp_post[C[j]]) {
                /* edge already written */
            } else if (temp[C[j]]) {
                /* offside value */
                fprintf(dot, "    temp_%d_offside->B1_%d_UU;\n", C[j], j);
            } else {
                /* original value */
                fprintf(dot, "    temp_%d_0->B1_%d_UU;\n", C[j], j);
            }
            if (temp[C[j]]) {
                /* already written */
                ++temp_post[C[j]];
            } else {
                ++temp_pre[C[j]];
            }
            for (int *x = ti; x < back; ++x) {
                if (C[j] == *x) {
                    int tallyho = x - ti;
                    ++ti_tally[tallyho];
                }
            }
            /*
              double UU = E->temp[C[j]];
              Ad[eqn1] += B1[j]*UU;
              Ad[eqn2] += B2[j]*UU;
              Ad[eqn3] += B3[j]*UU;
            */
            if (DOT_MIN <= eqn3 && eqn3 < DOT_MAX) {
                fprintf(dot, "    Ad_%d_%d[label=\"Ad[%d]\"];\n", eqn1, Ad[eqn1] + 1, eqn1);
                fprintf(dot, "    Ad_%d_%d[label=\"Ad[%d]\"];\n", eqn2, Ad[eqn2] + 1, eqn2);
                fprintf(dot, "    Ad_%d_%d[label=\"Ad[%d]\"];\n", eqn3, Ad[eqn3] + 1, eqn3);
                fprintf(dot, "    Ad_%d_%d->Ad_%d_%d;\n", eqn1, Ad[eqn1], eqn1, Ad[eqn1] + 1);
                fprintf(dot, "    Ad_%d_%d->Ad_%d_%d;\n", eqn2, Ad[eqn2], eqn2, Ad[eqn2] + 1);
                fprintf(dot, "    Ad_%d_%d->Ad_%d_%d;\n", eqn3, Ad[eqn3], eqn3, Ad[eqn3] + 1);
                fprintf(dot, "    B1_%d_UU->Ad_%d_%d;\n", j, eqn1, Ad[eqn1] + 1);
                fprintf(dot, "    B2_%d_UU->Ad_%d_%d;\n", j, eqn2, Ad[eqn2] + 1);
                fprintf(dot, "    B3_%d_UU->Ad_%d_%d;\n", j, eqn3, Ad[eqn3] + 1);
            }
            ++Ad[eqn1];
            ++Ad[eqn2];
            ++Ad[eqn3];
        }
        //fprintf(stderr, "\n");
            
        if (!(E->NODE[i] & OFFSIDE)) {
            fprintf(stderr, "@@@@@@ %d write: %d %d %d\n", i, eqn1, eqn2, eqn3);
            //E->temp[eqn1] = (F[eqn1] - Ad[eqn1])*E->BI[eqn1];
            //E->temp[eqn2] = (F[eqn2] - Ad[eqn2])*E->BI[eqn2];
            //E->temp[eqn3] = (F[eqn3] - Ad[eqn3])*E->BI[eqn3];
            ++temp[eqn1];
            ++temp[eqn2];
            ++temp[eqn3];
            if (i < nno) {
                int next_i = i + 1;
                int *next_C = E->Node_map + (next_i-1)*MAX_EQN;
                int flag1, flag2, flag3;
                flag1 = flag2 = flag3 = 0;
                for (int j = 3; j < MAX_EQN; j++) {
                    if (next_C[j] == eqn1) {
                        flag1 = 1;
                    } else if (next_C[j] == eqn2) {
                        flag2 = 1;
                    } else if (next_C[j] == eqn3) {
                        flag3 = 1;
                    }
                }
                assert(flag1 && flag2 && flag3);
            } else {
                assert(0);
            }
            *back++ = eqn1;
            *back++ = eqn2;
            *back++ = eqn3;
            if (DOT_MIN <= eqn3 && eqn3 < DOT_MAX) {
                fprintf(dot, "    Ad_%d_%d->temp_%d_offside;\n", eqn1, Ad[eqn1], eqn1);
                fprintf(dot, "    Ad_%d_%d->temp_%d_offside;\n", eqn2, Ad[eqn2], eqn2);
                fprintf(dot, "    Ad_%d_%d->temp_%d_offside;\n", eqn3, Ad[eqn3], eqn3);
            }
        }
            
    }
    
    for (int i = 0; i <= neq; ++i) {
        assert(temp[i] <= 1);
        if (temp[i]) {
            fprintf(stderr, "@@@ temp[%d] was written %d times\n", i, temp[i]);
        }
    }
    for (int *x = ti; x < back; ++x) {
        int tallyho = x - ti;
        int eqn = *x;
        assert(temp_pre[eqn] == 0);
        assert(temp_pre[eqn] + temp_post[eqn] == ti_tally[tallyho]);
        fprintf(stderr, "@@@ read tally %d for %d: %d + %d = %d\n", tallyho, eqn,
                temp_pre[eqn], temp_post[eqn], ti_tally[tallyho]);
    }
    
    fprintf(dot, "}\n");
    fclose(dot);
    
}


void piano_roll_gauss_seidel_2(
    struct Some_variables *E
    )
{
    const int neq = E->lmesh.NEQ;
    const int nno = E->lmesh.NNO;
    
    int *roll = (int *)malloc(nno*MAX_EQN*sizeof(int));
    for (int i = 0; i < nno*MAX_EQN; ++i) {
        roll[i] = 0;
    }
    
    int offsideTally = 0;
    
    int *Ad = (int *)malloc((neq+1)*sizeof(int));
    for (int i = 0; i <= neq; ++i) {
        Ad[i] = 0;
    }
    int *temp = (int *)malloc((neq+1)*sizeof(int));
    for (int i = 0; i <= neq; ++i) {
        temp[i] = 0;
    }
    
    for (int i = 1; i <= nno; i++) {
            
        int eqn1 = E->ID[i].doff[1];
        int eqn2 = E->ID[i].doff[2];
        int eqn3 = E->ID[i].doff[3];
            
        int *C = E->Node_map + (i-1)*MAX_EQN;
            
        higher_precision *B1,*B2,*B3;
        B1 = E->Eqn_k[1] + (i-1)*MAX_EQN;
        B2 = E->Eqn_k[2] + (i-1)*MAX_EQN;
        B3 = E->Eqn_k[3] + (i-1)*MAX_EQN;
            
        for (int j = 3; j < MAX_EQN; j++) {
            /*
              double UU = E->temp[C[j]];
              Ad[eqn1] += B1[j]*UU;
              Ad[eqn2] += B2[j]*UU;
              Ad[eqn3] += B3[j]*UU;
            */
            
            int *row = roll + j*nno;
            row[i-1] = eqn1;
            
            Ad[eqn1] = max(Ad[eqn1], temp[C[j]]) + 1;
            Ad[eqn2] = max(Ad[eqn2], temp[C[j]]) + 1;
            Ad[eqn3] = max(Ad[eqn3], temp[C[j]]) + 1;
        }
            
        if (!(E->NODE[i] & OFFSIDE)) {
            ++offsideTally;
            /*
              E->temp[eqn1] = (F[eqn1] - Ad[eqn1])*E->BI[eqn1];
              E->temp[eqn2] = (F[eqn2] - Ad[eqn2])*E->BI[eqn2];
              E->temp[eqn3] = (F[eqn3] - Ad[eqn3])*E->BI[eqn3];
            */
            temp[eqn1] = Ad[eqn1] + 1;
            temp[eqn2] = Ad[eqn2] + 1;
            temp[eqn3] = Ad[eqn3] + 1;
        }
            
    }
    
    fprintf(stderr, "!offside: %d of %d\n", offsideTally, nno);
    int maxAd = 0, maxTemp = 0;
    for (int i = 0; i <= neq; ++i) {
        maxAd = max(maxAd, Ad[i]);
        maxTemp = max(maxTemp, temp[i]);
        fprintf(stderr, "depth[%d]: Ad %d temp %d\n", i, Ad[i], temp[i]);
    }
    fprintf(stderr, "max Ad depth %d\n", maxAd);
    fprintf(stderr, "max temp depth %d\n", maxTemp);
    
    //------------------------------------------------------------------------
    //------------------------------------------------------------------------
    //------------------------------------------------------------------------
    
    
    int *nodes = (int *)malloc(maxAd*sizeof(int));
    for (int i = 0; i < maxAd; ++i) {
        nodes[i] = 0;
    }
    for (int i = 0; i <= neq; ++i) {
        Ad[i] = 0;
        temp[i] = 0;
    }
    
    for (int i = 1; i <= nno; i++) {
            
        int eqn1 = E->ID[i].doff[1];
        int eqn2 = E->ID[i].doff[2];
        int eqn3 = E->ID[i].doff[3];
            
        int *C = E->Node_map + (i-1)*MAX_EQN;
            
        higher_precision *B1,*B2,*B3;
        B1 = E->Eqn_k[1] + (i-1)*MAX_EQN;
        B2 = E->Eqn_k[2] + (i-1)*MAX_EQN;
        B3 = E->Eqn_k[3] + (i-1)*MAX_EQN;
            
        for (int j = 3; j < MAX_EQN; j++) {
            /*
              double UU = E->temp[C[j]];
              Ad[eqn1] += B1[j]*UU;
              Ad[eqn2] += B2[j]*UU;
              Ad[eqn3] += B3[j]*UU;
            */
            
            int *row = roll + j*nno;
            row[i-1] = eqn1;
            
            Ad[eqn1] = max(Ad[eqn1], temp[C[j]]) + 1;
            Ad[eqn2] = max(Ad[eqn2], temp[C[j]]) + 1;
            Ad[eqn3] = max(Ad[eqn3], temp[C[j]]) + 1;
            ++nodes[Ad[eqn1]];
            ++nodes[Ad[eqn2]];
            ++nodes[Ad[eqn3]];
        }
            
        if (!(E->NODE[i] & OFFSIDE)) {
            ++offsideTally;
            /*
              E->temp[eqn1] = (F[eqn1] - Ad[eqn1])*E->BI[eqn1];
              E->temp[eqn2] = (F[eqn2] - Ad[eqn2])*E->BI[eqn2];
              E->temp[eqn3] = (F[eqn3] - Ad[eqn3])*E->BI[eqn3];
            */
            temp[eqn1] = Ad[eqn1] + 1;
            temp[eqn2] = Ad[eqn2] + 1;
            temp[eqn3] = Ad[eqn3] + 1;
            ++nodes[temp[eqn1]];
            ++nodes[temp[eqn2]];
            ++nodes[temp[eqn3]];
        }
            
    }
    for (int i = 0; i <= neq; ++i) {
        if (!Ad[i]) ++nodes[0];
        if (!temp[i]) ++nodes[0];
    }
    
    int nodeTally = 0;
    for (int i = 0; i < maxAd; ++i) {
        fprintf(stderr, "nodes at depth %03d %d\n", i, nodes[i]);
        nodeTally += nodes[i];
    }
    fprintf(stderr, "total nodes: %d\n", nodeTally);
        
    if (0) for (int j = 3; j < MAX_EQN; j++) {
        int *row = roll + j*nno;
        fprintf(stderr, "row %d: ", j);
        for (int i = 1; i <= nno; i++) {
            fprintf(stderr, "%d ", row[i-1]);
        }
        fprintf(stderr, "\n");
    }
}


extern "C" void gauss_seidel(
    struct All_variables *E,
    double **d0,
    double **F, double **Ad,
    double acc,
    int *cycles,
    int level,
    int guess
    )
{
    struct Some_variables kE;
    
    assert_assumptions(E, level);
    
    /* initialize 'Some_variables' with 'All_variables' */
    
    kE.num_zero_resid = E->num_zero_resid[level][M];
    kE.zero_resid = E->zero_resid[level][M];
    
    kE.lmesh.NEQ = E->lmesh.NEQ[level];
    kE.lmesh.NNO = E->lmesh.NNO[level];
    
    kE.ID    = E->ID[level][M];
    
    kE.Eqn_k[0] = 0;
    kE.Eqn_k[1] = E->Eqn_k1[level][M];
    kE.Eqn_k[2] = E->Eqn_k2[level][M];
    kE.Eqn_k[3] = E->Eqn_k3[level][M];
    kE.Node_map = E->Node_map[level][M];
    
    kE.BI = E->BI[level][M];
    
    kE.temp = E->temp[M];
    
    kE.NODE = E->NODE[level][M];
    
    collect_terms(&kE);
    if (0) oy_gauss_seidel_2(&kE);
    piano_roll_gauss_seidel_2(&kE);
    assert(0);
    
    do_gauss_seidel(
        &kE,
        d0[M],
        F[M], Ad[M],
        acc,
        cycles,
        guess
        );
}



/*------------------------------------------------------------------------*/
/*------------------------------------------------------------------------*/
/*------------------------------------------------------------------------*/

void host_strip_bcs_from_residual(
    struct Some_variables *E,
    double *Res
    )
{
    for(int i = 1; i <= E->num_zero_resid; i++)
        Res[E->zero_resid[i]] = 0.0;
}


void host_n_assemble_del2_u(
    struct Some_variables *E,
    double *d_u, double *d_Au,
    int strip_bcs
    )
{
    cudaThreadSynchronize();
    
    const int neq = E->lmesh.NEQ;
    const int nno = E->lmesh.NNO;
    
    double *u = (double *)malloc((1+neq)*sizeof(double));
    cudaMemcpy(u, d_u, (1+neq)*sizeof(double), cudaMemcpyDeviceToHost);
    
    double *Au = (double *)malloc((1+neq)*sizeof(double));
    
    for (int e = 0; e <= neq; e++) {
        Au[e] = 0.0;
    }
    
    u[neq] = 0.0;
    
    for (int e = 1; e <= nno; e++) {
        
        int eqn1 = E->ID[e].doff[1];
        int eqn2 = E->ID[e].doff[2];
        int eqn3 = E->ID[e].doff[3];
        
        double U1 = u[eqn1];
        double U2 = u[eqn2];
        double U3 = u[eqn3];
        
        int *C = E->Node_map + (e-1)*MAX_EQN;
        
        higher_precision *B1,*B2,*B3;
        B1 = E->Eqn_k[1] + (e-1)*MAX_EQN;
        B2 = E->Eqn_k[2] + (e-1)*MAX_EQN;
        B3 = E->Eqn_k[3] + (e-1)*MAX_EQN;
        
        for (int i = 3; i < MAX_EQN; i++)  {
            double UU = u[C[i]];
            Au[eqn1] += B1[i]*UU;
            Au[eqn2] += B2[i]*UU;
            Au[eqn3] += B3[i]*UU;
        }
        for (int i = 0; i < MAX_EQN; i++) {
            Au[C[i]] += B1[i]*U1 +
                        B2[i]*U2 +
                        B3[i]*U3;
        }
    }
    
    if (strip_bcs)
        host_strip_bcs_from_residual(E,Au);
    
    cudaMemcpy(d_Au, Au, (1+neq)*sizeof(double), cudaMemcpyHostToDevice);
    
    free(u);
    free(Au);
    
    return;
}


void host_gauss_seidel_0(
    struct Some_variables *E,
    double *d_d0,
    double *d_Ad
    )
{
    cudaThreadSynchronize();
    
    const int neq = E->lmesh.NEQ;
    
    double *d0 = (double *)malloc((1+neq)*sizeof(double));
    double *Ad = (double *)malloc((1+neq)*sizeof(double));
    
    const double zeroo = 0.0;
    
    for (int i = 0; i < neq; i++) {
        d0[i] = Ad[i] = zeroo;
    }
    
    cudaMemcpy(d_d0, d0, (1+neq)*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(d_Ad, Ad, (1+neq)*sizeof(double), cudaMemcpyHostToDevice);
    
    free(d0);
    free(Ad);
}


void host_gauss_seidel_1(
    struct Some_variables *E,
    struct Some_variables *s_E,
    double *d_F, double *d_Ad
    )
{
    cudaThreadSynchronize();
    
    const int neq = E->lmesh.NEQ;
    const int nno = E->lmesh.NNO;
    
    double *F = (double *)malloc(neq*sizeof(double));
    cudaMemcpy(F, d_F, neq*sizeof(double), cudaMemcpyDeviceToHost);
    
    double *Ad = (double *)malloc((1+neq)*sizeof(double));
    cudaMemcpy(Ad, d_Ad, (1+neq)*sizeof(double), cudaMemcpyDeviceToHost);
    
    const double zeroo = 0.0;
    
    for (int j = 0; j <= neq; j++) {
        E->temp[j] = zeroo;
    }
    
    Ad[neq] = zeroo;
    
    for (int i = 1; i <= nno; i++) {
        if (E->NODE[i] & OFFSIDE) {
            int eqn1 = E->ID[i].doff[1];
            int eqn2 = E->ID[i].doff[2];
            int eqn3 = E->ID[i].doff[3];
            E->temp[eqn1] = (F[eqn1] - Ad[eqn1])*E->BI[eqn1];
            E->temp[eqn2] = (F[eqn2] - Ad[eqn2])*E->BI[eqn2];
            E->temp[eqn3] = (F[eqn3] - Ad[eqn3])*E->BI[eqn3];
        }
    }
    
    /* Ad[neq] */
    cudaMemcpy(d_Ad + neq, Ad + neq, sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(s_E->temp, E->temp, (neq+1)*sizeof(double), cudaMemcpyHostToDevice);
    
    free(F);
    free(Ad);
}


void host_gauss_seidel_2(
    struct Some_variables *E,
    struct Some_variables *s_E,
    double *d_F, double *d_Ad
    )
{
    cudaThreadSynchronize();
    
    const int neq = E->lmesh.NEQ;
    const int nno = E->lmesh.NNO;
    
    double *F = (double *)malloc(neq*sizeof(double));
    cudaMemcpy(F, d_F, neq*sizeof(double), cudaMemcpyDeviceToHost);
    
    double *Ad = (double *)malloc((1+neq)*sizeof(double));
    cudaMemcpy(Ad, d_Ad, (1+neq)*sizeof(double), cudaMemcpyDeviceToHost);
    
    cudaMemcpy(E->temp, s_E->temp, (neq+1)*sizeof(double), cudaMemcpyDeviceToHost);
    
    for (int i = 1; i <= nno; i++) {
            
        int eqn1 = E->ID[i].doff[1];
        int eqn2 = E->ID[i].doff[2];
        int eqn3 = E->ID[i].doff[3];
            
        int *C = E->Node_map + (i-1)*MAX_EQN;
            
        higher_precision *B1,*B2,*B3;
        B1 = E->Eqn_k[1] + (i-1)*MAX_EQN;
        B2 = E->Eqn_k[2] + (i-1)*MAX_EQN;
        B3 = E->Eqn_k[3] + (i-1)*MAX_EQN;
            
        /* Ad on boundaries differs after the following operation, but
           no communications are needed yet, because boundary Ad will
           not be used for the G-S iterations for interior nodes */
            
        for (int j = 3; j < MAX_EQN; j++) {
            double UU = E->temp[C[j]];
            Ad[eqn1] += B1[j]*UU;
            Ad[eqn2] += B2[j]*UU;
            Ad[eqn3] += B3[j]*UU;
        }
            
        if (!(E->NODE[i] & OFFSIDE)) {
            E->temp[eqn1] = (F[eqn1] - Ad[eqn1])*E->BI[eqn1];
            E->temp[eqn2] = (F[eqn2] - Ad[eqn2])*E->BI[eqn2];
            E->temp[eqn3] = (F[eqn3] - Ad[eqn3])*E->BI[eqn3];
        }
            
    }
            
    cudaMemcpy(d_Ad, Ad, (1+neq)*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(s_E->temp, E->temp, (neq+1)*sizeof(double), cudaMemcpyHostToDevice);
    
    free(F);
    free(Ad);
}


void host_gauss_seidel_3(
    struct Some_variables *E,
    struct Some_variables *s_E,
    double *d_d0,
    double *d_Ad
    )
{
    cudaThreadSynchronize();
    
    const int neq = E->lmesh.NEQ;
    const int nno = E->lmesh.NNO;
    
    double *d0 = (double *)malloc((1+neq)*sizeof(double));
    double *Ad = (double *)malloc((1+neq)*sizeof(double));
    
    cudaMemcpy(d0, d_d0, (1+neq)*sizeof(double), cudaMemcpyDeviceToHost);
    cudaMemcpy(Ad, d_Ad, (1+neq)*sizeof(double), cudaMemcpyDeviceToHost);
    cudaMemcpy(E->temp, s_E->temp, (neq+1)*sizeof(double), cudaMemcpyDeviceToHost);
    
    for (int i = 1; i <= nno; i++) {
            
        int eqn1 = E->ID[i].doff[1];
        int eqn2 = E->ID[i].doff[2];
        int eqn3 = E->ID[i].doff[3];
            
        int *C = E->Node_map + (i-1)*MAX_EQN;
            
        higher_precision *B1,*B2,*B3;
        B1 = E->Eqn_k[1] + (i-1)*MAX_EQN;
        B2 = E->Eqn_k[2] + (i-1)*MAX_EQN;
        B3 = E->Eqn_k[3] + (i-1)*MAX_EQN;
            
        /* Ad on boundaries differs after the following operation */
        for (int j = 0; j < MAX_EQN; j++) {
            Ad[C[j]] += B1[j]*E->temp[eqn1] +
                        B2[j]*E->temp[eqn2] +
                        B3[j]*E->temp[eqn3];
        }
            
        d0[eqn1] += E->temp[eqn1];
        d0[eqn2] += E->temp[eqn2];
        d0[eqn3] += E->temp[eqn3];
            
    }
    
    cudaMemcpy(d_d0, d0, (1+neq)*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(d_Ad, Ad, (1+neq)*sizeof(double), cudaMemcpyHostToDevice);
    
    free(d0);
    free(Ad);
}