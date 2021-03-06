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
#include "ensemble_nve.cuh"
#include "ensemble_include.cuh"
#include "force.cuh"



Ensemble_NVE::Ensemble_NVE(int t)
{
    type = t;
}



Ensemble_NVE::~Ensemble_NVE(void)
{
    // nothing now
}




void Ensemble_NVE::compute
(Parameters *para, CPU_Data *cpu_data, GPU_Data *gpu_data, Force *force)
{
    int    N           = para->N;
    int    grid_size   = (N - 1) / BLOCK_SIZE + 1;
    int fixed_group = para->fixed_group;
    int *label = gpu_data->label;
    real time_step   = para->time_step;
    real *mass = gpu_data->mass;
    real *x    = gpu_data->x;
    real *y    = gpu_data->y;
    real *z    = gpu_data->z;
    real *vx   = gpu_data->vx;
    real *vy   = gpu_data->vy;
    real *vz   = gpu_data->vz;
    real *fx   = gpu_data->fx;
    real *fy   = gpu_data->fy;
    real *fz   = gpu_data->fz;
    real *potential_per_atom = gpu_data->potential_per_atom;
    real *virial_per_atom_x  = gpu_data->virial_per_atom_x; 
    real *virial_per_atom_y  = gpu_data->virial_per_atom_y;
    real *virial_per_atom_z  = gpu_data->virial_per_atom_z;
    real *thermo             = gpu_data->thermo;
    real *box_length         = gpu_data->box_length;

    gpu_velocity_verlet_1<<<grid_size, BLOCK_SIZE>>>
    (N, fixed_group, label, time_step, mass, x,  y,  z, vx, vy, vz, fx, fy, fz);

    force->compute(para, gpu_data);

    gpu_velocity_verlet_2<<<grid_size, BLOCK_SIZE>>>
    (N, fixed_group, label, time_step, mass, vx, vy, vz, fx, fy, fz);


    // for the time being:
    int N_fixed = (fixed_group == -1) ? 0 : cpu_data->group_size[fixed_group];

    gpu_find_thermo<<<6, 1024>>>
    (
        N, N_fixed, temperature, box_length, 
        mass, z, potential_per_atom, vx, vy, vz, 
        virial_per_atom_x, virial_per_atom_y, virial_per_atom_z, thermo
    ); 
}




