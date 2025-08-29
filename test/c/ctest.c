#include <stdio.h>
#include <dlfcn.h>

typedef int (*fn_t)(int);

int main(int argc, char** argv){
  if(argc < 2){
    fprintf(stderr, "usage: %s <libpath>\n", argv[0]);
    return 2;
  }
  void* h = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
  if(!h){
    fprintf(stderr, "dlopen failed: %s\n", dlerror());
    return 3;
  }
  fn_t f = (fn_t)dlsym(h, "jc_add_one");
  if(!f){
    fprintf(stderr, "dlsym failed: %s\n", dlerror());
    return 4;
  }
  int r = f(41);
  if(r != 42){
    fprintf(stderr, "bad result: %d\n", r);
    return 5;
  }
  return 0;
}

