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


#ifndef ENSEMBLE_NVE_H
#define ENSEMBLE_NVE_H


#include "ensemble.cuh"
class Force;




class Ensemble_NVE : public Ensemble
{
public:
    Ensemble_NVE(int type_input);      
    virtual ~Ensemble_NVE(void);
    virtual void compute(Parameters*, CPU_Data*, GPU_Data*, Force*);
};





#endif




