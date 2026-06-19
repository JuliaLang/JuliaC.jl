#include <stdio.h>

extern int g1();
extern int g2();
extern int g3();

int g1_caller(){
    return g1();
};
int g2_caller(){
    return g2();
};
int g3_caller(){
    return g3();
};

int client_main(void){
    printf("%d\n", g1());
    printf("%d\n", g2());
    printf("%d\n", g3());
    return g1();
}
