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
#include "vac.cuh"


// Allocate memory for recording velocity data
void preprocess_vac(Parameters *para, CPU_Data *cpu_data, GPU_Data *gpu_data)
{
    if (para->vac.compute)
    {
        int num = para->N * para->number_of_steps / para->vac.sample_interval;
        CHECK(cudaMalloc((void**)&gpu_data->vx_all, sizeof(real) * num));
        CHECK(cudaMalloc((void**)&gpu_data->vy_all, sizeof(real) * num));
        CHECK(cudaMalloc((void**)&gpu_data->vz_all, sizeof(real) * num));
    }
}


// Record velocity data (kernel)
static __global__ void gpu_copy_velocity
(
    int N, int nd, real *g_in_x, real *g_in_y, real *g_in_z, 
    real *g_out_x, real *g_out_y, real *g_out_z
)
{
    int n = blockIdx.x * blockDim.x + threadIdx.x; // atom index
    if (n < N)
    {
        int m = nd * N + n;
        g_out_x[m] = g_in_x[n];
        g_out_y[m] = g_in_y[n];
        g_out_z[m] = g_in_z[n];
    }
}


// Record velocity data (wrapper)
void sample_vac
(int step, Parameters *para, CPU_Data *cpu_data,GPU_Data *gpu_data)
{
    if (para->vac.compute)
    {     
        if (step % para->vac.sample_interval == 0)
        { 
            int N = para->N;
            int nd = step / para->vac.sample_interval;
            
            int grid_size = (N - 1) / BLOCK_SIZE + 1;
            gpu_copy_velocity<<<grid_size, BLOCK_SIZE>>>
            (
                N, nd, gpu_data->vx, gpu_data->vy, gpu_data->vz, 
                gpu_data->vx_all, gpu_data->vy_all, gpu_data->vz_all
            );
            CHECK(cudaDeviceSynchronize());
            CHECK(cudaGetLastError());
        }
    }
}


// Calculate the velocity auto-correlation (VAC)
static __device__ void warp_reduce(volatile real *s, int t) 
{
    s[t] += s[t + 32]; s[t] += s[t + 16]; s[t] += s[t + 8];
    s[t] += s[t + 4];  s[t] += s[t + 2];  s[t] += s[t + 1];
}


static __global__ void gpu_find_vac
(
    int N, int M, real *g_vx, real *g_vy, real *g_vz, 
    real *g_vac_x, real *g_vac_y, real *g_vac_z
)
{
    //<<<Nc, 128>>>

    __shared__ real s_vac_x[128];
    __shared__ real s_vac_y[128];
    __shared__ real s_vac_z[128];

    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int number_of_patches = (N - 1) / 128 + 1;  

    s_vac_x[tid] = 0.0;  
    s_vac_y[tid] = 0.0;
    s_vac_z[tid] = 0.0;

    for (int m = 0; m < M; ++m)
    {
        int index_1 = m * N;
        int index_2 = (m + bid) * N;
        for (int patch = 0; patch < number_of_patches; ++patch)
        { 
            int n = tid + patch * 128;
            if (n < N)
            {
                s_vac_x[tid] += g_vx[index_1 + n] * g_vx[index_2 + n];
                s_vac_y[tid] += g_vy[index_1 + n] * g_vy[index_2 + n];
                s_vac_z[tid] += g_vz[index_1 + n] * g_vz[index_2 + n];  
            }
        }
    }
    __syncthreads();

    if (tid < 64)
    {
        s_vac_x[tid] += s_vac_x[tid + 64];
        s_vac_y[tid] += s_vac_y[tid + 64];
        s_vac_z[tid] += s_vac_z[tid + 64];
    }
    __syncthreads();
 
    if (tid < 32)
    {
        warp_reduce(s_vac_x, tid);
        warp_reduce(s_vac_y, tid);
        warp_reduce(s_vac_z, tid); 
    }
   
    if (tid == 0)
    {
        int number_of_data = M * N;
        g_vac_x[bid] = s_vac_x[0] / number_of_data;
        g_vac_y[bid] = s_vac_y[0] / number_of_data;
        g_vac_z[bid] = s_vac_z[0] / number_of_data;
    }
}


// Calculate the Running Diffusion Constant (RDC) 
// from the VAC using the Green-Kubo formula
static void find_rdc
(
    int Nc, real dt, real *vac_x, real *vac_y, real *vac_z, 
    real *rdc_x, real *rdc_y, real *rdc_z
)
{
    real dt2 = dt * 0.5;
    for (int nc = 1; nc < Nc; nc++)  
    {
        rdc_x[nc] = rdc_x[nc - 1] + (vac_x[nc - 1] + vac_x[nc]) * dt2;
        rdc_y[nc] = rdc_y[nc - 1] + (vac_y[nc - 1] + vac_y[nc]) * dt2;
        rdc_z[nc] = rdc_z[nc - 1] + (vac_z[nc - 1] + vac_z[nc]) * dt2;
    }
}


// Calculate phonon density of states (DOS) 
// using the method by Dickey and Paskin
static void find_dos
(
    int Nc,
    real delta_t, 
    real omega_0,
    real d_omega,
    real *vac_x_normalized, 
    real *vac_y_normalized, 
    real *vac_z_normalized,
    real *dos_x, 
    real *dos_y, 
    real *dos_z
)
{
    // Apply Hann window and normalize by the correct factor
    for (int nc = 0; nc < Nc; nc++)
    {
        real hann_window = (cos((PI * nc) / Nc) + 1.0) * 0.5;

        real multiply_factor = 2.0 * hann_window;
        if (nc == 0) 
        { 
            multiply_factor = 1.0 * hann_window; 
        }

        vac_x_normalized[nc] *= multiply_factor;
        vac_y_normalized[nc] *= multiply_factor;
        vac_z_normalized[nc] *= multiply_factor;
    }

    // Calculate DOS by discrete Fourier transform
    for (int nw = 0; nw < Nc; nw++)
    {
        real omega = omega_0 + nw * d_omega;
        for (int nc = 0; nc < Nc; nc++)
        {
            real cos_factor = cos(omega * nc * delta_t);
            dos_x[nw] += vac_x_normalized[nc] * cos_factor;
            dos_y[nw] += vac_y_normalized[nc] * cos_factor;
            dos_z[nw] += vac_z_normalized[nc] * cos_factor;
        }
        dos_x[nw] *= delta_t;
        dos_y[nw] *= delta_t;
        dos_z[nw] *= delta_t;
    }
}
        
    
// Calculate (1) VAC, (2) RDC, and (3) DOS = phonon density of states
static void find_vac_rdc_dos
(char *input_dir, Parameters *para, CPU_Data *cpu_data, GPU_Data *gpu_data)
{
    // rename variables
    int N = para->N;
    int number_of_steps = para->number_of_steps;
    int sample_interval = para->vac.sample_interval;
    int Nc = para->vac.Nc;
    real time_step = para->time_step;
    real omega_max = para->vac.omega_max;

    // other parameters
    int Nd = number_of_steps / sample_interval;
    int M = Nd - Nc; // number of time origins
    real dt = time_step * sample_interval;
    real dt_in_ps = dt * TIME_UNIT_CONVERSION / 1000.0; // ps
    real d_omega = omega_max / Nc;
    real omega_0 = d_omega;

    // major data
    real *vac_x, *vac_y, *vac_z;
    real *dos_x, *dos_y, *dos_z;
    real *rdc_x, *rdc_y, *rdc_z;
    real *vac_x_normalized, *vac_y_normalized, *vac_z_normalized;
    MY_MALLOC(vac_x, real, Nc);
    MY_MALLOC(vac_y, real, Nc);
    MY_MALLOC(vac_z, real, Nc);
    MY_MALLOC(rdc_x, real, Nc);
    MY_MALLOC(rdc_y, real, Nc);
    MY_MALLOC(rdc_z, real, Nc);
    MY_MALLOC(dos_x, real, Nc);
    MY_MALLOC(dos_y, real, Nc);
    MY_MALLOC(dos_z, real, Nc);
    MY_MALLOC(vac_x_normalized, real, Nc);
    MY_MALLOC(vac_y_normalized, real, Nc);
    MY_MALLOC(vac_z_normalized, real, Nc);

    for (int nc = 0; nc < Nc; nc++) {vac_x[nc] = vac_y[nc] = vac_z[nc] = 0.0;}
    for (int nc = 0; nc < Nc; nc++) {rdc_x[nc] = rdc_y[nc] = rdc_z[nc] = 0.0;}
    for (int nw = 0; nw < Nc; nw++) {dos_x[nw] = dos_y[nw] = dos_z[nw] = 0.0;}

    real *g_vac_x, *g_vac_y, *g_vac_z;
    CHECK(cudaMalloc((void**)&g_vac_x, sizeof(real) * Nc));
    CHECK(cudaMalloc((void**)&g_vac_y, sizeof(real) * Nc));
    CHECK(cudaMalloc((void**)&g_vac_z, sizeof(real) * Nc));

    // Here, the block size is fixed to 128, which is a good choice
    gpu_find_vac<<<Nc, 128>>>
    (
        N, M, gpu_data->vx_all, gpu_data->vy_all, gpu_data->vz_all, 
        g_vac_x, g_vac_y, g_vac_z
    );

    CHECK(cudaDeviceSynchronize());
    CHECK(cudaGetLastError());
    CHECK(cudaMemcpy(vac_x, g_vac_x, sizeof(real) * Nc, cudaMemcpyDeviceToHost));
    CHECK(cudaMemcpy(vac_y, g_vac_y, sizeof(real) * Nc, cudaMemcpyDeviceToHost));
    CHECK(cudaMemcpy(vac_z, g_vac_z, sizeof(real) * Nc, cudaMemcpyDeviceToHost));
    CHECK(cudaFree(g_vac_x));
    CHECK(cudaFree(g_vac_y));
    CHECK(cudaFree(g_vac_z));

    find_rdc(Nc, dt, vac_x, vac_y, vac_z, rdc_x, rdc_y, rdc_z);
    real vac_x_0 = vac_x[0];
    real vac_y_0 = vac_y[0];
    real vac_z_0 = vac_z[0];
    for (int nc = 0; nc < Nc; nc++)
    {
        vac_x_normalized[nc] = vac_x[nc] / vac_x_0;
        vac_y_normalized[nc] = vac_y[nc] / vac_y_0;
        vac_z_normalized[nc] = vac_z[nc] / vac_z_0;
    }

    find_dos
    (
        Nc, dt_in_ps, omega_0, d_omega, 
        vac_x_normalized, vac_y_normalized, vac_z_normalized, 
        dos_x, dos_y, dos_z
    );

    char file_vac[FILE_NAME_LENGTH];
    strcpy(file_vac, input_dir);
    strcat(file_vac, "/vac.out");
    FILE *fid = fopen(file_vac, "a");
    for (int nc = 0; nc < Nc; nc++)
    {
        real t = nc * dt_in_ps;
        real omega = omega_0 + d_omega * nc;

        // change to A^2/ps^2
        vac_x[nc] *= 1000000.0 / TIME_UNIT_CONVERSION / TIME_UNIT_CONVERSION; 
        vac_y[nc] *= 1000000.0 / TIME_UNIT_CONVERSION / TIME_UNIT_CONVERSION; 
        vac_z[nc] *= 1000000.0 / TIME_UNIT_CONVERSION / TIME_UNIT_CONVERSION; 

        rdc_x[nc] *= 1000.0 / TIME_UNIT_CONVERSION; // change to A^2/ps
        rdc_y[nc] *= 1000.0 / TIME_UNIT_CONVERSION; // change to A^2/ps
        rdc_z[nc] *= 1000.0 / TIME_UNIT_CONVERSION; // change to A^2/ps

        fprintf(fid, "%25.15e",                                             t);
        fprintf(fid, "%25.15e%25.15e%25.15e", vac_x[nc], vac_y[nc], vac_z[nc]);
        fprintf(fid, "%25.15e%25.15e%25.15e", rdc_x[nc], rdc_y[nc], rdc_z[nc]);
        fprintf(fid, "%25.15e",                                         omega);
        fprintf(fid, "%25.15e%25.15e%25.15e", dos_x[nc], dos_y[nc], dos_z[nc]);
        fprintf(fid, "\n");
    }
    fflush(fid);
    fclose(fid);

    MY_FREE(vac_x); MY_FREE(vac_y); MY_FREE(vac_z);
    MY_FREE(vac_x_normalized); 
    MY_FREE(vac_y_normalized); 
    MY_FREE(vac_z_normalized);
    MY_FREE(rdc_x); MY_FREE(rdc_y); MY_FREE(rdc_z);
    MY_FREE(dos_x); MY_FREE(dos_y); MY_FREE(dos_z);
}


// postprocess VAC and related quantities.
void postprocess_vac
(char *input_dir, Parameters *para, CPU_Data *cpu_data,GPU_Data *gpu_data)
{
    if (para->vac.compute)
    {
        printf("INFO:  start to calculate VAC and related quantities.\n");
        find_vac_rdc_dos(input_dir, para, cpu_data, gpu_data);
        CHECK(cudaFree(gpu_data->vx_all));
        CHECK(cudaFree(gpu_data->vy_all));
        CHECK(cudaFree(gpu_data->vz_all));
        printf("INFO:  VAC and related quantities are calculated.\n\n");
    }
}

