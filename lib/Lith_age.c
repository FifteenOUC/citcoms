/*
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 *
 *<LicenseText>
 *
 * CitcomS by Louis Moresi, Shijie Zhong, Lijie Han, Eh Tan,
 * Clint Conrad, Michael Gurnis, and Eun-seo Choi.
 * Copyright (C) 1994-2005, California Institute of Technology.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 *</LicenseText>
 *
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 */

#include <math.h>

#include "global_defs.h"

/*#include "age_related.h"*/
#include "parallel_related.h"
#include "parsing.h"
#include "lith_age.h"

float find_age_in_MY();
void lith_age_update_tbc(struct All_variables *E);


void lith_age_input(struct All_variables *E)
{
  int m = E->parallel.me;

  E->control.lith_age = 0;
  E->control.lith_age_time = 0;
  E->control.temperature_bound_adj = 0;

  input_int("lith_age",&(E->control.lith_age),"0",m);

  
  input_int("lith_age_time",&(E->control.lith_age_time),"0",m);
  input_string("lith_age_file",E->control.lith_age_file,"",m);
  input_float("lith_age_depth",&(E->control.lith_age_depth),"0.0471",m); /* 300 km */
  
  input_int("temperature_bound_adj",&(E->control.temperature_bound_adj),"0",m);
  if (E->control.temperature_bound_adj) {
    input_float("depth_bound_adj",&(E->control.depth_bound_adj),"0.1570",m);
    input_float("width_bound_adj",&(E->control.width_bound_adj),"0.08727",m);
  }
  return;
}

/* not called for ggrd version */
void lith_age_init(struct All_variables *E)
{
  char output_file[255];
  FILE *fp1;
  int node, i, j, output;

  int gnox, gnoy;
  gnox=E->mesh.nox;
  gnoy=E->mesh.noy;

  if (E->parallel.me == 0 ) fprintf(stderr,"INSIDE lith_age_init\n");
  E->age_t=(float*) malloc((gnox*gnoy+1)*sizeof(float));

  if(E->control.lith_age_time==1)   {
    /* to open files every timestep */
    E->control.lith_age_old_cycles = E->monitor.solution_cycles;
    output = 1;

    (E->solver.lith_age_read_files)(E,output);
  }
  else {
    /* otherwise, just open for the first timestep */
    /* NOTE: This is only used if we are adjusting the boundaries */
    sprintf(output_file,"%s",E->control.lith_age_file);
    fp1=fopen(output_file,"r");
    if (fp1 == NULL) {
      fprintf(E->fp,"(Boundary_conditions #1) Can't open %s\n",output_file);
      parallel_process_termination();
    }
    for(i=1;i<=gnoy;i++)
      for(j=1;j<=gnox;j++) {
	node=j+(i-1)*gnox;
	if(fscanf(fp1,"%f",&(E->age_t[node])) != 1) {
          fprintf(stderr,"Error while reading file '%s'\n",output_file);
          exit(8);
        }
	E->age_t[node]=E->age_t[node]*E->data.scalet;
      }
    fclose(fp1);
  } /* end E->control.lith_age_time == false */
}

/* 

   this doesn't get called if tic == 4 

*/
void lith_age_construct_tic(struct All_variables *E)
{
  int i, j, k, m, node, nodeg;
  int nox, noy, noz, gnox, gnoy, gnoz;
  float r1, temp;
  float depth_used;


  noy=E->lmesh.noy;nox=E->lmesh.nox;noz=E->lmesh.noz;
  gnox=E->mesh.nox;gnoy=E->mesh.noy;gnoz=E->mesh.noz;

  for(m=1;m<=E->sphere.caps_per_proc;m++)
    for(i=1;i<=noy;i++)
      for(j=1;j<=nox;j++)
	for(k=1;k<=noz;k++)  {
	  nodeg=E->lmesh.nxs-1+j+(E->lmesh.nys+i-2)*gnox;
	  node=k+(j-1)*noz+(i-1)*nox*noz;
	  E->T[m][node] = E->control.mantle_temp;

	  r1=E->sx[m][3][node];
	  if(in_lith_age_depth(r1,E->age_t[nodeg],&depth_used,E)){ /* if closer than (lith_age_depth) from top */
	    E->T[m][node] = erft_age(r1, E->age_t[nodeg],E);
	  }
	}
  
  /* modify temperature BC to be concorded with read in T */
  lith_age_update_tbc(E);

  temperatures_conform_bcs(E);

  return;
}
/* 
   assign T and TBC for nodes in the boundary layer

 */
void set_lith_age_for_t_and_tbc(struct All_variables *E)
{
  int i, j, k, m, node, nodeg;
  int nox, noy, noz, gnox, gnoy, gnoz,noxnoz;
  float r1, temp,depth_used;

  if(E->parallel.me == 0)
    fprintf(stderr,"setting T and TBC within lithosphere to age dependent T\n");
  
  noy=E->lmesh.noy;nox=E->lmesh.nox;noz=E->lmesh.noz;
  gnox=E->mesh.nox;gnoy=E->mesh.noy;gnoz=E->mesh.noz;
  noxnoz = nox*noz;

  for(m=1;m <= E->sphere.caps_per_proc;m++)
    for(i=1;i<=noy;i++)
      for(j=1;j<=nox;j++){
	nodeg=E->lmesh.nxs-1+j+(E->lmesh.nys+i-2)*gnox;
	for(k=1;k<=noz;k++)  {
	  node=k+(j-1)*noz+(i-1)*noxnoz;
	  r1=E->sx[m][3][node];
	  if(in_lith_age_depth(r1,E->age_t[nodeg],&depth_used,E)){ /* if closer than (lith_age_depth) from top */
	    temp = erft_age(r1, E->age_t[nodeg],E);
	    E->T[m][node] = temp;
	    E->sphere.cap[m].TB[1][node]=temp;
	    E->sphere.cap[m].TB[2][node]=temp;
	    E->sphere.cap[m].TB[3][node]=temp;
	  }
	}
      }
}
/* 

   determine if we are in the lithosphere for TBC assignment purposes
   normally, this will just mean checking the depth
   
   will also return the depth use
*/
int in_lith_age_depth(float r1,float age, float *depth_used, struct All_variables *E)
{
  static int in_lith_age_init = FALSE;
  static int mode;
  static float r1diff;
  if(!in_lith_age_init){
    /* initialization branch */
    if(E->control.lith_age_depth > 0){ /* default */
      r1diff =  E->sphere.ro - E->control.lith_age_depth;
      mode = 1;
    }else{
      /* determine depth from actual age */
      mode = 2;
    }
    in_lith_age_init = TRUE;
  }
  if(mode == 1){
    *depth_used = E->control.lith_age_depth;
    if(r1 >= r1diff)
      return 1;
    else
      return 0;
  }else{
    //fprintf(stderr,"%i %i %g \n",in_lith_age_init,mode,E->control.lith_age_depth);
    myerror(E,"mode 2 not implemented yet for in_lith_age_depth");
  }
  return 0;
}

/* this is not particularly elegant, but I leave in for backward
   compatibiltiy */
void lith_age_update_tbc(struct All_variables *E)
{
  int i, j, k, m, node;
  int nox, noy, noz;
  double r1, rout, rin;
  const float e_4=1.e-4;

  noy = E->lmesh.noy;
  nox = E->lmesh.nox;
  noz = E->lmesh.noz;
  rout = E->sphere.ro;
  rin = E->sphere.ri;

  for(m=1;m<=E->sphere.caps_per_proc;m++)
    for(i=1;i<=noy;i++)
      for(j=1;j<=nox;j++)
	for(k=1;k<=noz;k++)  {
	  node=k+(j-1)*noz+(i-1)*nox*noz;
	  r1=E->sx[m][3][node];

	  if(fabs(r1-rout)>=e_4 && fabs(r1-rin)>=e_4)  {
	    E->sphere.cap[m].TB[1][node]=E->T[m][node];
	    E->sphere.cap[m].TB[2][node]=E->T[m][node];
	    E->sphere.cap[m].TB[3][node]=E->T[m][node];
	  }
	}

  return;
}

/* 
   
   called from the boundary condition routine

*/
void lith_age_temperature_bound_adj(struct All_variables *E, int lv)
{
  int j,node,nno,i,k,m,nodeg;
  float ttt2,ttt3,fff2,fff3,depth_used;
  int nox,noy,noz,noxnoz;

  noy=E->lmesh.noy;nox=E->lmesh.nox;noz=E->lmesh.noz;
  noxnoz = nox*noz;

  nno=E->lmesh.nno;

  /* NOTE: To start, the relevent bits of "node" are zero. Thus, they only
     get set to TBX/TBY/TBZ if the node is in one of the bounding regions.
     Also note that right now, no matter which bounding region you are in,
     all three get set to true. CPC 6/20/00 */
  
  if (E->control.temperature_bound_adj) {
    if(E->sphere.caps == 12)
      myerror(E,"temperature_bound_adj and global model does not make sense?");

    ttt2=E->control.theta_min + E->control.width_bound_adj;
    ttt3=E->control.theta_max - E->control.width_bound_adj;
    fff2=E->control.fi_min + E->control.width_bound_adj;
    fff3=E->control.fi_max - E->control.width_bound_adj;

    if(lv==E->mesh.gridmax)
      for(j=1;j<=E->sphere.caps_per_proc;j++)
	for(node=1;node<=E->lmesh.nno;node++)  {
	  if( ((E->sx[j][1][node]<=ttt2) && (E->sx[j][3][node]>=E->sphere.ro-E->control.depth_bound_adj)) || ((E->sx[j][1][node]>=ttt3) && (E->sx[j][3][node]>=E->sphere.ro-E->control.depth_bound_adj)) )
	    /* if < (width) from x bounds AND (depth) from top */
	    {
	      E->node[j][node]=E->node[j][node] | TBX;
	      E->node[j][node]=E->node[j][node] & (~FBX);
	      E->node[j][node]=E->node[j][node] | TBY;
	      E->node[j][node]=E->node[j][node] & (~FBY);
	      E->node[j][node]=E->node[j][node] | TBZ;
	      E->node[j][node]=E->node[j][node] & (~FBZ);
	    }

	  if( ((E->sx[j][2][node]<=fff2) && (E->sx[j][3][node]>=E->sphere.ro-E->control.depth_bound_adj)) )
	    /* if fi is < (width) from side AND z is < (depth) from top */
	    {
	      E->node[j][node]=E->node[j][node] | TBX;
	      E->node[j][node]=E->node[j][node] & (~FBX);
	      E->node[j][node]=E->node[j][node] | TBY;
	      E->node[j][node]=E->node[j][node] & (~FBY);
	      E->node[j][node]=E->node[j][node] | TBZ;
	      E->node[j][node]=E->node[j][node] & (~FBZ);
	    }

	  if( ((E->sx[j][2][node]>=fff3) && (E->sx[j][3][node]>=E->sphere.ro-E->control.depth_bound_adj)) )
	    /* if fi is < (width) from side AND z is < (depth) from top */
	    {
	      E->node[j][node]=E->node[j][node] | TBX;
	      E->node[j][node]=E->node[j][node] & (~FBX);
	      E->node[j][node]=E->node[j][node] | TBY;
	      E->node[j][node]=E->node[j][node] & (~FBY);
	      E->node[j][node]=E->node[j][node] | TBZ;
	      E->node[j][node]=E->node[j][node] & (~FBZ);
	    }

	}
  } /* end E->control.temperature_bound_adj */

  if (E->control.lith_age_time) {
    if(lv==E->mesh.gridmax)
      for(m=1;m<=E->sphere.caps_per_proc;m++)

	for(i=1;i<=noy;i++)
	  for(j=1;j<=nox;j++){
	    nodeg = E->lmesh.nxs - 1+j+(E->lmesh.nys+i-2)*E->mesh.nox;
	    for(k=1;k<=noz;k++){
	      /* split this up into x-y-z- loop detailes to be able to
		 access age_t */
	      node=k+(j-1)*noz+(i-1)*noxnoz;	      
	      if(in_lith_age_depth(E->sx[m][3][node],E->age_t[nodeg],&depth_used,E)){ /* if closer than (lith_age_depth) from top */
		E->node[m][node]=E->node[m][node] | TBX;
		E->node[m][node]=E->node[m][node] & (~FBX);
		E->node[m][node]=E->node[m][node] | TBY;
		E->node[m][node]=E->node[m][node] & (~FBY);
		E->node[m][node]=E->node[m][node] | TBZ;
		E->node[m][node]=E->node[m][node] & (~FBZ);
	      }
	    }
	  }
  } /* end E->control.lith_age_time */
  
  return;
}


void lith_age_conform_tbc(struct All_variables *E)
{
  int m,j,node,nox,noz,noy,gnox,gnoy,gnoz,nodeg,i,k;
  float ttt2,ttt3,fff2,fff3;
  float r1,t1,f1,t0,temp,depth_used;
  float e_4;
  FILE *fp1;
  char output_file[255];
  int output,in_tbc;


  e_4=1.e-4;
  output = 0;

  gnox=E->mesh.nox;gnoy=E->mesh.noy;gnoz=E->mesh.noz;

  nox=E->lmesh.nox;noy=E->lmesh.noy;noz=E->lmesh.noz;

#ifdef USE_GGRD
  if((!E->control.ggrd.age_control)&&(E->control.lith_age_time==1)) { 
#else
  if(E->control.lith_age_time==1)   {
#endif
    /* to open files every timestep */
    if (E->control.lith_age_old_cycles != E->monitor.solution_cycles) {
      /*update so that output only happens once*/
      output = 1;
      E->control.lith_age_old_cycles = E->monitor.solution_cycles;
    }
    if (E->parallel.me == 0) fprintf(stderr,"INSIDE lith_age_conform_tbc\n");
    (E->solver.lith_age_read_files)(E,output);
  }

  /* NOW SET THE TEMPERATURES IN THE BOUNDARY REGIONS */
  if(E->monitor.solution_cycles>1 && E->control.temperature_bound_adj) {
    ttt2=E->control.theta_min + E->control.width_bound_adj;
    ttt3=E->control.theta_max - E->control.width_bound_adj;
    fff2=E->control.fi_min + E->control.width_bound_adj;
    fff3=E->control.fi_max - E->control.width_bound_adj;

    for(m=1;m<=E->sphere.caps_per_proc;m++)
      for(i=1;i<=noy;i++)
	for(j=1;j<=nox;j++)
	  for(k=1;k<=noz;k++)  {
	    nodeg=E->lmesh.nxs-1+j+(E->lmesh.nys+i-2)*gnox;
	    node=k+(j-1)*noz+(i-1)*nox*noz;
	    t1=E->sx[m][1][node];
	    f1=E->sx[m][2][node];
	    r1=E->sx[m][3][node];

	    if(fabs(r1-E->sphere.ro)>=e_4 && fabs(r1-E->sphere.ri)>=e_4)  { /* if NOT right on the boundary */
	      if( ((E->sx[m][1][node]<=ttt2) && (E->sx[m][3][node]>=E->sphere.ro-E->control.depth_bound_adj)) 
		  || ((E->sx[m][1][node]>=ttt3) && (E->sx[m][3][node]>=E->sphere.ro-E->control.depth_bound_adj)) ) {
		/* if < (width) from x bounds AND (depth) from top */


		t0 =erft_age(r1, E->age_t[nodeg],E);
		
		/* keep the age the same! */
		E->sphere.cap[m].TB[1][node]=t0;
		E->sphere.cap[m].TB[2][node]=t0;
		E->sphere.cap[m].TB[3][node]=t0;
	      }
	    }
	    
	    if( ((E->sx[m][2][node]<=fff2) || (E->sx[m][2][node]>=fff3)) &&
		(E->sx[m][3][node]>=E->sphere.ro-E->control.depth_bound_adj) ) {
	      /* if < (width) from y bounds AND (depth) from top */
	      
	      
	      /* keep the age the same! */
	      t0 = erft_age(r1, E->age_t[nodeg],E);
	      E->sphere.cap[m].TB[1][node]=t0;
	      E->sphere.cap[m].TB[2][node]=t0;
	      E->sphere.cap[m].TB[3][node]=t0;
	      
	    }
	  } /* end k   */
  }   /*  end of solution cycles  && temperature_bound_adj */
  
  /* NOW SET THE TEMPERATURES IN THE LITHOSPHERE IF CHANGING EVERY TIME STEP */
  if((E->convection.tic_method == 4) || ((E->monitor.solution_cycles>0) && E->control.lith_age_time))   {
    for(m=1;m<=E->sphere.caps_per_proc;m++)
      for(i=1;i<=noy;i++)
	for(j=1;j<=nox;j++)
	  for(k=1;k<=noz;k++)  {
	    nodeg=E->lmesh.nxs-1+j+(E->lmesh.nys+i-2)*gnox;
	    node=k+(j-1)*noz+(i-1)*nox*noz;

	    r1=E->sx[m][3][node];

	    if(fabs(r1-E->sphere.ro)>=e_4 && fabs(r1-E->sphere.ri)>=e_4)  { /* if NOT right on the boundary */
	      if(in_lith_age_depth(r1,E->age_t[nodeg],&depth_used,E)) {
		/* if closer than (lith_age_depth) from top */

		/* set a new age from the file */

		t0 = erft_age(r1, E->age_t[nodeg],E);
		E->sphere.cap[m].TB[1][node]=t0;
		E->sphere.cap[m].TB[2][node]=t0;
		E->sphere.cap[m].TB[3][node]=t0;
	      }
	    }
	  }     /* end k   */
  }   /*  end of solution cycles  && lith_age_time */
  
  return;
}
  
/* given non dim radius and non-dim age, compute erf temperature */
float erft_age(float nd_radius, float nd_age, struct All_variables *E)
{
  float lc,temp;
  lc = (E->sphere.ro - nd_radius) * 0.5 / sqrt(nd_age);
  temp = E->control.mantle_temp * erf(lc);
  return temp;
}

void assimilate_lith_conform_bcs(struct All_variables *E)
{
  float lith_age_depth,daf, assimilate_new_temp;
  int m,j,node,nox,noz,noy,gnox,gnoy,gnoz,nodeg,i,k,noxnoz;
  unsigned int type;


  gnox=E->mesh.nox;gnoy=E->mesh.noy;gnoz=E->mesh.noz;

  nox=E->lmesh.nox;noy=E->lmesh.noy;noz=E->lmesh.noz;
  noxnoz = nox*noz;

  for(m=1;m<=E->sphere.caps_per_proc;m++)

    for(i=1;i<=noy;i++)
      for(j=1;j<=nox;j++){
	nodeg=E->lmesh.nxs-1+j+(E->lmesh.nys+i-2)*gnox;
	
	for(k=1;k<=noz;k++)  {
	  node=k+(j-1)*noz+(i-1)*noxnoz;
	  
	  type = (E->node[j][node] & (TBX | TBZ | TBY));
	  
	  switch (type) {
	  case 0:  /* no match, next node */
            break;
	  case TBX:
            assimilate_new_temp = E->sphere.cap[m].TB[1][node];
            break;
	  case TBZ:
            assimilate_new_temp = E->sphere.cap[m].TB[3][node];
            break;
	  case TBY:
            assimilate_new_temp = E->sphere.cap[m].TB[2][node];
            break;
	  case (TBX | TBZ):     /* clashes ! */
            assimilate_new_temp = 0.5 * (E->sphere.cap[m].TB[1][node] + E->sphere.cap[m].TB[3][node]);
            break;
	  case (TBX | TBY):     /* clashes ! */
            assimilate_new_temp = 0.5 * (E->sphere.cap[m].TB[1][node] + E->sphere.cap[m].TB[2][node]);
            break;
	  case (TBZ | TBY):     /* clashes ! */
            assimilate_new_temp = 0.5 * (E->sphere.cap[m].TB[3][node] + E->sphere.cap[m].TB[2][node]);
            break;
	  case (TBZ | TBY | TBX):     /* clashes ! */
            assimilate_new_temp = 0.3333333 * (E->sphere.cap[m].TB[1][node] + E->sphere.cap[m].TB[2][node] + 
					       E->sphere.cap[m].TB[3][node]);
            break;
	  } /* end switch */
	  
	  

	  switch (type) {
	  case 0:  /* no match, next node */
            break;
	  default:
	    if(in_lith_age_depth(E->sx[m][3][node],E->age_t[nodeg],&lith_age_depth,E)) {
	      /* daf == depth_assimilation_factor */
	      daf = 0.5*(E->sphere.ro - E->sx[m][3][node])/lith_age_depth;
	      E->T[m][node] = daf*E->T[m][node] + (1.0-daf)*assimilate_new_temp;
	    }
	    else
	      E->T[m][node] = assimilate_new_temp;
	  } /* end switch */
	  
	} /* next node */
      }
  return;
}
