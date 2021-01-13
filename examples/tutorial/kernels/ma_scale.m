#include "../../../software/target/base/ztam.h"

extern void mycallback(int);

static uint32_t x;
static uint32_t z;
static uint32_t scale;
static uint32_t sz;

// Do matrix scaling 

static void do_ma_scale(void *_p,int pid) {
   int from,to,batchSize,i;
   int fmt=DP_DATA_TYPE_UINT8;

   // main thread do the top half, child thread do the bottom half
   from=(pid==0)?0:sz/2;
   to=(pid==0)?sz/2:sz;
   batchSize=NUM_PCORE*NUM_THREAD_PER_CORE*VECTOR_WIDTH;

   > PCORE[*].ma_scale::scale <= INT(scale);
   for(i=from;i < to;i+=batchSize) {
      > (fmt)PCORE[:].THREAD[:].ma_scale::x[:] <= (fmt)MEM(x,sz)[i:i+batchSize-1];
      > EXE_LOCKSTEP(ma_scale::scale,NUM_PCORE);
      ztamTaskYield();
      > (fmt)MEM(z,(pid==0)?sz/2:sz)[i:i+batchSize-1] <= (fmt)PCORE[:].THREAD[:].ma_scale::z[:];
   }
}

void ma_scale(int queue) {
   // Get request parameters which are memory address
   // of input tensor X,Y and output tensor Z

   x=ztamMsgqReadPointer(queue);
   z=ztamMsgqReadPointer(queue);
   scale=ztamMsgqReadInt(queue);
   sz=ztamMsgqReadInt(queue);

   ztamTaskSpawn(do_ma_scale,0,1);
   do_ma_scale(0,0);
   while(ztamTaskStatus(1))
      ztamTaskYield();
}

> EXPORT(ma_scale);

