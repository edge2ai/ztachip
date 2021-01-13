#include "../../../base/ztam.h"
#include "nn.h"
#include "conv.h"

extern void mycallback(int parm2);

typedef struct {
   uint32_t coef;
   uint32_t bias;
   uint32_t biasHi;
   uint32_t biasLo;   
   uint32_t bot;
   uint32_t top;
   uint32_t top_interleave;
   int ksz;
   int topcnt;
   int topdim;
   int botcnt;
   int botdim;
   int group;
   int stride;
   int pad;
   int bias_scale;
   int top_scale;
   int conv_dx;
   int dycnt;
   int groupsz;
   int input_offset;
   int activation_scale;
   int in_interleave;
   int out_interleave;
   uint32_t stream;
} RequestConv;

// Perform 3x3 convolution

static void convolution_3x3(void *_p,int pid) {
   RequestConv *req=(RequestConv *)_p;
   int i,j,k,r,r2,r3,c2,c;
   int ii,jj,kk;
   int offset;
   int index;
   int m,n;
   int x,y;
   int botcnt,botcnt2;
   int topcnt2;
   int topcnt3;
   int botdim;
   int kz,gkz;
   int rowi;
   int from,to;
   int groupsz,group,step;
   int np;
   int stride_dx,stride_dy;
   uint32_t bot,coef;
   int conv_dx,conv_dy,conv_dy2,conv_dx_log,conv_dx2;
   int dysz,dycnt;
   int dx;
   int kfunc;
   int topfmt=DP_DATA_TYPE_UINT8;
   int botfmt=DP_DATA_TYPE_UINT8;
   int biasfmt=DP_DATA_TYPE_INT16;
   int weightfmt=DP_DATA_TYPE_UINT8;

   if(pid==0) {
      > SPU <= (int)MEM(req->stream,SPU_LOOKUP_SIZE*3)[:];
   }
   conv_dx=req->conv_dx;
   if(conv_dx <= (NUM_THREAD_PER_CORE/2))
      conv_dx2=NUM_THREAD_PER_CORE/2;
   else
      conv_dx2=NUM_THREAD_PER_CORE;
   conv_dx_log=4;
   conv_dy2=req->groupsz;
   groupsz=req->groupsz;
   dycnt=req->dycnt;
   conv_dy=conv_dy2*dycnt;
   group=NUM_PCORE/groupsz;
   np=group*groupsz;
   step=group<<VECTOR_DEPTH;
   kz=req->ksz*req->ksz;
   gkz=kz*group*VECTOR_WIDTH;
   x=conv_dx*req->stride+req->ksz-req->stride;
   x=ROUND(x,VECTOR_WIDTH);
   y=conv_dy*req->stride+req->ksz-req->stride;
   dysz=x*conv_dy2*req->stride;
   topcnt3=((ROUND(req->topcnt,VECTOR_WIDTH)>>VECTOR_DEPTH)*kz)*VECTOR_WIDTH; 
   topcnt2=req->topcnt/req->group;
   botcnt2=req->botcnt/req->group;
   botdim=req->botdim-2*req->pad;
   stride_dy=conv_dy*req->stride;
   stride_dx=conv_dx*req->stride;
   botcnt=req->botcnt;
   bot=req->bot;
   coef=req->coef;

   kfunc=$convolution::exe3x3;
   if(x > CONV_SMALL_BOT_DX) ztamAssert("Convolution error");
   if(y > CONV_SMALL_BOT_DY) ztamAssert("Convolution error");
   if(req->group > 2) ztamAssert("Convolution error");

   > (int)PCORE(np)[*][:].convolution::init.stride <= INT(req->stride);
   > PCORE(np)[*][:].convolution::init._out_scale <= INT(req->activation_scale);
   > PCORE(np)[*][:].convolution::init._in_scale <= HALF(req->bias_scale);
   > (int)PCORE(np)[*][:].convolution::init.conv_dx_log <= INT(conv_dx_log);
   > (int)PCORE(np)[*][:].convolution::init._dx <= INT(x);
   for(i=0;i < np;i++) {
      index=(i%groupsz);
      > (int)PCORE(np)[i][:].convolution::init.mypid <= INT(index);
   }
   > EXE_LOCKSTEP(convolution::init,np);
   ztamTaskYield();
   if(pid==0) {
      from=0;
      to=ROUND(req->topcnt/2,step);
   } else {
      from=ROUND(req->topcnt/2,step);
      to=req->topcnt;
   }
   > $coef_pcore := (weightfmt)PCORE(group,groupsz)[:][*].convolution::coef[0:kz-1][:];
   > $bot_pcore := PCORE(np)[*].convolution::bot[0:x*y-1];
   for(i=from;i < to;i += step) {
      > (biasfmt)PCORE(group,groupsz)[:][*].convolution::biasHi[:] <= (biasfmt)MEM(req->biasHi,req->topcnt)[i:i+step-1];
      > (biasfmt)PCORE(group,groupsz)[:][*].convolution::biasLo[:] <= (biasfmt)MEM(req->biasLo,req->topcnt)[i:i+step-1];
      rowi=((i>>VECTOR_DEPTH)*kz)*VECTOR_WIDTH;
      ii=(i/topcnt2)*botcnt2;
      > $coef_ddr := (weightfmt)MEM(coef,botcnt2,topcnt3)[$][rowi:rowi+gkz-1];
      for(r=0,r2=-req->pad;r < req->topdim;r += conv_dy,r2 += stride_dy) {
         for(c=0,c2=-req->pad;c < req->topdim;c += conv_dx,c2+=stride_dx) {
            > $bot_ddr := PAD(-req->input_offset) (botfmt)MEM(bot,botcnt,botdim,botdim)[$][r2:r2+y-1][c2:c2+x-1];
            > convolution::start.count <= INT(dycnt);
            > EXE_LOCKSTEP(convolution::start,np);
            for(jj=0;jj < botcnt2;jj++) {
               ztamTaskYield(); 
               j=jj+ii;
               > $bot_pcore <= PROC(1) <= $bot_ddr[j];
               > $coef_pcore <= PROC(2) <= $coef_ddr[jj];
               dx=req->topdim-c;
               if(dx > conv_dx)
                  dx=conv_dx;
               for(kk=0,offset=0;kk < dycnt;kk++,offset+=dysz) {
                  if((r+kk*conv_dy2) >= req->topdim)
                     break;
                  > convolution::exe3x3.k <= INT(kk);
                  > convolution::exe3x3.offset <= INT(offset);
                  > EXE_LOCKSTEP(kfunc,np,dx);
               }
            } 
            for(jj=0;jj < dycnt;jj++) {
            > convolution::activate.idx <= INT(jj);
            > EXE_LOCKSTEP(convolution::activate,np);
            }
            ztamTaskYield();
            if(req->out_interleave==kTensorFormatInterleaved || req->out_interleave==kTensorFormatFlatAndInterleaved) {
               if(conv_dx2==NUM_THREAD_PER_CORE) {
                  > (topfmt)MEM(req->top_interleave,req->topdim,req->topdim,req->topcnt)[r:r+conv_dy-1][c:c+conv_dx2-1][i:i+step-1] <= PROC(0) <= (topfmt)  FOR(M=0:dycnt-1) FOR(L=0:groupsz-1) FOR(K=0:NUM_THREAD_PER_CORE-1) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) PCORE(group,groupsz)[J][L].THREAD[K].convolution::top[M][I];
               } else {
                  > (topfmt)MEM(req->top_interleave,req->topdim,req->topdim,req->topcnt)[r:r+conv_dy-1][c:c+conv_dx2-1][i:i+step-1] <= PROC(0) <= (topfmt)  FOR(M=0:dycnt-1) FOR(L=0:groupsz-1) FOR(K=0:NUM_THREAD_PER_CORE/2-1) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) PCORE(group,groupsz)[J][L].THREAD[K].convolution::top[M][I];
               }
            }
            if(req->out_interleave==kTensorFormatFlat || req->out_interleave==kTensorFormatFlatAndInterleaved) {
               if(conv_dx2==NUM_THREAD_PER_CORE) {
                  > (topfmt)MEM(req->top,req->topcnt,req->topdim,req->topdim)[i:i+step-1][r:r+conv_dy-1][c:c+conv_dx2-1] <= PROC(0) <= (topfmt) SCATTER(0) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) FOR(K=0:dycnt-1) PCORE(group,groupsz)[J][:].THREAD(2,8)[:][:].convolution::top[K][I];
               } else {
                  > (topfmt)MEM(req->top,req->topcnt,req->topdim,req->topdim)[i:i+step-1][r:r+conv_dy-1][c:c+conv_dx2-1] <= PROC(0) <= (topfmt) SCATTER(0) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) FOR(K=0:dycnt-1) PCORE(group,groupsz)[J][:].THREAD[0:NUM_THREAD_PER_CORE/2-1].convolution::top[K][I];
               }
            }
         }
      }
   }
}


#define MIN_DYCNT  5 // Minimum dycnt required to avoid MCORE instruction FIFO underrun.

// Doing 1x1 convolution

static void convolution_1x1(void *_p,int pid) {
   RequestConv *req=(RequestConv *)_p;
   int i,k,r,r2,r3,c2,c;
   int ii,jj;
   register int kk;
   int topoffset;
   int index;
   int m,n;
   int xy;
   int botcnt,botcnt2;
   int topcnt,topcnt2;
   int topcnt3;
   int botdim;
   int kz,gkz;
   int mm;
   int rowi;
   int from,to;
   int groupsz,group,step;
   int np,topsz,botsz;
   uint32_t top,top2,bot,top2bot,coef;
   int conv_dx;
   int dysz,dycnt,dycntLast,dzcnt,dycnt2,xy2,xy3,xy4;
   int remain,delta;
   int topfmt=DP_DATA_TYPE_UINT8;
   int botfmt=DP_DATA_TYPE_UINT8;
   int biasfmt=DP_DATA_TYPE_INT16;
   int weightfmt=DP_DATA_TYPE_UINT8;
   uint32_t f,f_activate;
   int mindycnt,batchcnt;
   static uint32_t kfunc[8]={$convolution1x1::exe,$convolution1x1::exe2,$convolution1x1::exe3,$convolution1x1::exe4,
                             $convolution1x1::exe5,$convolution1x1::exe6,$convolution1x1::exe7,$convolution1x1::exe8};
   if(pid==0) {
      > SPU <= (int)MEM(req->stream,SPU_LOOKUP_SIZE*3)[:];
   }
   top=req->top;
   topsz=req->topdim*req->topdim;
   botsz=req->botdim*req->botdim;
   np=NUM_PCORE;
   kz=req->ksz*req->ksz;
   topcnt=0;
   topoffset=0;
   for(group=NUM_PCORE;group >= 1;group=group/2) {
      
      // pcores are divided into group where each group work on the 
      // same convolution tensor.
      // We want to start with the smallest group so that we can process
      // as many tensors at the same time as we can
      // And the remaining tensors after each pass will be processed in a larger group
      // This ensures maximum usage of computation resources with the least
      // waste...

      groupsz=NUM_PCORE/group;
      topoffset+=topcnt; 
      topcnt=req->topcnt-topoffset;
      if(topcnt<=0)
         break;
      topcnt2=ROUND((topcnt+1)/2,VECTOR_WIDTH);
      batchcnt=group*VECTOR_WIDTH;
      if(group > 1)
         topcnt2=(topcnt2/batchcnt)*batchcnt; // Round down
      else
         topcnt2=((topcnt2+batchcnt-1)/batchcnt)*batchcnt; // Round up
      topcnt2=topcnt2*2;
      if(topcnt2 < topcnt)
         topcnt=topcnt2;
      if(topcnt==0)
         continue;

      // First round, do everything in groupsz=1
      if(groupsz==1) {
         for(i=NUM_MIN_THREAD_FOR_MAX_EFFICIENCY;i <= NUM_THREAD_PER_CORE;i++) {
            dycnt=(topsz+(i*groupsz)-1)/(i*groupsz);
            if((dycnt < mindycnt)||(i==NUM_MIN_THREAD_FOR_MAX_EFFICIENCY)) {
               mindycnt=dycnt;
               conv_dx=i;
            }
         }
      } else {
         // When groupsz>1; conv_dx has to be NUM_THREAD inorder to be able to do TX efficiently
         conv_dx=NUM_THREAD_PER_CORE;
      }
      step=group<<VECTOR_DEPTH;
      gkz=kz*group*VECTOR_WIDTH;
      dysz=conv_dx*groupsz;
      dycnt=(topsz+dysz-1)/dysz;
      if(dycnt > CONV_1X1_Y_DIM)
         dycnt=CONV_1X1_Y_DIM;
      while(ROUND(dycnt*dysz,VECTOR_WIDTH) > CONV_1X1_BOTSZ)
         dycnt--;
      dycntLast=((topsz%(dycnt*dysz))+dysz-1)/dysz;
      xy=dysz*dycnt;

      topcnt3=((ROUND(req->topcnt,VECTOR_WIDTH)>>VECTOR_DEPTH)*kz)*VECTOR_WIDTH; 
      botcnt2=req->botcnt/req->group;
      botdim=req->botdim-2*req->pad;
      botcnt=req->botcnt;
      bot=req->bot;
      coef=req->coef;

      // Check if we can do 2 top element at a time.
      if((xy>=topsz) && (botcnt2&1)==0 && (dycnt <= (CONV_1X1_Y_DIM/2)) && ROUND(xy*2,VECTOR_WIDTH) <= CONV_1X1_BOTSZ) {
         // Can do 2 at a time of a top element fit within one interation and there is enough memory
         // to hold 2. And number of botcnt is even
         dzcnt=2;
      } else {
         dzcnt=1;
      }
      if(req->group > 2) ztamAssert("Convolution error");

      // Initialize convolution module...

      > PCORE(np)[*][:].convolution1x1::init._out_scale <= INT(req->activation_scale);
      > PCORE(np)[*][:].convolution1x1::init._dysz <= INT(dysz);
      > PCORE(np)[*][:].convolution1x1::init._conv_dx <= INT(conv_dx);
      for(i=0;i < np;i++) {
         if(req->ksz==11)
            index=0;
         else
            index=(i%groupsz);
         > (int)PCORE(np)[i][:].convolution1x1::init.mypid <= INT(index);
      }
      > EXE_LOCKSTEP(convolution1x1::init,np);
      ztamTaskYield();
      if(pid==0) {
         from=0;
         to=ROUND((topcnt+1)/2,VECTOR_WIDTH);
      } else {
         from=ROUND((topcnt+1)/2,VECTOR_WIDTH);
         to=topcnt;
      }
      from+=topoffset;
      to+=topoffset;

      f_activate=ztamBuildKernelFunc($convolution1x1::activate,np,conv_dx);

      > $coef_pcore := (weightfmt)FOR(I=0:dzcnt-1) PCORE(group,groupsz)[:][*].convolution1x1::coef[I][:];

      for(i=from;i < to;i += step)
      {
         > (biasfmt)PCORE(group,groupsz)[:][*].convolution1x1::biasHi[:] <= (biasfmt)MEM(req->biasHi,req->topcnt)[i:i+step-1];
         > (biasfmt)PCORE(group,groupsz)[:][*].convolution1x1::biasLo[:] <= (biasfmt)MEM(req->biasLo,req->topcnt)[i:i+step-1];

         rowi=((i>>VECTOR_DEPTH)*kz)*VECTOR_WIDTH;
         > $coef_ddr := (weightfmt)MEM(coef,botcnt2/dzcnt,dzcnt,topcnt3)[$][:][rowi:rowi+gkz-1];
         for(mm=0;mm < topsz;) {
            dycnt2=(topsz-mm+dysz-1)/dysz;
            if(dycnt2 > dycnt)
               dycnt2=dycnt;
            if(dycnt2 > MIN_DYCNT && dycntLast < MIN_DYCNT) {
               // dycnt needs at least to be MIN_DYCNT to avoid not feeding instruction to mcore fast enough
               // The last loop may not have enough dycnt, so offload some dycnt from previous loop to the last 
               // loop.
               // Its important to make sure mcore instruction fifo is always fed with enough instructions
               int extra;
               extra=(dycnt2-MIN_DYCNT);
               if(extra > (MIN_DYCNT-dycntLast))
                  extra=(MIN_DYCNT-dycntLast);
               dycnt2-=extra;
               dycntLast+=extra;
            }
            f=ztamBuildKernelFunc(kfunc[dycnt2-1],NUM_PCORE,conv_dx);
            xy2=conv_dx*groupsz*dycnt2;
            xy3=ROUND(xy2,VECTOR_WIDTH);
            xy4=xy3*dzcnt;
            if(dzcnt>1 && xy4 > (dzcnt*botsz))
               xy4=ROUND(dzcnt*botsz,VECTOR_WIDTH);      
            > $bot_ddr := (botfmt)MEM(bot,botcnt/dzcnt,botsz*dzcnt)[$][mm:mm+xy4-1];
            > $bot_pcore := PCORE(np)[*].convolution1x1::bot[0:xy4-1];
            > convolution1x1::start.count <= INT(dycnt2);
            > EXE_LOCKSTEP(convolution1x1::start,np);

            // Do convolution...
            
            if(dzcnt > 1) {
               for(jj=0;jj < botcnt2;jj+=dzcnt) {
                  ztamTaskYield(); 
                  > $bot_pcore <= PROC(1) <= $bot_ddr[jj/dzcnt];
                  > $coef_pcore <= PROC(2) <= $coef_ddr[jj/dzcnt];
                  > convolution1x1::exe2.idx <= INT(0);
                  > convolution1x1::exe2.idx2 <= INT(0);
                  > EXE_LOCKSTEP(f);
                  > convolution1x1::exe2.idx <= INT(botsz);
                  > convolution1x1::exe2.idx2 <= INT(1);
                  > EXE_LOCKSTEP(f);
               }
            } else {
               > convolution1x1::exe2.idx <= INT(0);
               > convolution1x1::exe2.idx2 <= INT(0);
               for(jj=0;jj < botcnt2;jj+=dzcnt) {
                  ztamTaskYield(); 
                  > $bot_pcore <= PROC(1) <= $bot_ddr[jj];
                  > $coef_pcore <= PROC(2) <= $coef_ddr[jj];
                  > EXE_LOCKSTEP(f);
               }
            }
            ztamTaskYield();	
            
            // Do activation step... 
            
            for(jj=0;jj < dycnt2;jj++)
            { 
               > convolution1x1::activate.idx <= INT(jj);
               > convolution1x1::activate.idx2 <= INT(jj*conv_dx);
               > EXE_LOCKSTEP(f_activate);
            }
            ztamTaskYield();
            
            // Output results...
            
            if(groupsz > 1) {
               if(req->out_interleave==kTensorFormatInterleaved || req->out_interleave==kTensorFormatFlatAndInterleaved) {
                  // Output in interleave format
                  > (topfmt)MEM(req->top_interleave,topsz,req->topcnt)[mm:mm+xy2-1][i:i+step-1] <= PROC(0) <= (topfmt)  FOR(M=0:dycnt2-1) FOR(L=0:groupsz-1) FOR(K=0:NUM_THREAD_PER_CORE-1) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) PCORE(group,groupsz)[J][L].convolution1x1::top(CONV_1X1_Y_DIM,NUM_THREAD_PER_CORE,VECTOR_WIDTH)[M][K][I];
               }
               if(req->out_interleave==kTensorFormatFlat || req->out_interleave==kTensorFormatFlatAndInterleaved) {
                  // Output in non-interleave format
                  > (topfmt)MEM(req->top,req->topcnt,topsz)[i:i+step-1][mm:mm+xy2-1] <= PROC(0) <= (topfmt) SCATTER(0) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) FOR(K=0:dycnt2-1) PCORE(group,groupsz)[J][:].convolution1x1::top(CONV_1X1_Y_DIM,2,8,VECTOR_WIDTH)[K][:][:][I];
               }
            } else {
               if(req->out_interleave==kTensorFormatInterleaved || req->out_interleave==kTensorFormatFlatAndInterleaved) {
                  // Output in interleave format
                  > (topfmt)MEM(req->top_interleave,topsz,req->topcnt)[mm:mm+xy2-1][i:i+step-1] <= PROC(0) <= (topfmt)  FOR(K=0:xy2-1) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) PCORE(group)[J].convolution1x1::top(CONV_1X1_Y_DIM*NUM_THREAD_PER_CORE,VECTOR_WIDTH)[K][I];
               }
               if(req->out_interleave==kTensorFormatFlat || req->out_interleave==kTensorFormatFlatAndInterleaved) {
                  // Output in non-interleave format
                  > (topfmt)MEM(req->top,req->topcnt,topsz)[i:i+step-1][mm:mm+xy3-1] <= PROC(0) <= (topfmt) SCATTER(0) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) FOR(K=0:xy3/8-1) PCORE(group)[J].convolution1x1::top(CONV_1X1_Y_DIM*NUM_THREAD_PER_CORE/8,8,VECTOR_WIDTH)[K][:][I];
               }
            }
            mm += dysz*dycnt2;
         }
      }
   }
}

// Perform depth-wise convolution

static void convolution_depthwise(void *_p,int pid) {
   RequestConv *req=(RequestConv *)_p;
   int i,k,r,r2,r3,c2,c;
   int kk;
   int offset,topoffset;
   int index;
   int m,n;
   int x,y;
   int botcnt;
   int topcnt2;
   int coefsz;
   int topcnt;
   int botdim;
   int kz,gkz;
   int rowi;
   int from,to;
   int groupsz,group,step;
   int np;
   int stride_dx,stride_dy;
   uint32_t bot,coef;
   int conv_dx,conv_dy,conv_dy2,conv_dx2;
   int dysz,dycnt,dxcnt;
   int dx;
   int topfmt=DP_DATA_TYPE_UINT8;
   int botfmt=DP_DATA_TYPE_UINT8;
   int biasfmt=DP_DATA_TYPE_INT16;
   int weightfmt=DP_DATA_TYPE_UINT8;
   int botsz;
   int f,loop;
   int count,minCount,interation,minInteration;
   int batchcnt,maxgroupsz,mingroup;
   int threadSubBlock;

   if(pid==0) {
      > SPU <= (int)MEM(req->stream,SPU_LOOKUP_SIZE*3)[:];
   }
   np=NUM_PCORE;
   kz=req->ksz*req->ksz;   
   botdim=req->botdim-2*req->pad;
   botcnt=req->botcnt;
   bot=req->bot;
   botsz=botcnt*botdim*botdim;
   coef=req->coef;
   coefsz=((ROUND(req->topcnt,VECTOR_WIDTH)>>VECTOR_DEPTH)*kz)*VECTOR_WIDTH; 

   for(dx=1;dx <= NUM_THREAD_PER_CORE;dx++) {
      if((dx*req->stride+req->ksz-req->stride)>CONV_DEPTHWISE_BOT_DX)
         break;
      count = (req->topdim+dx-1)/dx;
      if(count < minCount || dx==1) {
         minCount=count;
         conv_dx=dx;
      }
   }
   if(conv_dx <= (NUM_THREAD_PER_CORE/2))
      conv_dx2=(NUM_THREAD_PER_CORE/2);
   else
      conv_dx2=NUM_THREAD_PER_CORE;
   topcnt=0;
   topoffset=0;
   maxgroupsz=(CONV_DEPTHWISE_BOT_DY-req->ksz+req->stride)/req->stride;
   mingroup=(NUM_PCORE+maxgroupsz-1)/maxgroupsz;
   for(group=NUM_PCORE;group >= mingroup;group=group/2) {

      // pcores are divided into group where each group work on the 
      // same convolution tensor.
      // We want to start with the smallest group so that we can process
      // as many tensors at the same time as we can
      // And the remaining tensors after each pass will be processed in a larger group
      // This ensures maximum usage of computation resources with the least
      // waste...

      topoffset+=topcnt; 
      topcnt=req->topcnt-topoffset;
      if(topcnt<=0)
         break;
      topcnt2=ROUND((topcnt+1)/2,VECTOR_WIDTH);
      batchcnt=group*VECTOR_WIDTH;
      if((group/2)>=mingroup)
         topcnt2=(topcnt2/batchcnt)*batchcnt; // Round down
      else
         topcnt2=((topcnt2+batchcnt-1)/batchcnt)*batchcnt; // Round up
      topcnt2=topcnt2*2;
      if(topcnt2 < topcnt)
         topcnt=topcnt2;
      if(topcnt==0)
         continue;
      groupsz=NUM_PCORE/group;
      dxcnt=NUM_THREAD_PER_CORE/conv_dx;
      if(dxcnt>2) dxcnt=2;
      if((dxcnt*groupsz*req->stride+(req->ksz-req->stride)) > CONV_DEPTHWISE_BOT_DY)
         dxcnt=1;
      dycnt=(req->topdim+groupsz-1)/groupsz;
      dycnt=(dycnt+dxcnt-1)/dxcnt;
      if(dycnt > CONV_DEPTHWISE_Y_DIM)
         dycnt=CONV_DEPTHWISE_Y_DIM;
      while((dycnt*dxcnt*groupsz*req->stride+(req->ksz-req->stride)) > CONV_DEPTHWISE_BOT_DY)
         dycnt--;
      conv_dy2=groupsz;
      conv_dy=conv_dy2*dycnt*dxcnt;
      step=group<<VECTOR_DEPTH;
      gkz=kz*group*VECTOR_WIDTH;
      x=conv_dx*req->stride+req->ksz-req->stride;
      y=conv_dy*req->stride+req->ksz-req->stride;
      dysz=x*conv_dy2*req->stride;
      stride_dy=conv_dy*req->stride;
      stride_dx=conv_dx*req->stride;
      threadSubBlock=(conv_dx2==NUM_THREAD_PER_CORE)?2:dxcnt;
      if(x > CONV_DEPTHWISE_BOT_DX) ztamAssert("Convolution error");
      if(y > CONV_DEPTHWISE_BOT_DY) ztamAssert("Convolution error");

      // Initialize module...

      > (int)PCORE(np)[*][:].convolution_depthwise::init.stride <= INT(req->stride);
      > PCORE(np)[*][:].convolution_depthwise::init._out_scale <= INT(req->activation_scale);
      > PCORE(np)[*][:].convolution_depthwise::init._in_scale <= HALF(req->bias_scale);
      > (int)PCORE(np)[*][:].convolution_depthwise::init._dx <= INT(x);

      for(i=0;i < np;i++) {
         index=(i%groupsz);
         > (int)PCORE(np)[i][:].convolution_depthwise::init.mypid <= INT(index);
      }
      if(dxcnt==1) {
         > EXE_LOCKSTEP(convolution_depthwise::init,np);
      } else {    
         > EXE_LOCKSTEP(convolution_depthwise::init2,np);
      }
      ztamTaskYield();

      if(pid==0) {
         from=0;
         to=ROUND((topcnt+1)/2,VECTOR_WIDTH);
      } else {
         from=ROUND((topcnt+1)/2,VECTOR_WIDTH);
         to=topcnt;
      }
      from+=topoffset;
      to+=topoffset;

      f=ztamBuildKernelFunc($convolution_depthwise::exe3x3,np,(dxcnt==1)?conv_dx:NUM_THREAD_PER_CORE/2+conv_dx);

      > $coef_pcore := (weightfmt)PCORE(group,groupsz)[:][*].convolution_depthwise::coef[0:kz-1][:];

      >VAR $bot_pcore;
      if(req->in_interleave) {
         > $bot_pcore := (botfmt) FOR(XY=0:x*y-1) FOR(K=0:group-1) PCORE(group,groupsz)[K][*].convolution_depthwise::bot[XY][:];
      } else {
         > $bot_pcore := FOR(K=0:group-1) FOR(J=0:VECTOR_WIDTH-1) PCORE(group,groupsz)[K][*].convolution_depthwise::bot[0:x*y-1][J];
      }

      for(i=from;i < to;i += step) {
         > (biasfmt)PCORE(group,groupsz)[:][*].convolution_depthwise::biasHi[:] <= (biasfmt)MEM(req->biasHi,req->topcnt)[i:i+step-1];
         > (biasfmt)PCORE(group,groupsz)[:][*].convolution_depthwise::biasLo[:] <= (biasfmt)MEM(req->biasLo,req->topcnt)[i:i+step-1];

         rowi=((i>>VECTOR_DEPTH)*kz)*VECTOR_WIDTH;

         > $coef_ddr := (weightfmt)MEM(coef,coefsz)[rowi:rowi+gkz-1];
         > $coef_pcore <= PROC(2) <= $coef_ddr;

         for(r=0,r2=-req->pad;r < req->topdim;r += conv_dy,r2 += stride_dy) {
            for(c=0,c2=-req->pad;c < req->topdim;c += conv_dx,c2+=stride_dx) {
               >VAR $bot_ddr;
               if(req->in_interleave) {
                  > $bot_ddr := PAD(0) (botfmt)MEM(bot,botdim,botdim,botcnt)[r2:r2+y-1][c2:c2+x-1][i:i+group*VECTOR_WIDTH-1];
               } else {
                  > $bot_ddr := PAD(0) (botfmt)MEM(bot,botcnt,botdim,botdim)[i:i+group*VECTOR_WIDTH-1][r2:r2+y-1][c2:c2+x-1];		
               }
               > $bot_pcore <= PROC(1) <= $bot_ddr;
               dx=req->topdim-c;
               if(dx > conv_dx)
                  dx=conv_dx;

               // Do convolution...

               for(kk=0,offset=0;kk < dycnt;kk++,offset+=dxcnt*dysz) {
                  if((r+kk*conv_dy2*dxcnt) >= req->topdim)
                     break;
                  > convolution_depthwise::exe3x3.k <= INT(kk);
                  > convolution_depthwise::exe3x3.offset <= INT(offset);
                  > EXE_LOCKSTEP(f);
               }
               ztamTaskYield();

               // Output results...

               > (topfmt)MEM(req->top,req->topcnt,req->topdim,req->topdim)[i:i+step-1][r:r+conv_dy-1][c:c+conv_dx2-1] <= PROC(0) <= (topfmt) SCATTER(0) FOR(J=0:group-1) FOR(I=0:VECTOR_WIDTH-1) FOR(K=0:dycnt-1) PCORE(group,groupsz)[J][:].THREAD(2,8)[0:threadSubBlock-1][:].convolution_depthwise::top[K][I];
            }
         }      
      }
   }
}

typedef struct {
   int size;
   uint32_t input[2];
   uint32_t output;
   uint32_t stream;
} RequestAdd;

// Perform add layer 

static void do_add_process(void *_p,int pid)
{
   RequestAdd *req=(RequestAdd *)_p;
   int i,np,step,step2,from,to;
   int fmt=DP_DATA_TYPE_UINT8;
   np=NUM_PCORE;

   if(pid==0) {
      > SPU <= (int)MEM(req->stream,SPU_LOOKUP_SIZE*3)[:];
   }
   step=NUM_PCORE*NUM_THREAD_PER_CORE*VECTOR_WIDTH;
   step2=step;
   if(pid==0) {
      from=0;
      to=ROUND(req->size/2,step);
   } else {
      from=ROUND(req->size/2,step);
      to=req->size;
   }
   for(i=from;i < to;i+=step) { 
      > (fmt)PCORE(np)[:].THREAD[:].add::exe.x1 <= PROC(1) <= (fmt)MEM(req->input[0],req->size(req->size))[i:i+step2-1];
      > (fmt)PCORE(np)[:].THREAD[:].add::exe.x2 <= PROC(2) <= (fmt)MEM(req->input[1],req->size(req->size))[i:i+step2-1];
      > EXE_LOCKSTEP(add::exe,np);
      ztamTaskYield();
      > (fmt)MEM(req->output,req->size(req->size))[i:i+step2-1] <= PROC(0) <= (fmt)PCORE(np)[:].THREAD[:].add::exe.y;
   }
}

// Process add request

void do_add(int queue)
{
   RequestAdd req;

   req.size=ztamMsgqReadInt(queue);
   req.input[0]=ztamMsgqReadPointer(queue);
   req.input[1]=ztamMsgqReadPointer(queue);
   req.output=ztamMsgqReadPointer(queue);
   req.stream=ztamMsgqReadPointer(queue);
   ztamTaskSpawn(do_add_process,&req,1);
   do_add_process(&req,0);
   while(ztamTaskStatus(1))
      ztamTaskYield();
}

// Process convolution request

void do_convolution(int queue)
{
   RequestConv req;

   req.coef=ztamMsgqReadPointer(queue);
   req.biasHi=ztamMsgqReadPointer(queue);
   req.biasLo=ztamMsgqReadPointer(queue);
   req.bot=ztamMsgqReadPointer(queue);
   req.top=ztamMsgqReadPointer(queue);
   req.top_interleave=ztamMsgqReadPointer(queue);
   req.ksz=ztamMsgqReadInt(queue);
   req.topcnt=ztamMsgqReadInt(queue);
   req.topdim=ztamMsgqReadInt(queue);
   req.botcnt=ztamMsgqReadInt(queue);
   req.botdim=ztamMsgqReadInt(queue);
   req.input_offset=ztamMsgqReadInt(queue);
   req.activation_scale=ztamMsgqReadInt(queue);
   req.stream=ztamMsgqReadPointer(queue);
   req.group=ztamMsgqReadInt(queue);
   req.stride=ztamMsgqReadInt(queue);
   req.pad=ztamMsgqReadInt(queue);
   req.conv_dx=ztamMsgqReadInt(queue);
   req.dycnt=ztamMsgqReadInt(queue);
   req.groupsz=ztamMsgqReadInt(queue);
   req.in_interleave=ztamMsgqReadInt(queue);
   req.out_interleave=ztamMsgqReadInt(queue);
   if(req.ksz==1)
   {
      ztamTaskSpawn(convolution_1x1,&req,1);
      convolution_1x1(&req,0);
   }
   else
   {
      ztamTaskSpawn(convolution_3x3,&req,1);
      convolution_3x3(&req,0);
   }
   while(ztamTaskStatus(1))
      ztamTaskYield();
}

// Process depth_wise convolution request

void do_convolution_depthwise(int queue)
{
   RequestConv req;
   req.coef=ztamMsgqReadPointer(queue);
   req.biasHi=ztamMsgqReadPointer(queue);
   req.biasLo=ztamMsgqReadPointer(queue);
   req.bot=ztamMsgqReadPointer(queue);
   req.top=ztamMsgqReadPointer(queue);
   req.top_interleave=ztamMsgqReadPointer(queue);
   req.ksz=ztamMsgqReadInt(queue);
   req.topcnt=ztamMsgqReadInt(queue);
   req.topdim=ztamMsgqReadInt(queue);
   req.botcnt=ztamMsgqReadInt(queue);
   req.botdim=ztamMsgqReadInt(queue);
   req.input_offset=ztamMsgqReadInt(queue);
   req.activation_scale=ztamMsgqReadInt(queue);
   req.stream=ztamMsgqReadPointer(queue);
   req.group=ztamMsgqReadInt(queue);
   req.stride=ztamMsgqReadInt(queue);
   req.pad=ztamMsgqReadInt(queue);
   req.conv_dx=ztamMsgqReadInt(queue);
   req.dycnt=ztamMsgqReadInt(queue);
   req.groupsz=ztamMsgqReadInt(queue);
   req.in_interleave=ztamMsgqReadInt(queue);
   req.out_interleave=ztamMsgqReadInt(queue);
   ztamTaskSpawn(convolution_depthwise,&req,1);
   convolution_depthwise(&req,0);
   while(ztamTaskStatus(1))
      ztamTaskYield();
}

> EXPORT(do_convolution);
> EXPORT(do_convolution_depthwise);
> EXPORT(do_add);
