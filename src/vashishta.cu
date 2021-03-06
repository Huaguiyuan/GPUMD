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
#include "vashishta.cuh"




// best block size here: 64 or 128
#define BLOCK_SIZE_VASHISHTA 64 




/*----------------------------------------------------------------------------80
    Reference: 
        P. Vashishta et al., J. Appl. Phys. 101, 103515 (2007).
*-----------------------------------------------------------------------------*/




void Vashishta::initialize_0(FILE *fid)
{
    printf("INPUT: use Vashishta potential.\n");
    int count;
    
    double B_0, B_1, cos0_0, cos0_1, C, r0, cut;
    count = fscanf
    (fid, "%lf%lf%lf%lf%lf%lf%lf", &B_0, &B_1, &cos0_0, &cos0_1, &C, &r0, &cut);
    if (count != 7) 
    {
        print_error("reading error for Vashishta potential.\n");
        exit(1);
    }
    vashishta_para.B[0] = B_0;
    vashishta_para.B[1] = B_1;
    vashishta_para.cos0[0] = cos0_0;
    vashishta_para.cos0[1] = cos0_1;
    vashishta_para.C = C;
    vashishta_para.r0 = r0;
    vashishta_para.rc = cut;
    rc = cut;
    
    double H[3], qq[3], lambda_inv[3], D[3], xi_inv[3], W[3];
    int eta[3];
    for (int n = 0; n < 3; n++)
    {  
        count = fscanf
        (
            fid, "%lf%d%lf%lf%lf%lf%lf", 
		    &H[n], &eta[n], &qq[n], &lambda_inv[n], &D[n], &xi_inv[n], &W[n]
        );
        if (count != 7) 
        {
		    print_error("reading error for Vashishta potential.\n");
            exit(1);
        }
		qq[n] *= K_C;         // Gauss -> SI
		D[n] *= (K_C * HALF); // Gauss -> SI and D -> D/2
		lambda_inv[n] = ONE / lambda_inv[n];
		xi_inv[n] = ONE / xi_inv[n];
		
		vashishta_para.H[n] = H[n];
		vashishta_para.eta[n] = eta[n];
		vashishta_para.qq[n] = qq[n];
		vashishta_para.lambda_inv[n] = lambda_inv[n];
		vashishta_para.D[n] = D[n];
		vashishta_para.xi_inv[n] = xi_inv[n];
		vashishta_para.W[n] = W[n];
			
        real rci = ONE / rc;
        real rci4 = rci * rci * rci * rci;
        real rci6 = rci4 * rci * rci;
        real p2_steric = H[n] * pow(rci, real(eta[n]));
	    real p2_charge = qq[n] * rci * exp(-rc*lambda_inv[n]);
        real p2_dipole = D[n] * rci4 * exp(-rc*xi_inv[n]);
	    real p2_vander = W[n] * rci6;
	    vashishta_para.v_rc[n] = p2_steric+p2_charge-p2_dipole-p2_vander;
        vashishta_para.dv_rc[n] = p2_dipole * (xi_inv[n] + FOUR * rci) 
	                            + p2_vander * (SIX * rci)
                                - p2_charge * (lambda_inv[n] + rci)      
						        - p2_steric * (eta[n] * rci);
    }
}  




// get U_ij and (d U_ij / d r_ij) / r_ij for the 2-body part
static void find_p2_and_f2_host
(
    real H, int eta, real qq, real lambda_inv, real D, real xi_inv, real W, 
    real v_rc, real dv_rc, real rc, real d12, real &p2, real &f2
)
{
    real d12inv = ONE / d12;
    real d12inv2 = d12inv * d12inv;
    real p2_steric = eta; p2_steric = H * pow(d12inv, eta);
    real p2_charge = qq * d12inv * exp(-d12 * lambda_inv);
    real p2_dipole = D * (d12inv2 * d12inv2) * exp(-d12 * xi_inv);
    real p2_vander = W * (d12inv2 * d12inv2 * d12inv2);
    p2 = p2_steric + p2_charge - p2_dipole - p2_vander; 
    p2 -= v_rc + (d12 - rc) * dv_rc; // shifted potential
    f2 = p2_dipole * (xi_inv + FOUR*d12inv) + p2_vander * (SIX * d12inv);
    f2 -= p2_charge * (lambda_inv + d12inv) + p2_steric * (eta * d12inv);
    f2 = (f2 - dv_rc) * d12inv;      // shifted force
}




void Vashishta::initialize_1(FILE *fid)
{
    printf("INPUT: use tabulated Vashishta potential.\n");
    int count;

    int N; double rmin;
    count = fscanf(fid, "%d%lf", &N, &rmin);
    if (count != 2) 
    {
        print_error("reading error for Vashishta potential.\n");
        exit(1);
    }
    vashishta_para.N = N;
    vashishta_para.rmin = rmin;

    real *table;
    MY_MALLOC(table, real, N * 6);
    
    double B_0, B_1, cos0_0, cos0_1, C, r0, cut;
    count = fscanf
    (fid, "%lf%lf%lf%lf%lf%lf%lf", &B_0, &B_1, &cos0_0, &cos0_1, &C, &r0, &cut);
    if (count != 7) 
    {
        print_error("reading error for Vashishta potential.\n");
        exit(1);
    }
    vashishta_para.B[0] = B_0;
    vashishta_para.B[1] = B_1;
    vashishta_para.cos0[0] = cos0_0;
    vashishta_para.cos0[1] = cos0_1;
    vashishta_para.C = C;
    vashishta_para.r0 = r0;
    vashishta_para.rc = cut;
    vashishta_para.scale = (N-ONE)/(cut-rmin);
    rc = cut;
    
    double H[3], qq[3], lambda_inv[3], D[3], xi_inv[3], W[3];
    int eta[3];
    for (int n = 0; n < 3; n++)
    {  
        count = fscanf
        (
            fid, "%lf%d%lf%lf%lf%lf%lf", 
		    &H[n], &eta[n], &qq[n], &lambda_inv[n], &D[n], &xi_inv[n], &W[n]
        );
        if (count != 7) 
        {
		    print_error("reading error for Vashishta potential.\n");
            exit(1);
        }
        qq[n] *= K_C;         // Gauss -> SI
        D[n] *= (K_C * HALF); // Gauss -> SI and D -> D/2
        lambda_inv[n] = ONE / lambda_inv[n];
        xi_inv[n] = ONE / xi_inv[n];
		
        vashishta_para.H[n] = H[n];
        vashishta_para.eta[n] = eta[n];
        vashishta_para.qq[n] = qq[n];
        vashishta_para.lambda_inv[n] = lambda_inv[n];
        vashishta_para.D[n] = D[n];
        vashishta_para.xi_inv[n] = xi_inv[n];
        vashishta_para.W[n] = W[n];
			
        real rci = ONE / rc;
        real rci4 = rci * rci * rci * rci;
        real rci6 = rci4 * rci * rci;
        real p2_steric = H[n] * pow(rci, real(eta[n]));
        real p2_charge = qq[n] * rci * exp(-rc*lambda_inv[n]);
        real p2_dipole = D[n] * rci4 * exp(-rc*xi_inv[n]);
        real p2_vander = W[n] * rci6;
        vashishta_para.v_rc[n] = p2_steric+p2_charge-p2_dipole-p2_vander;
        vashishta_para.dv_rc[n] = p2_dipole * (xi_inv[n] + FOUR * rci) 
	                            + p2_vander * (SIX * rci)
                                - p2_charge * (lambda_inv[n] + rci)      
						        - p2_steric * (eta[n] * rci);

        // build the table
        for (int m = 0; m < N; m++) 
        {
            real d12 = rmin + m * (cut - rmin) / (N-ONE);
            real p2, f2;
            find_p2_and_f2_host
            (
                H[n], eta[n], qq[n], lambda_inv[n], D[n], xi_inv[n], W[n], 
                vashishta_para.v_rc[n], 
                vashishta_para.dv_rc[n], 
                rc, d12, p2, f2
            );
            int index_p = m + N * n;
            int index_f = m + N * (n + 3);
            table[index_p] = p2;
            table[index_f] = f2;
        }
    }

    int memory = sizeof(real) * N * 6;
    CHECK(cudaMalloc((void**)&vashishta_data.table, memory));
    cudaMemcpy(vashishta_data.table, table, memory, cudaMemcpyHostToDevice);
    MY_FREE(table);
}  




Vashishta::Vashishta(FILE *fid, Parameters *para, int use_table_input)
{
    use_table = use_table_input;
    if (use_table == 0) initialize_0(fid);
    if (use_table == 1) initialize_1(fid);

    int num = ((para->neighbor.MN<20) ? para->neighbor.MN : 20);
    int memory = sizeof(real) * para->N * num;
    CHECK(cudaMalloc((void**)&vashishta_data.f12x, memory));
    CHECK(cudaMalloc((void**)&vashishta_data.f12y, memory));
    CHECK(cudaMalloc((void**)&vashishta_data.f12z, memory));
    memory = sizeof(int) * para->N;
    CHECK(cudaMalloc((void**)&vashishta_data.NN_short, memory));
    memory = sizeof(int) * para->N * num;
    CHECK(cudaMalloc((void**)&vashishta_data.NL_short, memory));
}





Vashishta::~Vashishta(void)
{
    if (use_table) cudaFree(vashishta_data.table);
    cudaFree(vashishta_data.f12x);
    cudaFree(vashishta_data.f12y);
    cudaFree(vashishta_data.f12z);
    cudaFree(vashishta_data.NN_short);
    cudaFree(vashishta_data.NL_short);
}




// eta is always an integer and we don't need the very slow pow()
static __device__ real my_pow(real x, int n) 
{
    if (n == 7) 
    { 
        real y = x;
        x *= x;
        y *= x; // x^3
        x *= x; // x^4
        return y * x;
    }
    else if (n == 9) 
    { 
        real y = x;
        x *= x; // x^2
        x *= x; // x^4
        y *= x; // x^5
        return y * x; 
    }
    else // n = 11
    { 
        real y = x;
        x *= x; // x^2
        y *= x; // x^3
        x *= x; // x^4
        x *= x; // x^8
        return y * x; 
    }
}




// get U_ij and (d U_ij / d r_ij) / r_ij for the 2-body part
static __device__ void find_p2_and_f2
(
    real H, int eta, real qq, real lambda_inv, real D, real xi_inv, real W, 
    real v_rc, real dv_rc, real rc, real d12, real &p2, real &f2
)
{
    real d12inv = ONE / d12;
    real d12inv2 = d12inv * d12inv;
    // real p2_steric = eta; p2_steric = H * pow(d12inv, p2_steric); // slow
    real p2_steric = H * my_pow(d12inv, eta); // super fast
    real p2_charge = qq * d12inv * exp(-d12 * lambda_inv);
    real p2_dipole = D * (d12inv2 * d12inv2) * exp(-d12 * xi_inv);
    real p2_vander = W * (d12inv2 * d12inv2 * d12inv2);
    p2 = p2_steric + p2_charge - p2_dipole - p2_vander; 
    p2 -= v_rc + (d12 - rc) * dv_rc; // shifted potential
    f2 = p2_dipole * (xi_inv + FOUR*d12inv) + p2_vander * (SIX * d12inv);
    f2 -= p2_charge * (lambda_inv + d12inv) + p2_steric * (eta * d12inv);
    f2 = (f2 - dv_rc) * d12inv;      // shifted force
}




// 2-body part of the Vashishta potential (kernel)
template <int use_table, int cal_p, int cal_j, int cal_q>
static __global__ void gpu_find_force_vashishta_2body
(
    int number_of_particles, int N1, int N2, int pbc_x, int pbc_y, int pbc_z, 
    Vashishta_Para vas,
    int *g_NN, int *g_NL, int *g_NN_local, int *g_NL_local, int *g_type,
#ifdef USE_LDG
    const real* __restrict__ g_table,
    const real* __restrict__ g_x, 
    const real* __restrict__ g_y, 
    const real* __restrict__ g_z, 
    const real* __restrict__ g_vx, 
    const real* __restrict__ g_vy, 
    const real* __restrict__ g_vz,
#else
    real *g_table, 
    real *g_x,  real *g_y,  real *g_z, real *g_vx, real *g_vy, real *g_vz,
#endif
    real *g_box_length, real *g_fx, real *g_fy, real *g_fz,
    real *g_sx, real *g_sy, real *g_sz, real *g_potential, 
    real *g_h, int *g_label, int *g_fv_index, real *g_fv 
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index

    real s_fx = ZERO; 
    real s_fy = ZERO; 
    real s_fz = ZERO; 
    // if cal_p, then s1~s4 = px, py, pz, U; if cal_j, then s1~s5 = j1~j5
    real s1 = ZERO;
    real s2 = ZERO;
    real s3 = ZERO;
    real s4 = ZERO;
    real s5 = ZERO; 

    if (n1 >= N1 && n1 < N2)
    {
        int neighbor_number = g_NN[n1];
        int type1 = g_type[n1];
        real x1 = LDG(g_x, n1); 
        real y1 = LDG(g_y, n1); 
        real z1 = LDG(g_z, n1);
        real vx1; 
        real vy1; 
        real vz1;
        if (!cal_p)
        {
            vx1 = LDG(g_vx, n1); 
            vy1 = LDG(g_vy, n1); 
            vz1 = LDG(g_vz, n1);
        }
        real lx = g_box_length[0]; 
        real ly = g_box_length[1]; 
        real lz = g_box_length[2];
        
        int count = 0; // initialize g_NN_local[n1] to 0

        for (int i1 = 0; i1 < neighbor_number; ++i1)
        {   
            int n2 = g_NL[n1 + number_of_particles * i1];
            
            real x12  = LDG(g_x, n2) - x1;
            real y12  = LDG(g_y, n2) - y1;
            real z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(pbc_x, pbc_y, pbc_z, x12, y12, z12, lx, ly, lz);
            real d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
            if (d12 >= vas.rc) { continue; }
            if (d12 < vas.r0) // r0 is much smaller than rc
            {                    
                g_NL_local[n1 + number_of_particles * (count++)] = n2;
            }
            int type2 = g_type[n2];
            int type12 = type1 + type2; // 0 = AA; 1 = AB or BA; 2 = BB
            real p2, f2;

            if (use_table == 1)
            {
                if (d12 > vas.rmin)
                {
                    real tmp = (d12 - vas.rmin) * vas.scale;
                    int index = tmp; // 0 <= index < N-1
                    real x = tmp - index; // 0 <= x < 1
                    index += type12 * vas.N;
                    p2 = (ONE-x)*LDG(g_table, index) + x*LDG(g_table, index+1);
                    index += vas.N * 3;    
                    f2 = (ONE-x)*LDG(g_table, index) + x*LDG(g_table, index+1);
                }
                else
                {
                    find_p2_and_f2
                    (
                        vas.H[type12], vas.eta[type12], vas.qq[type12], 
                        vas.lambda_inv[type12], vas.D[type12], 
                        vas.xi_inv[type12], vas.W[type12], vas.v_rc[type12], 
                        vas.dv_rc[type12], vas.rc, d12, p2, f2
                    );	
                }
            }

            if (use_table == 0)
            {
                find_p2_and_f2
                (
                    vas.H[type12], vas.eta[type12], vas.qq[type12], 
                    vas.lambda_inv[type12], vas.D[type12], vas.xi_inv[type12],
                    vas.W[type12], vas.v_rc[type12], vas.dv_rc[type12], 
                    vas.rc, d12, p2, f2
                );	
            }

            // treat two-body potential in the same way as many-body potential
            real f12x = f2 * x12 * HALF; 
            real f12y = f2 * y12 * HALF; 
            real f12z = f2 * z12 * HALF; 
            real f21x = -f12x; 
            real f21y = -f12y; 
            real f21z = -f12z; 
       
            // accumulate force
            s_fx += f12x - f21x; 
            s_fy += f12y - f21y; 
            s_fz += f12z - f21z; 
            
            // accumulate potential energy and virial
            if (cal_p) 
            {
                s4 += p2 * HALF; // two-body potential
                s1 -= x12 * (f12x - f21x) * HALF; 
                s2 -= y12 * (f12y - f21y) * HALF; 
                s3 -= z12 * (f12z - f21z) * HALF;
            }
            
            if (cal_j) // heat current (EMD)
            {
                s1 += (f21x * vx1 + f21y * vy1) * x12;  // x-in
                s2 += (f21z * vz1) * x12;               // x-out
                s3 += (f21x * vx1 + f21y * vy1) * y12;  // y-in
                s4 += (f21z * vz1) * y12;               // y-out
                s5 += (f21x*vx1+f21y*vy1+f21z*vz1)*z12; // z-all
            } 

            if (cal_q) // heat across some section (NEMD)
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

        g_NN_local[n1] = count; // now the local neighbor list has been built

        g_fx[n1] += s_fx; // save force
        g_fy[n1] += s_fy; 
        g_fz[n1] += s_fz;  
        if (cal_p) // save stress and potential
        {
            g_sx[n1] += s1; 
            g_sy[n1] += s2; 
            g_sz[n1] += s3;
            g_potential[n1] += s4;
        }
        if (cal_j) // save heat current
        {
            g_h[n1 + 0 * number_of_particles] += s1;
            g_h[n1 + 1 * number_of_particles] += s2;
            g_h[n1 + 2 * number_of_particles] += s3;
            g_h[n1 + 3 * number_of_particles] += s4;
            g_h[n1 + 4 * number_of_particles] += s5;
        }
    }
}    




// calculate the partial forces dU_i/dr_ij
template <int cal_p>
static __global__ void gpu_find_force_vashishta_partial
(
    int number_of_particles, int N1, int N2, int pbc_x, int pbc_y, int pbc_z, 
    Vashishta_Para vas,
    int *g_neighbor_number, int *g_neighbor_list, int *g_type,
#ifdef USE_LDG
    const real* __restrict__ g_x, 
    const real* __restrict__ g_y, 
    const real* __restrict__ g_z, 
#else
    real *g_x,  real *g_y,  real *g_z,
#endif
    real *g_box_length,
    real *g_potential, real *g_f12x, real *g_f12y, real *g_f12z  
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index
    if (n1 >= N1 && n1 < N2)
    {
        int neighbor_number = g_neighbor_number[n1];
        int type1 = g_type[n1];
        real x1 = LDG(g_x, n1); 
        real y1 = LDG(g_y, n1); 
        real z1 = LDG(g_z, n1);
        real lx = g_box_length[0]; 
        real ly = g_box_length[1]; 
        real lz = g_box_length[2];
        real potential_energy = ZERO;

        for (int i1 = 0; i1 < neighbor_number; ++i1)
        {   
            int index = i1 * number_of_particles + n1;
            int n2 = g_neighbor_list[index];
            int type2 = g_type[n2];

            real x12  = LDG(g_x, n2) - x1;
            real y12  = LDG(g_y, n2) - y1;
            real z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(pbc_x, pbc_y, pbc_z, x12, y12, z12, lx, ly, lz);
            real d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
            real d12inv = ONE / d12;
          
            real f12x = ZERO; real f12y = ZERO; real f12z = ZERO;  
            real gamma2 = ONE / ((d12 - vas.r0) * (d12 - vas.r0)); // gamma=1
             
            // accumulate_force_123
            for (int i2 = 0; i2 < neighbor_number; ++i2)
            {       
                int n3 = g_neighbor_list[n1 + number_of_particles * i2];  
                if (n3 == n2) { continue; }
                int type3 = g_type[n3];           // only consider ABB and BAA
                if (type3 != type2) { continue; } // exclude AAB, BBA, ABA, BAB
                if (type3 == type1) { continue; } // exclude AAA, BBB

                real x13 = LDG(g_x, n3) - x1;
                real y13 = LDG(g_y, n3) - y1;
                real z13 = LDG(g_z, n3) - z1;
                dev_apply_mic(pbc_x, pbc_y, pbc_z, x13, y13, z13, lx, ly, lz);
                real d13 = sqrt(x13 * x13 + y13 * y13 + z13 * z13);

                real exp123 = exp(ONE / (d12 - vas.r0) + ONE / (d13 - vas.r0));
                real one_over_d12d13 = ONE / (d12 * d13);
                real cos123 = (x12*x13 + y12*y13 + z12*z13) * one_over_d12d13;
                real cos123_over_d12d12 = cos123*d12inv*d12inv;
                real cos_inv = cos123 - vas.cos0[type1];
                cos_inv = ONE / (ONE + vas.C * cos_inv * cos_inv); 
				    
                if (cal_p) // accumulate potential energy
                {
                    potential_energy += (cos123 - vas.cos0[type1])
                                      * (cos123 - vas.cos0[type1])
                                      * cos_inv*HALF*vas.B[type1]*exp123;
                }
 
                real tmp1=vas.B[type1]*exp123*cos_inv*(cos123-vas.cos0[type1]);
                real tmp2=gamma2 * (cos123 - vas.cos0[type1]) * d12inv;

                real cos_d = x13 * one_over_d12d13 - x12 * cos123_over_d12d12; 	 
                f12x += tmp1*(TWO*cos_d*cos_inv-tmp2*x12);
                cos_d = y13 * one_over_d12d13 - y12 * cos123_over_d12d12;
                f12y += tmp1*(TWO*cos_d*cos_inv-tmp2*y12);
                cos_d = z13 * one_over_d12d13 - z12 * cos123_over_d12d12;
                f12z += tmp1*(TWO*cos_d*cos_inv-tmp2*z12);
            }
            g_f12x[index] = f12x;
            g_f12y[index] = f12y;
            g_f12z[index] = f12z;
        }
        if (cal_p) // save potential
        {
            g_potential[n1] += potential_energy;
        }
    }
}    




// 3-body part of the Vashishta potential (kernel)
template <int cal_p, int cal_j, int cal_q>
static __global__ void gpu_find_force_vashishta_3body
(
    int number_of_particles, int N1, int N2, int pbc_x, int pbc_y, int pbc_z, 
    Vashishta_Para vas,
    int *g_neighbor_number, int *g_neighbor_list, int *g_type,
#ifdef USE_LDG
    const real* __restrict__ g_f12x, 
    const real* __restrict__ g_f12y,
    const real* __restrict__ g_f12z,
    const real* __restrict__ g_x, 
    const real* __restrict__ g_y, 
    const real* __restrict__ g_z, 
    const real* __restrict__ g_vx, 
    const real* __restrict__ g_vy, 
    const real* __restrict__ g_vz,
#else
    real* g_f12x, real* g_f12y, real* g_f12z, 
    real *g_x,  real *g_y,  real *g_z, 
    real *g_vx, real *g_vy, real *g_vz,
#endif
    real *g_box_length, real *g_fx, real *g_fy, real *g_fz,
    real *g_sx, real *g_sy, real *g_sz,
    real *g_h, int *g_label, int *g_fv_index, real *g_fv 
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index
    real s_fx = ZERO;
    real s_fy = ZERO;
    real s_fz = ZERO;

    // if cal_p, then s1~s4 = px, py, pz, U; if cal_j, then s1~s5 = j1~j5
    real s1 = ZERO;
    real s2 = ZERO;
    real s3 = ZERO;
    real s4 = ZERO;
    real s5 = ZERO;

    if (n1 >= N1 && n1 < N2)
    {
        int neighbor_number = g_neighbor_number[n1];
        real x1 = LDG(g_x, n1); 
        real y1 = LDG(g_y, n1); 
        real z1 = LDG(g_z, n1);
        real vx1; 
        real vy1; 
        real vz1;
        if (!cal_p)
        {
            vx1 = LDG(g_vx, n1); 
            vy1 = LDG(g_vy, n1); 
            vz1 = LDG(g_vz, n1);
        }
        real lx = g_box_length[0]; 
        real ly = g_box_length[1]; 
        real lz = g_box_length[2];

        for (int i1 = 0; i1 < neighbor_number; ++i1)
        {  
            int index = i1 * number_of_particles + n1; 
            int n2 = g_neighbor_list[index];
            int neighbor_number_2 = g_neighbor_number[n2];

            real x12  = LDG(g_x, n2) - x1;
            real y12  = LDG(g_y, n2) - y1;
            real z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(pbc_x, pbc_y, pbc_z, x12, y12, z12, lx, ly, lz);
           
            real f12x = LDG(g_f12x, index); 
            real f12y = LDG(g_f12y, index);
            real f12z = LDG(g_f12z, index);
            int offset = 0;
            for (int k = 0; k < neighbor_number_2; ++k)
            {
                if (n1 == g_neighbor_list[n2 + number_of_particles * k]) 
                { 
                    offset = k; break; 
                }
            }
            index = offset * number_of_particles + n2; 
            real f21x = LDG(g_f12x, index);
            real f21y = LDG(g_f12y, index);
            real f21z = LDG(g_f12z, index);
    
            // per atom force 
            s_fx += f12x - f21x; 
            s_fy += f12y - f21y; 
            s_fz += f12z - f21z; 

            if (cal_p) // accumulate virial
            {
                s1 -= x12 * (f12x - f21x) * HALF; 
                s2 -= y12 * (f12y - f21y) * HALF; 
                s3 -= z12 * (f12z - f21z) * HALF;
            }
            
            if (cal_j) // heat current (EMD)
            {
                s1 += (f21x * vx1 + f21y * vy1) * x12;  // x-in
                s2 += (f21z * vz1) * x12;               // x-out
                s3 += (f21x * vx1 + f21y * vy1) * y12;  // y-in
                s4 += (f21z * vz1) * y12;               // y-out
                s5 += (f21x*vx1+f21y*vy1+f21z*vz1)*z12; // z-all
            } 

            if (cal_q) // heat current (NEMD)
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

        // accumulate on top of the 2-body part (hence += instead of =)
        g_fx[n1] += s_fx; // accumulate force
        g_fy[n1] += s_fy; 
        g_fz[n1] += s_fz;  
        if (cal_p) // accumulate stress
        {
            g_sx[n1] += s1; 
            g_sy[n1] += s2; 
            g_sz[n1] += s3;
        }
        if (cal_j) // accumulate heat current
        {
            g_h[n1 + 0 * number_of_particles] += s1;
            g_h[n1 + 1 * number_of_particles] += s2;
            g_h[n1 + 2 * number_of_particles] += s3;
            g_h[n1 + 3 * number_of_particles] += s4;
            g_h[n1 + 4 * number_of_particles] += s5;
        }
    }
}    
 



// Find force and related quantities for the Vashishta potential (A wrapper)
void Vashishta::compute(Parameters *para, GPU_Data *gpu_data)
{
    int N = para->N;
    int grid_size = (N2 - N1 - 1) / BLOCK_SIZE_VASHISHTA + 1;
    int pbc_x = para->pbc_x;
    int pbc_y = para->pbc_y;
    int pbc_z = para->pbc_z;
    int *NN = gpu_data->NN_local;             // for 2-body
    int *NL = gpu_data->NL_local;             // for 2-body
    int *NN_local = vashishta_data.NN_short;  // for 3-body
    int *NL_local = vashishta_data.NL_short;  // for 3-body
    int *type = gpu_data->type_local;
    real *x = gpu_data->x; 
    real *y = gpu_data->y; 
    real *z = gpu_data->z;
    real *vx = gpu_data->vx; 
    real *vy = gpu_data->vy; 
    real *vz = gpu_data->vz;
    real *fx = gpu_data->fx; 
    real *fy = gpu_data->fy; 
    real *fz = gpu_data->fz;
    real *box_length = gpu_data->box_length;
    real *sx = gpu_data->virial_per_atom_x; 
    real *sy = gpu_data->virial_per_atom_y; 
    real *sz = gpu_data->virial_per_atom_z; 
    real *pe = gpu_data->potential_per_atom;
    real *h = gpu_data->heat_per_atom; 
    
    int *label = gpu_data->label;
    int *fv_index = gpu_data->fv_index;
    real *fv = gpu_data->fv;

    real *table = vashishta_data.table;
    real *f12x  = vashishta_data.f12x; 
    real *f12y  = vashishta_data.f12y; 
    real *f12z  = vashishta_data.f12z;
          
    if (para->hac.compute)    
    {
        if (use_table == 0)
        {
            gpu_find_force_vashishta_2body<0, 0, 1, 0>
            <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
            (
                N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN, NL, NN_local, 
                NL_local, type, table, x, y, z, vx, vy, vz, box_length, 
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force_vashishta_2body<1, 0, 1, 0>
            <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
            (
                N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN, NL, NN_local, 
                NL_local, type, table, x, y, z, vx, vy, vz, box_length, 
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }

        gpu_find_force_vashishta_partial<0>
        <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
        (
            N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN_local, NL_local, type,
            x, y, z, box_length, pe, f12x, f12y, f12z  
        );

        gpu_find_force_vashishta_3body<0, 1, 0>
        <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
        (
            N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN_local, NL_local, type, 
            f12x, f12y, f12z, x, y, z, vx, vy, vz, box_length, 
            fx, fy, fz, sx, sy, sz, h, label, fv_index, fv
        );
    }
    else if (para->shc.compute)
    {
        if (use_table == 0)
        {
            gpu_find_force_vashishta_2body<0, 0, 0, 1>
            <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
            (
                N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN, NL, NN_local, 
                NL_local, type, table, x, y, z, vx, vy, vz, box_length, 
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force_vashishta_2body<1, 0, 0, 1>
            <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
            (
                N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN, NL, NN_local, 
                NL_local, type, table, x, y, z, vx, vy, vz, box_length, 
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }

        gpu_find_force_vashishta_partial<0>
        <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
        (
            N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN_local, NL_local, type,
            x, y, z, box_length, pe, f12x, f12y, f12z  
        );

        gpu_find_force_vashishta_3body<0, 0, 1>
        <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
        (
            N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN_local, NL_local, type, 
            f12x, f12y, f12z, x, y, z, vx, vy, vz, box_length, 
            fx, fy, fz, sx, sy, sz, h, label, fv_index, fv
        );
    }
    else
    {
        if (use_table == 0)
        {
            gpu_find_force_vashishta_2body<0, 1, 0, 0>
            <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
            (
                N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN, NL, NN_local, 
                NL_local, type, table, x, y, z, vx, vy, vz, box_length, 
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }
        else
        {
            gpu_find_force_vashishta_2body<1, 1, 0, 0>
            <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
            (
                N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN, NL, NN_local, 
                NL_local, type, table, x, y, z, vx, vy, vz, box_length, 
                fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
            );
        }

        gpu_find_force_vashishta_partial<1>
        <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
        (
            N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN_local, NL_local, type,
            x, y, z, box_length, pe, f12x, f12y, f12z 
        );

        gpu_find_force_vashishta_3body<1, 0, 0>
        <<<grid_size, BLOCK_SIZE_VASHISHTA>>>
        (
            N, N1, N2, pbc_x, pbc_y, pbc_z, vashishta_para, NN_local, NL_local, type, 
            f12x, f12y, f12z, x, y, z, vx, vy, vz, box_length, 
            fx, fy, fz, sx, sy, sz, h, label, fv_index, fv
        );  
    }

    #ifdef DEBUG
        CHECK(cudaDeviceSynchronize());
        CHECK(cudaGetLastError());
    #endif
}




