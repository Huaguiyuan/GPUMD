/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/


#include "common.cuh"
#include "mic.cuh"
#include "pair.cuh"



// best block size here: 128
#define BLOCK_SIZE_FORCE 128

#ifdef USE_DP
    #define RI_ALPHA     0.2
    #define RI_ALPHA_SQ  0.04
    #define RI_PI_FACTOR 0.225675833419103 // ALPHA * 2 / SQRT(PI)  
#else
    #define RI_ALPHA     0.2f
    #define RI_ALPHA_SQ  0.04f
    #define RI_PI_FACTOR 0.225675833419103f // ALPHA * 2 / SQRT(PI) 
#endif




Pair::Pair(FILE *fid, Parameters *para, int potential_model_input)
{
    potential_model = potential_model_input;
    if (potential_model == 0) initialize_ri(fid);
    if (potential_model >= 1 && potential_model <= 5) 
        initialize_lj(fid, potential_model);
}




void Pair::initialize_lj(FILE *fid, int N)
{
    printf("INPUT: use %d-element LJ potential.\n", N);
    double epsilon, sigma, cutoff;
    rc = 0.0;
    for (int n = 0; n < N; n++)
    {
        for (int m = 0; m < N; m++)
        {
            int count = fscanf(fid, "%lf%lf%lf", &epsilon, &sigma, &cutoff);
            if (count!=3) 
            {print_error("reading error for potential file.\n");exit(1);}
            lj_para.s6e4[n][m]   = pow(sigma, 6.0)  * epsilon * 4.0;
            lj_para.s12e4[n][m]  = pow(sigma, 12.0) * epsilon * 4.0;
            lj_para.cutoff_square[n][m] = cutoff * cutoff;
            if (rc < cutoff) rc = cutoff;
        }
    }
}




void Pair::initialize_ri(FILE *fid)
{
    printf("INPUT: use the rigid-ion potential.\n");
    double x[4][3];
    for (int n = 0; n < 4; n++)
    {
        int count = fscanf(fid, "%lf%lf%lf", &x[n][0], &x[n][1], &x[n][2]);
        if (count != 3)
        {print_error("reading error for potential.in.\n"); exit(1);}
    }
    ri_para.cutoff = x[0][2];
    ri_para.qq11   = x[0][0] * x[0][0] * K_C;
    ri_para.qq22   = x[0][1] * x[0][1] * K_C;
    ri_para.qq12   = x[0][0] * x[0][1] * K_C;
    ri_para.a11    = x[1][0];
    ri_para.b11    = x[1][1];
    ri_para.c11    = x[1][2];
    ri_para.a22    = x[2][0];
    ri_para.b22    = x[2][1];
    ri_para.c22    = x[2][2];
    ri_para.a12    = x[3][0];
    ri_para.b12    = x[3][1];
    ri_para.c12    = x[3][2];
    ri_para.b11 = ONE / ri_para.b11;
    ri_para.b22 = ONE / ri_para.b22;
    ri_para.b12 = ONE / ri_para.b12;

    rc = ri_para.cutoff; // force cutoff

    ri_para.v_rc = erfc(RI_ALPHA * rc) / rc;
    ri_para.dv_rc = -erfc(RI_ALPHA * rc) / (rc * rc);
    ri_para.dv_rc -= RI_PI_FACTOR * exp(-RI_ALPHA_SQ * rc * rc) / rc;
}




Pair::~Pair(void)
{
    // nothing
}




// get U_ij and (d U_ij / d r_ij) / r_ij (the LJ potential)
static __device__ void find_p2_and_f2
(real s6e4, real s12e4, real d12sq, real &p2, real &f2)
{
    real d12inv2 = ONE / d12sq;
    real d12inv6 = d12inv2 * d12inv2 * d12inv2;  
    f2 = SIX * (s6e4 * d12inv6 - s12e4 * TWO * d12inv6 * d12inv6) * d12inv2; 
    p2 = s12e4 * d12inv6 * d12inv6 - s6e4 * d12inv6;  
}




// get U_ij and (d U_ij / d r_ij) / r_ij (the RI potential)
static __device__ void find_p2_and_f2
(int type1, int type2, RI_Para ri, real d12sq, real &p2, real &f2)
{
    real a, b, c, qq; 
    if (type1 == 0 && type2 == 0)
    {
        a  = ri.a11; 
        b  = ri.b11; 
        c  = ri.c11; 
        qq = ri.qq11;
    }
    else if (type1 == 1 && type2 == 1)
    {
        a  = ri.a22; 
        b  = ri.b22; 
        c  = ri.c22; 
        qq = ri.qq22;
    }  
    else 
    {
        a  = ri.a12; 
        b  = ri.b12; 
        c  = ri.c12; 
        qq = ri.qq12;
    }  

    real d12         = sqrt(d12sq); 
    real d12inv      = ONE / d12;   
    real d12inv3     = d12inv * d12inv * d12inv; 
    real exponential = exp(-d12 * b);     // b = 1/rho
    real erfc_r = erfc(RI_ALPHA * d12) * d12inv;
    p2 = a * exponential - c * d12inv3 * d12inv3;
    p2 += qq * ( erfc_r - ri.v_rc - ri.dv_rc * (d12 - ri.cutoff) );
    f2 = SIX*c*(d12inv3*d12inv3*d12inv) - a*exponential*b;
    f2-=qq*(erfc_r*d12inv+RI_PI_FACTOR*d12inv*exp(-RI_ALPHA_SQ*d12sq)+ri.dv_rc);
    f2 *= d12inv;
}




// force evaluation kernel
template <int potential_model, int cal_p, int cal_j, int cal_q>
static __global__ void gpu_find_force
(
    LJ_Para lj, RI_Para ri,
    int number_of_particles, int pbc_x, int pbc_y, int pbc_z,
    int *g_neighbor_number, int *g_neighbor_list, int *g_type,
#ifdef USE_LDG
    const real* __restrict__ g_x, 
    const real* __restrict__ g_y, 
    const real* __restrict__ g_z, 
    const real* __restrict__ g_vx, 
    const real* __restrict__ g_vy, 
    const real* __restrict__ g_vz,
#else
    real *g_x,  real *g_y,  real *g_z, real *g_vx, real *g_vy, real *g_vz,
#endif
    real *g_box, real *g_fx, real *g_fy, real *g_fz,
    real *g_sx, real *g_sy, real *g_sz, real *g_potential, 
    real *g_h, int *g_label, int *g_fv_index, real *g_fv 
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x; // particle index

    __shared__ real s_fx[BLOCK_SIZE_FORCE];
    __shared__ real s_fy[BLOCK_SIZE_FORCE];
    __shared__ real s_fz[BLOCK_SIZE_FORCE];
    // if cal_p, then s1~s4 = px, py, pz, U; if cal_j, then s1~s5 = j1~j5
    __shared__ real s1[BLOCK_SIZE_FORCE];
    __shared__ real s2[BLOCK_SIZE_FORCE];
    __shared__ real s3[BLOCK_SIZE_FORCE];
    __shared__ real s4[BLOCK_SIZE_FORCE];
    __shared__ real s5[BLOCK_SIZE_FORCE];

    s_fx[threadIdx.x] = ZERO; 
    s_fy[threadIdx.x] = ZERO; 
    s_fz[threadIdx.x] = ZERO;  
    s1[threadIdx.x] = ZERO; 
    s2[threadIdx.x] = ZERO; 
    s3[threadIdx.x] = ZERO;
    s4[threadIdx.x] = ZERO;
    s5[threadIdx.x] = ZERO;

    if (n1 < number_of_particles)
    {
        int neighbor_number = g_neighbor_number[n1];
        int type1 = g_type[n1];
        real x1 = LDG(g_x, n1); 
        real y1 = LDG(g_y, n1); 
        real z1 = LDG(g_z, n1);
        real vx1 = LDG(g_vx, n1); 
        real vy1 = LDG(g_vy, n1); 
        real vz1 = LDG(g_vz, n1);
        real lx = g_box[0]; 
        real ly = g_box[1]; 
        real lz = g_box[2];

        for (int i1 = 0; i1 < neighbor_number; ++i1)
        {   
            int n2 = g_neighbor_list[n1 + number_of_particles * i1];
            int type2 = g_type[n2];

            real x12  = LDG(g_x, n2) - x1;
            real y12  = LDG(g_y, n2) - y1;
            real z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(pbc_x, pbc_y, pbc_z, x12, y12, z12, lx, ly, lz);
            real d12sq = x12 * x12 + y12 * y12 + z12 * z12;

            real p2, f2;

            // RI
            if (potential_model == 0)
            {
                if (d12sq >= ri.cutoff * ri.cutoff) {continue;}
                find_p2_and_f2(type1, type2, ri, d12sq, p2, f2);
            } 

            // LJ1-LJ5
            if (potential_model >= 1 && potential_model <= 5)
            {
                if (d12sq >= lj.cutoff_square[type1][type2]) {continue;}
                find_p2_and_f2
                (lj.s6e4[type1][type2], lj.s12e4[type1][type2], d12sq, p2, f2);
            }

            // treat two-body potential in the same way as many-body potential
            real f12x = f2 * x12 * HALF; 
            real f12y = f2 * y12 * HALF; 
            real f12z = f2 * z12 * HALF; 
            real f21x = -f12x; 
            real f21y = -f12y; 
            real f21z = -f12z; 
       
            // accumulate force
            s_fx[threadIdx.x] += f12x - f21x; 
            s_fy[threadIdx.x] += f12y - f21y; 
            s_fz[threadIdx.x] += f12z - f21z; 
            
            // accumulate potential energy and virial
            if (cal_p) 
            {
                s4[threadIdx.x] += p2 * HALF; // two-body potential
                s1[threadIdx.x] -= x12 * (f12x - f21x) * HALF; 
                s2[threadIdx.x] -= y12 * (f12y - f21y) * HALF; 
                s3[threadIdx.x] -= z12 * (f12z - f21z) * HALF;
            }
            
            // heat current (EMD)
            if (cal_j) 
            {
                s1[threadIdx.x] += (f21x * vx1 + f21y * vy1) * x12;  // x-in
                s2[threadIdx.x] += (f21z * vz1) * x12;               // x-out
                s3[threadIdx.x] += (f21x * vx1 + f21y * vy1) * y12;  // y-in
                s4[threadIdx.x] += (f21z * vz1) * y12;               // y-out
                s5[threadIdx.x] += (f21x*vx1+f21y*vy1+f21z*vz1)*z12; // z-all
            } 

            // heat across some section (NEMD)
            if (cal_q) 
            {
                int index_12 = g_fv_index[n1] * 12;
                if (index_12 >= 0 && g_fv_index[n1 + number_of_particles] == n2)
                {
                    g_fv[index_12 + 0]  += f12x;
                    g_fv[index_12 + 1]  += f12y;
                    g_fv[index_12 + 2]  += f12z;
                    g_fv[index_12 + 3]  += f21x;
                    g_fv[index_12 + 4]  += f21y;
                    g_fv[index_12 + 5]  += f21z;
                    g_fv[index_12 + 6]  += vx1;
                    g_fv[index_12 + 7]  += vy1;
                    g_fv[index_12 + 8]  += vz1;
                    g_fv[index_12 + 9]  += LDG(g_vx, n2);
                    g_fv[index_12 + 10] += LDG(g_vy, n2);
                    g_fv[index_12 + 11] += LDG(g_vz, n2);
                }  
            }
        }

        // save force
        g_fx[n1] += s_fx[threadIdx.x]; 
        g_fy[n1] += s_fy[threadIdx.x]; 
        g_fz[n1] += s_fz[threadIdx.x]; 

        // save stress and potential
        if (cal_p) 
        {
            g_sx[n1] += s1[threadIdx.x]; 
            g_sy[n1] += s2[threadIdx.x]; 
            g_sz[n1] += s3[threadIdx.x];
            g_potential[n1] += s4[threadIdx.x];
        }

        // save heat current
        if (cal_j) 
        {
            g_h[n1 + 0 * number_of_particles] += s1[threadIdx.x];
            g_h[n1 + 1 * number_of_particles] += s2[threadIdx.x];
            g_h[n1 + 2 * number_of_particles] += s3[threadIdx.x];
            g_h[n1 + 3 * number_of_particles] += s4[threadIdx.x];
            g_h[n1 + 4 * number_of_particles] += s5[threadIdx.x];
        }
    }
}    
 



// Find force and related quantities for pair potentials (A wrapper)
void Pair::compute(Parameters *para, GPU_Data *gpu_data)
{
    int N = para->N;
    int grid_size = (N - 1) / BLOCK_SIZE_FORCE + 1;
    int pbc_x = para->pbc_x;
    int pbc_y = para->pbc_y;
    int pbc_z = para->pbc_z;
    int *NN = gpu_data->NN_local;
    int *NL = gpu_data->NL_local;
    int *type = gpu_data->type;
    real *x = gpu_data->x; 
    real *y = gpu_data->y; 
    real *z = gpu_data->z;
    real *vx = gpu_data->vx; 
    real *vy = gpu_data->vy; 
    real *vz = gpu_data->vz;
    real *fx = gpu_data->fx; 
    real *fy = gpu_data->fy; 
    real *fz = gpu_data->fz;
    real *box = gpu_data->box_length;
    real *sx = gpu_data->virial_per_atom_x; 
    real *sy = gpu_data->virial_per_atom_y; 
    real *sz = gpu_data->virial_per_atom_z; 
    real *pe = gpu_data->potential_per_atom;
    real *h = gpu_data->heat_per_atom; 
    
    int *label = gpu_data->label;
    int *fv_index = gpu_data->fv_index;
    real *fv = gpu_data->fv;


    if (potential_model == 0) // RI
    {
           
        if (para->hac.compute)    
        {
            gpu_find_force<0, 0, 1, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else if (para->shc.compute)
        {
            gpu_find_force<0, 0, 0, 1><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force<0, 1, 0, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
    }

    if (potential_model == 1) // LJ1
    {
           
        if (para->hac.compute)    
        {
            gpu_find_force<1, 0, 1, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else if (para->shc.compute)
        {
            gpu_find_force<1, 0, 0, 1><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force<1, 1, 0, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
    }

    if (potential_model == 2) // LJ2
    {
           
        if (para->hac.compute)    
        {
            gpu_find_force<2, 0, 1, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else if (para->shc.compute)
        {
            gpu_find_force<2, 0, 0, 1><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force<2, 1, 0, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
    }

    if (potential_model == 3) // LJ3
    {
           
        if (para->hac.compute)    
        {
            gpu_find_force<3, 0, 1, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else if (para->shc.compute)
        {
            gpu_find_force<3, 0, 0, 1><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force<3, 1, 0, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
    }

    if (potential_model == 4) // LJ4
    {
           
        if (para->hac.compute)    
        {
            gpu_find_force<4, 0, 1, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else if (para->shc.compute)
        {
            gpu_find_force<4, 0, 0, 1><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force<4, 1, 0, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
    }

    if (potential_model == 5) // LJ5
    {
           
        if (para->hac.compute)    
        {
            gpu_find_force<5, 0, 1, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else if (para->shc.compute)
        {
            gpu_find_force<5, 0, 0, 1><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force<5, 1, 0, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
            (
                lj_para, ri_para,
                N, pbc_x, pbc_y, pbc_z, NN, NL, type, x, y, z, vx, vy, vz, box,
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
    }

    #ifdef DEBUG
        CHECK(cudaDeviceSynchronize());
        CHECK(cudaGetLastError());
    #endif
}




